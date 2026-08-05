const test = require('node:test');
const assert = require('node:assert/strict');

const {
  permanentlyDeleteWorker,
  WorkerDeletionError,
} = require('./workerDeletion');

const workerId = '11111111-1111-4111-8111-111111111111';

function fakeClient({ phone = '9876543210' } = {}) {
  const calls = [];
  return {
    calls,
    async query(sql, params = []) {
      const normalized = sql.replace(/\s+/g, ' ').trim();
      calls.push({ sql: normalized, params });
      if (normalized.startsWith('SELECT id, phone')) {
        return phone ? { rowCount: 1, rows: [{ id: workerId, phone }] } : { rowCount: 0, rows: [] };
      }
      if (normalized.startsWith('SELECT storage_provider')) {
        return {
          rowCount: 1,
          rows: [{ storageProvider: 'firebase', storageKey: `worker-documents/${workerId}/front.jpg` }],
        };
      }
      if (normalized.startsWith('SELECT (SELECT COUNT')) {
        return {
          rowCount: 1,
          rows: [{ documents: 3, consents: 1, kycVerifications: 2, jobOffers: 4, auditLogs: 2 }],
        };
      }
      if (normalized.startsWith('UPDATE worker_job_dispatches') && normalized.includes('accepted_worker_id = NULL')) {
        return { rowCount: 1, rows: [{ id: 'job-id' }] };
      }
      if (normalized.startsWith('DELETE FROM worker_enrollments')) {
        return { rowCount: 1, rows: [{ id: workerId }] };
      }
      return { rowCount: 0, rows: [] };
    },
  };
}

test('permanently deletes a confirmed worker and records a non-PII audit summary', async () => {
  const client = fakeClient();
  let storageInput;
  const summary = await permanentlyDeleteWorker({
    client,
    workerId,
    expectedPhone: '9876543210',
    adminId: 'admin-1',
    requestId: 'request-1',
    deleteStoredDocuments: async (input) => { storageInput = input; },
  });

  assert.equal(summary.documents, 3);
  assert.equal(summary.detachedJobs, 1);
  assert.equal(storageInput.enrollmentId, workerId);
  assert.equal(storageInput.documents.length, 1);
  assert.ok(client.calls.some((call) => call.sql === 'COMMIT'));
  assert.ok(!client.calls.some((call) => call.sql === 'ROLLBACK'));
  const auditCall = client.calls.find((call) => call.sql.startsWith('INSERT INTO admin_audit_logs'));
  assert.ok(auditCall);
  assert.doesNotMatch(auditCall.params[1], /9876543210|11111111-1111/);
});

test('rejects stale worker confirmation and rolls back without deleting files', async () => {
  const client = fakeClient({ phone: '9999999999' });
  let storageCalled = false;

  await assert.rejects(
    permanentlyDeleteWorker({
      client,
      workerId,
      expectedPhone: '9876543210',
      adminId: 'admin-1',
      requestId: 'request-2',
      deleteStoredDocuments: async () => { storageCalled = true; },
    }),
    (error) => error instanceof WorkerDeletionError
      && error.code === 'WORKER_CONFIRMATION_MISMATCH',
  );

  assert.equal(storageCalled, false);
  assert.ok(client.calls.some((call) => call.sql === 'ROLLBACK'));
  assert.ok(!client.calls.some((call) => call.sql === 'COMMIT'));
});

test('rolls back database removal if protected file deletion fails', async () => {
  const client = fakeClient();
  await assert.rejects(
    permanentlyDeleteWorker({
      client,
      workerId,
      expectedPhone: '9876543210',
      adminId: 'admin-1',
      requestId: 'request-3',
      deleteStoredDocuments: async () => { throw new Error('storage unavailable'); },
    }),
    /storage unavailable/,
  );
  assert.ok(client.calls.some((call) => call.sql === 'ROLLBACK'));
  assert.ok(!client.calls.some((call) => call.sql === 'COMMIT'));
});
