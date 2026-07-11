const admin = require('firebase-admin');
const { v4: uuidv4 } = require('uuid');

let messaging = null;

function initializeMessaging(logger) {
  const raw = process.env.FIREBASE_SERVICE_ACCOUNT_JSON;
  if (!raw) {
    logger.warn('FIREBASE_SERVICE_ACCOUNT_JSON is not configured; push delivery is disabled');
    return;
  }
  try {
    const credential = JSON.parse(raw);
    const app = admin.apps.length
      ? admin.app()
      : admin.initializeApp({ credential: admin.credential.cert(credential) });
    messaging = app.messaging();
  } catch (error) {
    logger.error('Firebase Admin initialization failed', { error: error.message });
  }
}

async function ensureDispatchSchema(pool) {
  await pool.query(`
    CREATE TABLE IF NOT EXISTS worker_presence (
      worker_enrollment_id UUID PRIMARY KEY REFERENCES worker_enrollments(id) ON DELETE CASCADE,
      fcm_token TEXT,
      platform VARCHAR(20) NOT NULL DEFAULT 'android',
      online BOOLEAN NOT NULL DEFAULT FALSE,
      latitude DOUBLE PRECISION,
      longitude DOUBLE PRECISION,
      last_seen_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    );
    CREATE INDEX IF NOT EXISTS worker_presence_online_idx
      ON worker_presence(online, last_seen_at DESC);
    CREATE TABLE IF NOT EXISTS worker_job_dispatches (
      id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
      customer_task_id VARCHAR(120) NOT NULL,
      service_type VARCHAR(30) NOT NULL,
      category VARCHAR(120) NOT NULL,
      title VARCHAR(160) NOT NULL,
      notes TEXT,
      address_text VARCHAR(500) NOT NULL,
      latitude DOUBLE PRECISION NOT NULL,
      longitude DOUBLE PRECISION NOT NULL,
      budget INTEGER NOT NULL,
      status VARCHAR(30) NOT NULL DEFAULT 'offered',
      accepted_worker_id UUID REFERENCES worker_enrollments(id),
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      expires_at TIMESTAMPTZ NOT NULL DEFAULT NOW() + INTERVAL '2 minutes'
    );
    CREATE TABLE IF NOT EXISTS worker_job_offers (
      job_id UUID NOT NULL REFERENCES worker_job_dispatches(id) ON DELETE CASCADE,
      worker_enrollment_id UUID NOT NULL REFERENCES worker_enrollments(id) ON DELETE CASCADE,
      status VARCHAR(30) NOT NULL DEFAULT 'offered',
      responded_at TIMESTAMPTZ,
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      PRIMARY KEY(job_id, worker_enrollment_id)
    );
  `);
}

async function updatePresence(pool, value) {
  const worker = await pool.query(
    `SELECT id FROM worker_enrollments WHERE phone = $1 AND worker_status = 'verified' LIMIT 1`,
    [value.phone]
  );
  if (!worker.rowCount) return null;
  const result = await pool.query(`
    INSERT INTO worker_presence (
      worker_enrollment_id, fcm_token, platform, online, latitude, longitude, last_seen_at, updated_at
    ) VALUES ($1,$2,$3,$4,$5,$6,NOW(),NOW())
    ON CONFLICT (worker_enrollment_id) DO UPDATE SET
      fcm_token = COALESCE(EXCLUDED.fcm_token, worker_presence.fcm_token),
      platform = EXCLUDED.platform,
      online = EXCLUDED.online,
      latitude = EXCLUDED.latitude,
      longitude = EXCLUDED.longitude,
      last_seen_at = NOW(), updated_at = NOW()
    RETURNING worker_enrollment_id AS "workerId", online, last_seen_at AS "lastSeenAt"
  `, [worker.rows[0].id, value.fcmToken, value.platform, value.online,
    value.latitude, value.longitude]);
  return result.rows[0];
}

