const test = require('node:test');
const assert = require('node:assert/strict');
const { validateScheduledAt } = require('./workidaScheduling');

const nowMs = Date.parse('2026-08-23T04:37:00.000Z'); // 10:07 in India.

test('today accepts a future time before India midnight', () => {
  assert.equal(
    validateScheduledAt({ urgency: 'today', scheduledAt: '2026-08-23T18:29:00.000Z', nowMs }),
    '2026-08-23T18:29:00.000Z',
  );
  assert.throws(
    () => validateScheduledAt({ urgency: 'today', scheduledAt: '2026-08-23T18:30:00.000Z', nowMs }),
    /before midnight today/,
  );
});

test('later allows only the following three India calendar days', () => {
  for (const value of [
    '2026-08-23T18:30:00.000Z',
    '2026-08-24T18:30:00.000Z',
    '2026-08-26T18:29:00.000Z',
  ]) assert.doesNotThrow(() => validateScheduledAt({ urgency: 'scheduled', scheduledAt: value, nowMs }));
  assert.throws(
    () => validateScheduledAt({ urgency: 'scheduled', scheduledAt: '2026-08-26T18:30:00.000Z', nowMs }),
    /next three/,
  );
});

test('now rejects a hidden scheduled timestamp', () => {
  assert.throws(
    () => validateScheduledAt({ urgency: 'now', scheduledAt: '2026-08-23T10:00:00.000Z', nowMs }),
    /cannot include/,
  );
});
