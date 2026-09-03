const test = require('node:test');
const assert = require('node:assert/strict');
const express = require('express');

const { createWorkerAccountRouter } = require('./workerAccount.routes');

const WORKER_ID = '11111111-1111-4111-8111-111111111111';
const REQUEST_ID = '22222222-2222-4222-8222-222222222222';
const TOKEN_PHONE = '9876543210';

function makePool({
  enrollmentRows = 1,
  activeJobRows = 0,
  requestRows = 1,
  phone = TOKEN_PHONE,
} = {}) {
  const calls = [];
  const respond = (sql) => {
    const s = sql.replace(/\s+/g, ' ').trim();
    if (s.startsWith('SELECT id FROM worker_enrollments WHERE phone')) {
      return enrollmentRows
        ? { rowCount: 1, rows: [{ id: WORKER_ID }] }
        : { rowCount: 0, rows: [] };
    }
    if (s.startsWith('SELECT id, phone, status FROM worker_deletion_requests')) {
      return requestRows
        ? { rowCount: 1, rows: [{ id: REQUEST_ID, phone, status: 'pending' }] }
        : { rowCount: 0, rows: [] };
    }
    if (s.startsWith('SELECT id FROM worker_job_dispatches')) {
      return activeJobRows
        ? { rowCount: 1, rows: [{ id: 'job-1' }] }
        : { rowCount: 0, rows: [] };
    }
    if (s.startsWith('SELECT id, phone FROM worker_enrollments')) {
      return { rowCount: 1, rows: [{ id: WORKER_ID, phone }] };
    }
    if (s.startsWith('SELECT storage_provider')) return { rowCount: 0, rows: [] };
    if (s.startsWith('SELECT (SELECT COUNT')) {
      return {
        rowCount: 1,
        rows: [{ documents: 3, consents: 1, kycVerifications: 1, jobOffers: 2, auditLogs: 1 }],
      };
    }
    if (s.startsWith('DELETE FROM worker_enrollments')) {
      return { rowCount: 1, rows: [{ id: WORKER_ID }] };
    }
    if (s.startsWith('INSERT INTO worker_deletion_requests')) {
      return { rowCount: 1, rows: [{ id: 'req-1', requestedAt: new Date('2026-09-03T00:00:00Z') }] };
    }
    return { rowCount: 0, rows: [] };
  };
  const query = async (sql, params = []) => {
    calls.push({ sql: sql.replace(/\s+/g, ' ').trim(), params });
    return respond(sql);
  };
  return {
    calls,
    query,
    connect: async () => ({ query, release() {} }),
  };
}

function testServer(pool, {
  tokenPhone = TOKEN_PHONE,
  firebaseUid = 'uid-1',
  firebaseDeleteError = null,
  firebaseLookupError = null,
} = {}) {
  const deletedUsers = [];
  const workerAuth = (req, res, next) => {
    if (!tokenPhone) {
      return res.status(401).json({ success: false, code: 'WORKER_UNAUTHENTICATED' });
    }
    req.workerPhone = tokenPhone;
    req.firebaseUid = firebaseUid;
    req.requestId = 'test-request';
    return next();
  };
  const app = express();
  app.use(express.json());
  app.use('/api', createWorkerAccountRouter(pool, {
    workerAuth,
    deleteStoredDocuments: async () => {},
    deleteFirebaseUser: async (uid) => {
      deletedUsers.push(uid);
      if (firebaseDeleteError) throw firebaseDeleteError;
    },
    findFirebaseUserByPhone: async () => {
      if (firebaseLookupError) throw firebaseLookupError;
      return { uid: 'uid-by-phone' };
    },
    adminKey: 'test-admin-key',
  }));
  const server = app.listen(0);
  const { port } = server.address();
  return {
    deletedUsers,
    close: () => new Promise((r) => server.close(r)),
    url: `http://127.0.0.1:${port}`,
  };
}

test('DELETE /api/workers/me requires a verified token', async () => {
  const server = testServer(makePool(), { tokenPhone: null });
  try {
    const res = await fetch(`${server.url}/api/workers/me`, { method: 'DELETE' });
    assert.equal(res.status, 401);
  } finally {
    await server.close();
  }
});

test('DELETE /api/workers/me permanently deletes the caller and their Firebase user', async () => {
  const pool = makePool();
  const server = testServer(pool);
  try {
    const res = await fetch(`${server.url}/api/workers/me`, { method: 'DELETE' });
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(body.deleted, true);
    assert.equal(body.summary.documents, 3);
    assert.deepEqual(server.deletedUsers, ['uid-1']);
    assert.ok(pool.calls.some((c) => c.sql.startsWith('INSERT INTO worker_enrollment_resets')));
    assert.ok(pool.calls.some((c) => c.sql.startsWith('DELETE FROM worker_enrollments')));
    assert.ok(pool.calls.some((c) => c.sql === 'COMMIT'));
  } finally {
    await server.close();
  }
});

