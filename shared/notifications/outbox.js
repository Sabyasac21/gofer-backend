const crypto = require('crypto');

const OUTBOX_SCHEMA = `
  CREATE TABLE IF NOT EXISTS notification_outbox (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    event_id VARCHAR(240) NOT NULL UNIQUE,
    event_type VARCHAR(120) NOT NULL,
    payload JSONB NOT NULL,
    status VARCHAR(20) NOT NULL DEFAULT 'pending'
      CHECK (status IN ('pending','publishing','published')),
    attempts INTEGER NOT NULL DEFAULT 0,
    next_attempt_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    published_at TIMESTAMPTZ
  );
  CREATE INDEX IF NOT EXISTS notification_outbox_pending_idx
    ON notification_outbox(status,next_attempt_at,created_at);
`;

function eventId(eventType, aggregateId, transition) {
  return crypto
    .createHash('sha256')
    .update(`${eventType}:${aggregateId}:${transition || ''}`)
    .digest('hex');
}

async function ensureNotificationOutbox(pool) {
  await pool.query(OUTBOX_SCHEMA);
}

async function enqueueNotificationEvent(client, event) {
  const envelope = {
    eventId: event.eventId,
    type: event.type,
    occurredAt: event.occurredAt || new Date().toISOString(),
    recipients: event.recipients,
    data: event.data || {},
  };
  await client.query(`
    INSERT INTO notification_outbox(event_id,event_type,payload)
    VALUES($1,$2,$3::jsonb)
    ON CONFLICT(event_id) DO NOTHING
  `, [envelope.eventId, envelope.type, JSON.stringify(envelope)]);
  return envelope;
}

function startNotificationOutboxPublisher(pool, options = {}) {
  const logger = options.logger || console;
  const rabbitUrl = options.rabbitUrl || process.env.RABBITMQ_URL;
  const internalUrl = options.internalUrl || process.env.NOTIFICATION_INTERNAL_URL;
  const internalKey = options.internalKey || process.env.NOTIFICATION_INTERNAL_KEY;
  const intervalMs = Number(options.intervalMs || 1500);
  let stopped = false;
  let running = false;
  let connection;
  let channel;

  async function publishViaRabbit(payload) {
    if (!rabbitUrl) return false;
    if (!channel) {
      // Lazy require keeps services usable when RabbitMQ is intentionally absent.
      const amqp = require('amqplib');
      connection = await amqp.connect(rabbitUrl);
      channel = await connection.createConfirmChannel();
      await channel.assertExchange('workida.events', 'topic', { durable: true });
    }
    channel.publish(
      'workida.events',
      `notification.${payload.type}`,
      Buffer.from(JSON.stringify(payload)),
      { persistent: true, contentType: 'application/json', messageId: payload.eventId },
    );
    await channel.waitForConfirms();
    return true;
  }

  async function publishViaHttp(payload) {
    if (!internalUrl || !internalKey || typeof fetch !== 'function') return false;
    const response = await fetch(`${internalUrl.replace(/\/$/, '')}/api/internal/notification-events`, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'x-notification-service-key': internalKey,
      },
      body: JSON.stringify(payload),
    });
    if (!response.ok) throw new Error(`Notification service returned HTTP ${response.status}`);
    return true;
  }

  async function tick() {
    if (stopped || running) return;
    running = true;
    try {
      const rows = await pool.query(`
        SELECT id,payload,attempts FROM notification_outbox
        WHERE status IN ('pending','publishing') AND next_attempt_at<=NOW()
        ORDER BY created_at LIMIT 25
      `);
      for (const row of rows.rows) {
        try {
          await pool.query(
            `UPDATE notification_outbox SET status='publishing',attempts=attempts+1 WHERE id=$1`,
            [row.id],
          );
          const published = await publishViaRabbit(row.payload)
            || await publishViaHttp(row.payload);
          if (!published) break;
          await pool.query(
            `UPDATE notification_outbox SET status='published',published_at=NOW() WHERE id=$1`,
            [row.id],
          );
        } catch (error) {
          const delaySeconds = Math.min(300, 2 ** Math.min(Number(row.attempts || 0), 8));
          await pool.query(`
            UPDATE notification_outbox
            SET status='pending',next_attempt_at=NOW()+($2 * INTERVAL '1 second')
            WHERE id=$1
          `, [row.id, delaySeconds]);
          logger.warn('Notification outbox publish failed', {
            eventId: row.payload?.eventId,
            error: error.message,
          });
          channel = null;
          if (connection) await connection.close().catch(() => {});
          connection = null;
        }
      }
    } catch (error) {
      logger.warn('Notification outbox poll failed', { error: error.message });
    } finally {
      running = false;
    }
  }

  const timer = setInterval(tick, intervalMs);
  timer.unref?.();
  tick();
  return async () => {
    stopped = true;
    clearInterval(timer);
    if (connection) await connection.close().catch(() => {});
  };
}

module.exports = {
  eventId,
  ensureNotificationOutbox,
  enqueueNotificationEvent,
  startNotificationOutboxPublisher,
};
