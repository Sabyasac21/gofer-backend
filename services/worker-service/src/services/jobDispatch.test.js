const test = require('node:test');
const assert = require('node:assert/strict');
const { canWorkerTransition } = require('./jobLifecycle');
const {
  summarizeMessagingResponses,
  isInvalidRegistrationToken,
} = require('./firebaseDiagnostics');
const { getPendingWorkerJob } = require('./pendingJob');

test('allows only sequential worker progress', () => {
  for (const [current, next] of [
    ['accepted', 'arrived'],
    ['arrived', 'started'],
    ['started', 'completion_requested'],
    ['started', 'completed'],
  ]) {
    assert.equal(canWorkerTransition(current, next), true);
  }
});

test('worker may cancel before work starts but not after starting', () => {
  assert.equal(canWorkerTransition('accepted', 'cancelled'), true);
  assert.equal(canWorkerTransition('arrived', 'cancelled'), true);
  assert.equal(canWorkerTransition('started', 'cancelled'), false);
});

test('rejects skipped and reversed worker transitions', () => {
  for (const [current, next] of [
    ['accepted', 'completed'],
    ['accepted', 'started'],
    ['arrived', 'completed'],
    ['completed', 'started'],
    ['cancelled', 'arrived'],
    ['offered', 'started'],
  ]) {
    assert.equal(canWorkerTransition(current, next), false);
  }
});

test('terminal jobs cannot be revived', () => {
  for (const terminal of ['completed', 'cancelled', 'expired']) {
    for (const next of ['accepted', 'arrived', 'started', 'completed']) {
      assert.equal(canWorkerTransition(terminal, next), false);
    }
  }
});

test('customer confirmation state cannot be advanced by the worker', () => {
  assert.equal(canWorkerTransition('completion_requested', 'completed'), false);
  assert.equal(canWorkerTransition('completion_requested', 'started'), false);
  assert.equal(canWorkerTransition('completion_requested', 'cancelled'), false);
});

test('summarizes Firebase failures without exposing registration tokens', () => {
  const summary = summarizeMessagingResponses({
    responses: [
      { success: true },
      {
        success: false,
        error: { code: 'messaging/registration-token-not-registered' },
      },
      {
        success: false,
        error: { code: 'messaging/mismatched-credential' },
      },
    ],
  }, [
    { id: 'worker-1', fcm_token: 'secret-token-1' },
    { id: 'worker-2', fcm_token: 'secret-token-2' },
    { id: 'worker-3', fcm_token: 'secret-token-3' },
  ]);

  assert.deepEqual(summary.failureCodes, {
    'messaging/registration-token-not-registered': 1,
    'messaging/mismatched-credential': 1,
  });
  assert.deepEqual(summary.failures, [
    {
      workerId: 'worker-2',
      code: 'messaging/registration-token-not-registered',
      invalidToken: true,
    },
    {
      workerId: 'worker-3',
      code: 'messaging/mismatched-credential',
      invalidToken: false,
    },
  ]);
  assert.equal(JSON.stringify(summary).includes('secret-token'), false);
});

test('only definitive Firebase registration errors retire a worker token', () => {
  assert.equal(isInvalidRegistrationToken('messaging/invalid-registration-token'), true);
  assert.equal(isInvalidRegistrationToken('messaging/registration-token-not-registered'), true);
  assert.equal(isInvalidRegistrationToken('messaging/mismatched-credential'), false);
  assert.equal(isInvalidRegistrationToken('messaging/server-unavailable'), false);
});

test('pending job recovery returns the active offer for the worker phone', async () => {
  const recovered = {
    id: 'job-1',
    workType: 'Cleaning',
    customerArea: 'Sector 62',
    distanceKm: 1.2,
    durationLabel: 'New request',
    payMin: 500,
    payMax: 500,
    notes: '',
    status: 'offered',
    expiresAt: new Date(Date.now() + 120000),
  };
  const calls = [];
  const pool = {
    async query(sql, values) {
      calls.push({ sql, values });
      if (calls.length < 3) return { rowCount: 0, rows: [] };
      return { rowCount: 1, rows: [recovered] };
    },
  };

  const result = await getPendingWorkerJob(pool, '9876543210');

  assert.equal(calls.length, 3);
  assert.deepEqual(calls[2].values, ['9876543210']);
  assert.equal(result.id, 'job-1');
  assert.match(calls[2].sql, /d\.expires_at > NOW\(\)/);
  assert.match(calls[2].sql, /d\.accepted_worker_id = we\.id/);
  assert.match(calls[2].sql, /completion_requested/);
  assert.match(
    calls[2].sql,
    /CASE WHEN d\.status = 'offered' THEN d\.expires_at ELSE NULL END/,
  );
});