test('DELETE /api/workers/me queues Firebase Auth cleanup instead of hiding a failure', async () => {
  const pool = makePool();
  const server = testServer(pool, {
    firebaseDeleteError: new Error('temporary Firebase outage'),
  });
  try {
    const res = await fetch(`${server.url}/api/workers/me`, { method: 'DELETE' });
    assert.equal(res.status, 202);
    const body = await res.json();
    assert.equal(body.deleted, true);
    assert.equal(body.authDeletionPending, true);
    const cleanup = pool.calls.find((c) => (
      c.sql.startsWith('INSERT INTO worker_deletion_requests')
      && c.params[2] === 'in_app_cleanup'
    ));
    assert.deepEqual(cleanup.params, [
      TOKEN_PHONE,
      'Retry deletion of the Firebase Authentication user.',
      'in_app_cleanup',
      'pending_auth_cleanup',
    ]);
  } finally {
    await server.close();
  }
});

test('DELETE /api/workers/me refuses while a job is in progress', async () => {
  const pool = makePool({ activeJobRows: 1 });
  const server = testServer(pool);
  try {
    const res = await fetch(`${server.url}/api/workers/me`, { method: 'DELETE' });
    assert.equal(res.status, 409);
    const body = await res.json();
    assert.equal(body.code, 'ACTIVE_JOB');
    assert.ok(!pool.calls.some((c) => c.sql.startsWith('DELETE FROM worker_enrollments')));
    assert.deepEqual(server.deletedUsers, []);
  } finally {
    await server.close();
  }
});

test('DELETE /api/workers/me returns 404 when the number has no enrollment', async () => {
  const server = testServer(makePool({ enrollmentRows: 0 }));
  try {
    const res = await fetch(`${server.url}/api/workers/me`, { method: 'DELETE' });
    assert.equal(res.status, 404);
    const body = await res.json();
    assert.equal(body.code, 'WORKER_NOT_FOUND');
  } finally {
    await server.close();
  }
});

test('POST /api/workers/deletion-requests records a valid request', async () => {
  const pool = makePool();
  const server = testServer(pool);
  try {
    const res = await fetch(`${server.url}/api/workers/deletion-requests`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ phone: '9811111111', reason: 'No longer working' }),
    });
    assert.equal(res.status, 202);
    const body = await res.json();
    assert.equal(body.requestId, 'req-1');
    const insert = pool.calls.find((c) => c.sql.startsWith('INSERT INTO worker_deletion_requests'));
    assert.deepEqual(insert.params, [
      '9811111111',
      'No longer working',
      'web',
      'pending',
    ]);
  } finally {
    await server.close();
  }
});

test('POST /api/workers/deletion-requests rejects a malformed number', async () => {
  const server = testServer(makePool());
  try {
    const res = await fetch(`${server.url}/api/workers/deletion-requests`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ phone: '123' }),
    });
    assert.equal(res.status, 400);
  } finally {
    await server.close();
  }
});

test('POST /api/admin/deletion-requests/:id/complete requires ownership verification', async () => {
  const server = testServer(makePool());
  try {
    const res = await fetch(
      `${server.url}/api/admin/deletion-requests/${REQUEST_ID}/complete`,
      {
        method: 'POST',
        headers: {
          'content-type': 'application/json',
          'x-admin-key': 'test-admin-key',
        },
        body: JSON.stringify({ confirmation: 'DELETE', ownershipVerified: false }),
      },
    );
    assert.equal(res.status, 400);
  } finally {
    await server.close();
  }
});

test('POST /api/admin/deletion-requests/:id/complete deletes data after verification', async () => {
  const pool = makePool();
  const server = testServer(pool);
  try {
    const res = await fetch(
      `${server.url}/api/admin/deletion-requests/${REQUEST_ID}/complete`,
      {
        method: 'POST',
        headers: {
          'content-type': 'application/json',
          'x-admin-key': 'test-admin-key',
          'x-admin-id': 'reviewer-1',
        },
        body: JSON.stringify({ confirmation: 'DELETE', ownershipVerified: true }),
      },
    );
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(body.status, 'resolved');
    assert.deepEqual(server.deletedUsers, ['uid-by-phone']);
    assert.ok(pool.calls.some((c) => c.sql.startsWith('DELETE FROM worker_enrollments')));
    assert.ok(pool.calls.some((c) => (
      c.sql.startsWith('UPDATE worker_deletion_requests')
      && c.params[0] === REQUEST_ID
      && c.params[1] === 'resolved'
    )));
  } finally {
    await server.close();
  }
});
