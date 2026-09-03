const test = require('node:test');
const assert = require('node:assert/strict');
const express = require('express');

const { createMarketplaceRouter } = require('./marketplace.routes');

// Mounts the marketplace router with an injectable workerAuth and a capturing
// pool so we can assert the worker phone comes from the token, not the request.
function testServer({ tokenPhone } = {}) {
  const queries = [];
  const pool = {
    async query(sql, params = []) {
      queries.push({ sql, params });
      return { rowCount: 0, rows: [] };
    },
  };
  const workerAuth = (req, res, next) => {
    if (!tokenPhone) {
      return res.status(401).json({ success: false, code: 'WORKER_UNAUTHENTICATED' });
    }
    req.workerPhone = tokenPhone;
    req.firebaseUid = 'uid-under-test';
    return next();
  };

  const app = express();
  app.use(express.json());
  app.use('/api/marketplace', createMarketplaceRouter(pool, { workerAuth }));
  const server = app.listen(0);
  const { port } = server.address();
  return {
    queries,
    close: () => new Promise((resolve) => server.close(resolve)),
    url: `http://127.0.0.1:${port}`,
  };
}

const JOB_ID = '11111111-1111-4111-8111-111111111111';

test('worker marketplace route rejects a request with no verified token', async () => {
  const server = testServer({ tokenPhone: null });
  try {
    const response = await fetch(
      `${server.url}/api/marketplace/jobs/${JOB_ID}?phone=9998887776`,
    );
    assert.equal(response.status, 401);
    const body = await response.json();
    assert.equal(body.code, 'WORKER_UNAUTHENTICATED');
    assert.equal(server.queries.length, 0);
  } finally {
    await server.close();
  }
});

test('worker phone is taken from the token and a spoofed query phone is ignored', async () => {
  const server = testServer({ tokenPhone: '9000000001' });
  try {
    const response = await fetch(
      `${server.url}/api/marketplace/jobs/${JOB_ID}?phone=9998887776`,
    );
    // workerJob returns no row -> 404, but the lookup must have used the token phone.
    assert.equal(response.status, 404);
    const lookup = server.queries.find((q) => /worker_job_dispatches/.test(q.sql));
    assert.ok(lookup, 'expected a worker_job_dispatches lookup');
    assert.deepEqual(lookup.params, [JOB_ID, '9000000001']);
    assert.ok(
      !server.queries.some((q) => q.params.includes('9998887776')),
      'the spoofed query phone must never reach the database',
    );
  } finally {
    await server.close();
  }
});

test('worker POST route overrides any body phone with the token phone', async () => {
  const server = testServer({ tokenPhone: '9000000001' });
  try {
    const response = await fetch(
      `${server.url}/api/marketplace/jobs/${JOB_ID}/requirements`,
      {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({
          phone: '9998887776',
          kind: 'material',
          description: 'Need 2 kg cement',
          reason: 'Not included in the original scope',
          idempotencyKey: '22222222-2222-4222-8222-222222222222',
          segmentIdempotencyKey: '33333333-3333-4333-8333-333333333333',
        }),
      },
    );
    // Reaches marketplaceOperations with the capturing pool; result is not asserted,
    // only that the spoofed phone never appears in a query.
    assert.ok([200, 201, 400, 404, 409, 500].includes(response.status));
    assert.ok(
      !server.queries.some((q) => q.params.includes('9998887776')),
      'the spoofed body phone must never reach the database',
    );
  } finally {
    await server.close();
  }
});
