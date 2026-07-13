const test = require('node:test');
const assert = require('node:assert/strict');
const { canWorkerTransition } = require('./jobLifecycle');
const {
  summarizeMessagingResponses,
  isInvalidRegistrationToken,
} = require('./firebaseDiagnostics');

test('allows only sequential worker progress', () => {
  for (const [current, next] of [
    ['accepted', 'arrived'],
    ['arrived', 'started'],
    ['started', 'completed'],
  ]) {
    assert.equal(canWorkerTransition(current, next), true);
  }
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
