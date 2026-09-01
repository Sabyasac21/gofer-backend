const assert = require('node:assert/strict');
const test = require('node:test');
const express = require('express');

const { createCustomerRouter } = require('./customer.routes');

function testServer(pool) {
  const app = express();
  app.use(express.json());
  app.use('/api', createCustomerRouter(pool));
  const server = app.listen(0);
  const { port } = server.address();
  return {
    close: () => new Promise((resolve) => server.close(resolve)),
    url: `http://127.0.0.1:${port}`,
  };
}

test('customer session creates a token while storing only its hash', async () => {
  const calls = [];
  const pool = {
    async query(sql, params) {
      calls.push({ sql, params });
      if (sql.startsWith('INSERT INTO gofer_customers')) {
        return {
          rowCount: 1,
          rows: [{
            id: '11111111-1111-4111-8111-111111111111',
            name: params[0],
            phone: null,
            phone_verified_at: null,
            created_at: new Date('2026-09-01T00:00:00Z'),
            updated_at: new Date('2026-09-01T00:00:00Z'),
          }],
        };
      }
      throw new Error(`Unexpected query: ${sql}`);
    },
  };
  const server = testServer(pool);
  try {
    const response = await fetch(`${server.url}/api/customers/session`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ name: 'Test customer' }),
    });
    const body = await response.json();
    assert.equal(response.status, 200);
    assert.equal(body.customer.name, 'Test customer');
    assert.ok(body.sessionToken.length >= 32);
    assert.match(calls[0].params[1], /^[a-f0-9]{64}$/);
    assert.notEqual(calls[0].params[1], body.sessionToken);
  } finally {
    await server.close();
  }
});

test('customer routes return the response shape expected by the Flutter client', async () => {
  const pool = { query: async () => { throw new Error('database should not be called'); } };
  const server = testServer(pool);
  try {
    const response = await fetch(`${server.url}/api/customers/session`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ name: 'x' }),
    });
    const body = await response.json();
    assert.equal(response.status, 400);
    assert.equal(body.success, false);
    assert.equal(body.code, 'VALIDATION_ERROR');
    assert.equal(typeof body.message, 'string');
  } finally {
    await server.close();
  }
});
