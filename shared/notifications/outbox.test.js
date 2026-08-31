const test = require('node:test');
const assert = require('node:assert/strict');
const { eventId, enqueueNotificationEvent } = require('./outbox');

test('event IDs are deterministic and transition-specific', () => {
  assert.equal(eventId('job.updated', 'job-1', 'arrived'), eventId('job.updated', 'job-1', 'arrived'));
  assert.notEqual(eventId('job.updated', 'job-1', 'arrived'), eventId('job.updated', 'job-1', 'started'));
});

test('outbox envelopes contain only the public event contract', async () => {
  const calls = [];
  const client = { query: async (sql, values) => calls.push({ sql, values }) };
  const envelope = await enqueueNotificationEvent(client, {
    eventId: 'event-1',
    type: 'job.worker_arrived',
    occurredAt: '2026-01-01T00:00:00.000Z',
    recipients: [{ type: 'customer', id: 'customer-1' }],
    data: { jobId: 'job-1' },
  });
  assert.equal(envelope.eventId, 'event-1');
  assert.equal(envelope.type, 'job.worker_arrived');
  assert.equal(calls.length, 1);
  assert.match(calls[0].sql, /ON CONFLICT\(event_id\) DO NOTHING/);
});
