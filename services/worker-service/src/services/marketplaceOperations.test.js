const test = require('node:test');
const assert = require('node:assert/strict');

const { platformFeeFor, replaceOpenSegment } = require('./marketplaceOperations');
const {
  MarketplaceError,
  authenticateCustomer,
  hashToken,
  requireStatus,
} = require('./marketplaceTransaction');

test('customer sessions are authenticated by token hash', async () => {
  const token = 'opaque-session-token';
  const pool = {
    async query(_sql, values) {
      assert.deepEqual(values, ['customer-1', hashToken(token)]);
      return { rowCount: 1, rows: [{ exists: true }] };
    },
  };
  assert.equal(await authenticateCustomer(pool, 'customer-1', token), true);
  assert.equal(await authenticateCustomer(pool, '', token), false);
  assert.equal(await authenticateCustomer(pool, 'customer-1', ''), false);
});

test('invalid lifecycle transitions return a stable conflict code', () => {
  assert.throws(
    () => requireStatus({ status: 'completed' }, ['started']),
    (error) => error instanceof MarketplaceError &&
      error.statusCode === 409 && error.code === 'INVALID_JOB_STATE'
  );
});

test('platform fee is derived only from backend basis-point configuration', () => {
  const previous = process.env.WORKIDA_PLATFORM_FEE_BPS;
  try {
    process.env.WORKIDA_PLATFORM_FEE_BPS = '1250';
    assert.equal(platformFeeFor(800), 100);
    process.env.WORKIDA_PLATFORM_FEE_BPS = '10001';
    assert.throws(() => platformFeeFor(800), /Invalid platform fee/);
  } finally {
    if (previous === undefined) delete process.env.WORKIDA_PLATFORM_FEE_BPS;
    else process.env.WORKIDA_PLATFORM_FEE_BPS = previous;
  }
});

test('retrying a time segment idempotency key does not close the open segment', async () => {
  const existing = { id: 'segment-1', segment_type: 'working' };
  const calls = [];
  const client = {
    async query(sql, values) {
      calls.push({ sql, values });
      return { rowCount: 1, rows: [existing] };
    },
  };
  const result = await replaceOpenSegment(
    client, 'job-1', 'working', 'retry', 'worker', 'worker-1', 'key-1'
  );
  assert.equal(result, existing);
  assert.equal(calls.length, 1);
  assert.match(calls[0].sql, /idempotency_key/);
});

test('starting a new segment atomically closes the old one', async () => {
  const calls = [];
  const client = {
    async query(sql, values) {
      calls.push({ sql, values });
      if (calls.length === 1) return { rowCount: 0, rows: [] };
      if (calls.length === 3) {
        return { rowCount: 1, rows: [{ id: 'segment-2', segment_type: 'customer_waiting' }] };
      }
      return { rowCount: 1, rows: [] };
    },
  };
  const result = await replaceOpenSegment(
    client, 'job-1', 'customer_waiting', 'Customer unavailable',
    'worker', 'worker-1', 'key-2'
  );
  assert.equal(result.id, 'segment-2');
  assert.match(calls[1].sql, /ended_at IS NULL/);
  assert.match(calls[2].sql, /INSERT INTO marketplace_time_segments/);
});
