const test = require('node:test');
const assert = require('node:assert/strict');
const { canWorkerTransition } = require('./jobLifecycle');
const {
  summarizeMessagingResponses,
  isInvalidRegistrationToken,
} = require('./firebaseDiagnostics');
const { getPendingWorkerJob } = require('./pendingJob');
const {
  cancelAndRematchJob,
  MAX_REPLACEMENT_ATTEMPTS,
  updatePresence,
} = require('./jobDispatch');

test('presence SQL explicitly types coordinates used by CASE expressions',
    async () => {
  for (const coordinates of [
    { latitude: 22.7196, longitude: 75.8577 },
    { latitude: null, longitude: null },
  ]) {
    const calls = [];
    const pool = {
      async query(sql, values) {
        calls.push({ sql, values });
        if (calls.length === 1) {
          return {
            rowCount: 1,
            rows: [{ id: '11111111-1111-1111-1111-111111111111' }],
          };
        }
        return {
          rowCount: 1,
          rows: [{
            workerId: '11111111-1111-1111-1111-111111111111',
            online: true,
          }],
        };
      },
    };

    const result = await updatePresence(pool, {
      phone: '9876543210',
      online: true,
      fcmToken: 'test-token',
      platform: 'android',
      ...coordinates,
    });

    assert.equal(result.online, true);
    assert.equal(calls.length, 2);
    assert.match(calls[1].sql, /\$5::double precision/);
    assert.match(calls[1].sql, /\$6::double precision/);
    assert.match(calls[1].sql, /\$4::boolean/);
    assert.deepEqual(calls[1].values.slice(4), [
      coordinates.latitude,
      coordinates.longitude,
    ]);
  }
});

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

function cancellationPool({
  replacementAttempts = 0,
  candidates = [],
  alreadyCancelled = false,
} = {}) {
  const calls = [];
  const client = {
    async query(sql, values) {
      calls.push({ sql, values });
      if (sql === 'BEGIN' || sql === 'COMMIT' || sql === 'ROLLBACK') {
        return { rowCount: 0, rows: [] };
      }
      if (sql.includes('SELECT id FROM worker_enrollments')) {
        return { rowCount: 1, rows: [{ id: '11111111-1111-1111-1111-111111111111' }] };
      }
      if (sql.includes('SELECT *') && sql.includes('FOR UPDATE')) {
        if (alreadyCancelled) return { rowCount: 0, rows: [] };
        return {
          rowCount: 1,
          rows: [{
            id: '22222222-2222-2222-2222-222222222222',
            customer_task_id: '33333333-3333-3333-3333-333333333333',
            service_type: 'helper',
            category: 'Cleaning',
            title: 'Cleaning',
            notes: '',
            address_text: 'Noida',
            latitude: 28.6,
            longitude: 77.3,
            budget: 500,
            replacement_attempts: replacementAttempts,
            excluded_worker_ids: [],
          }],
        };
      }
      if (sql.includes('worker_offer.status') && alreadyCancelled) {
        return {
          rowCount: 1,
          rows: [{
            id: '22222222-2222-2222-2222-222222222222',
            customer_task_id: '33333333-3333-3333-3333-333333333333',
            status: 'offered',
            replacement_attempts: 1,
            matched_workers: 2,
          }],
        };
      }
      if (sql.includes('UPDATE worker_job_dispatches') && sql.includes('replacement_attempts')) {
        const canRematch = values[5];
        return {
          rowCount: 1,
          rows: [{
            id: values[0],
            customer_task_id: '33333333-3333-3333-3333-333333333333',
            status: canRematch ? 'offered' : 'expired',
            title: 'Cleaning',
            category: 'Cleaning',
            notes: '',
            address_text: 'Noida',
            budget: 500,
            expires_at: new Date(Date.now() + 120000),
          }],
        };
      }
      if (sql.includes('SELECT we.id, wp.fcm_token')) {
        return { rowCount: candidates.length, rows: candidates };
      }
      return { rowCount: 1, rows: [] };
    },
    release() {},
  };
  return {
    calls,
    pool: {
      async connect() {
        return client;
      },
      async query() {
        return { rowCount: 0, rows: [] };
      },
    },
  };
}

test('worker cancellation atomically starts a two-minute replacement search', async () => {
  const replacement = {
    id: '44444444-4444-4444-4444-444444444444',
    fcm_token: 'replacement-token',
    distance_km: 1.5,
  };
  const { pool, calls } = cancellationPool({ candidates: [replacement] });

  const result = await cancelAndRematchJob(
    pool,
    '22222222-2222-2222-2222-222222222222',
    '9876543210',
  );

  assert.equal(result.status, 'offered');
  assert.equal(result.rematching, true);
  assert.equal(result.replacementAttempts, 1);
  assert.equal(result.matchedWorkers, 1);
  const update = calls.find(({ sql }) =>
    sql.includes('UPDATE worker_job_dispatches') &&
    sql.includes('replacement_attempts'));
  assert.equal(update.values[5], true);
  assert.match(update.sql, /NOW\(\) \+ INTERVAL '2 minutes'/);
  assert.ok(calls.some(({ sql }) => sql.includes("status='cancelled'")));
  assert.ok(calls.some(({ sql }) => sql.includes('ON CONFLICT')));
  assert.equal(calls.at(-1).sql, 'COMMIT');
});

test('replacement search stops after the configured automatic limit', async () => {
  const { pool, calls } = cancellationPool({
    replacementAttempts: MAX_REPLACEMENT_ATTEMPTS,
  });

  const result = await cancelAndRematchJob(
    pool,
    '22222222-2222-2222-2222-222222222222',
    '9876543210',
  );

  assert.equal(result.status, 'expired');
  assert.equal(result.rematching, false);
  assert.equal(result.replacementAttempts, MAX_REPLACEMENT_ATTEMPTS + 1);
  assert.equal(
    calls.some(({ sql }) => sql.includes('SELECT we.id, wp.fcm_token')),
    false,
  );
});

test('duplicate worker cancellation is idempotent and does not send twice', async () => {
  const { pool, calls } = cancellationPool({ alreadyCancelled: true });

  const result = await cancelAndRematchJob(
    pool,
    '22222222-2222-2222-2222-222222222222',
    '9876543210',
  );

  assert.equal(result.status, 'offered');
  assert.equal(result.rematching, true);
  assert.equal(result.existing, true);
  assert.equal(result.push.attempted, 0);
  assert.equal(calls.at(-1).sql, 'COMMIT');
  assert.equal(
    calls.some(({ sql }) => sql.includes('replacement_attempts=$4')),
    false,
  );
});