async function dispatchJob(pool, value) {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const job = await client.query(`
      INSERT INTO worker_job_dispatches (
        customer_task_id, service_type, category, title, notes, address_text,
        latitude, longitude, budget
      ) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9) RETURNING *
    `, [value.customerTaskId, value.serviceType, value.category, value.title,
      value.notes, value.address, value.latitude, value.longitude, value.budget]);
    const candidates = await client.query(`
      SELECT we.id, wp.fcm_token,
        6371 * 2 * ASIN(SQRT(
          POWER(SIN(RADIANS(wp.latitude - $1) / 2), 2) +
          COS(RADIANS($1)) * COS(RADIANS(wp.latitude)) *
          POWER(SIN(RADIANS(wp.longitude - $2) / 2), 2)
        )) AS distance_km
      FROM worker_enrollments we
      JOIN worker_presence wp ON wp.worker_enrollment_id = we.id
      WHERE we.worker_status = 'verified'
        AND wp.online = TRUE
        AND wp.last_seen_at > NOW() - INTERVAL '3 minutes'
        AND wp.latitude IS NOT NULL AND wp.longitude IS NOT NULL
        AND (
          ($3 = 'helper' AND 'helper' = ANY(we.enrollment_types)) OR
          ($3 = 'professional' AND 'professional' = ANY(we.enrollment_types)
            AND EXISTS (SELECT 1 FROM unnest(we.professional_categories) c WHERE LOWER(c) = LOWER($4)))
        )
        AND 6371 * 2 * ASIN(SQRT(
          POWER(SIN(RADIANS(wp.latitude - $1) / 2), 2) +
          COS(RADIANS($1)) * COS(RADIANS(wp.latitude)) *
          POWER(SIN(RADIANS(wp.longitude - $2) / 2), 2)
        )) <= we.travel_radius_km
      ORDER BY distance_km ASC LIMIT 50
    `, [value.latitude, value.longitude, value.serviceType, value.category]);
    for (const worker of candidates.rows) {
      await client.query(
        'INSERT INTO worker_job_offers(job_id, worker_enrollment_id) VALUES ($1,$2)',
        [job.rows[0].id, worker.id]
      );
    }
    await client.query('COMMIT');

    const tokens = candidates.rows.map((row) => row.fcm_token).filter(Boolean);
    let push = { configured: Boolean(messaging), attempted: tokens.length, succeeded: 0 };
    if (messaging && tokens.length) {
      const response = await messaging.sendEachForMulticast({
        tokens,
        notification: { title: 'New Gofer job nearby', body: `${value.title} · Rs ${value.budget}` },
        data: {
          type: 'job_offer', jobId: job.rows[0].id, workType: value.category,
          customerArea: value.address, notes: value.notes || '', budget: String(value.budget)
        },
        android: {
          priority: 'high',
          notification: { channelId: 'gofer_jobs', sound: 'default', priority: 'max', visibility: 'public' }
        }
      });
      push.succeeded = response.successCount;
    }
    return { id: job.rows[0].id, matchedWorkers: candidates.rowCount, push };
  } catch (error) {
    await client.query('ROLLBACK');
    throw error;
  } finally { client.release(); }
}

async function respondToJob(pool, jobId, phone, decision) {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const worker = await client.query('SELECT id FROM worker_enrollments WHERE phone=$1', [phone]);
    if (!worker.rowCount) return null;
    const offer = await client.query(`
      UPDATE worker_job_offers SET status=$1, responded_at=NOW()
      WHERE job_id=$2 AND worker_enrollment_id=$3 AND status='offered' RETURNING *
    `, [decision, jobId, worker.rows[0].id]);
    if (!offer.rowCount) { await client.query('ROLLBACK'); return null; }
    if (decision === 'accepted') {
      const claimed = await client.query(`
        UPDATE worker_job_dispatches SET status='accepted', accepted_worker_id=$1
        WHERE id=$2 AND status='offered' AND expires_at>NOW() RETURNING id
      `, [worker.rows[0].id, jobId]);
      if (!claimed.rowCount) { await client.query('ROLLBACK'); return { accepted: false }; }
      await client.query(`UPDATE worker_job_offers SET status='expired', responded_at=NOW()
        WHERE job_id=$1 AND worker_enrollment_id<>$2 AND status='offered'`, [jobId, worker.rows[0].id]);
    }
    await client.query('COMMIT');
    return { accepted: decision === 'accepted', decision };
  } catch (error) { await client.query('ROLLBACK'); throw error; }
  finally { client.release(); }
}

module.exports = { initializeMessaging, ensureDispatchSchema, updatePresence, dispatchJob, respondToJob };
