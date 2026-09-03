const test = require('node:test');
const assert = require('node:assert/strict');

const { createWorkerAuth, normalizeIndianPhone } = require('./workerAuth');

function fakeRes() {
  return {
    statusCode: null,
    payload: null,
    status(code) {
      this.statusCode = code;
      return this;
    },
    json(body) {
      this.payload = body;
      return this;
    },
  };
}

function fakeReq(authorization) {
  return {
    get(name) {
      return name.toLowerCase() === 'authorization' ? authorization : undefined;
    },
  };
}

test('normalizeIndianPhone strips +91 and whitespace', () => {
  assert.equal(normalizeIndianPhone('+919876543210'), '9876543210');
  assert.equal(normalizeIndianPhone('9876543210'), '9876543210');
  assert.equal(normalizeIndianPhone('+91 98765 43210'), '9876543210');
  assert.equal(normalizeIndianPhone(null), '');
});

test('accepts a valid token and derives identity from it', async () => {
  const auth = createWorkerAuth({
    verifyIdToken: async (token, checkRevoked) => {
      assert.equal(token, 'good-token');
      assert.equal(checkRevoked, true);
      return { uid: 'firebase-uid-1', phone_number: '+919876543210' };
    },
  });
  const req = fakeReq('Bearer good-token');
  const res = fakeRes();
  let nexted = false;
  await auth(req, res, () => { nexted = true; });

  assert.equal(nexted, true);
  assert.equal(res.statusCode, null);
  assert.equal(req.workerPhone, '9876543210');
  assert.equal(req.firebaseUid, 'firebase-uid-1');
});

test('rejects a request with no Authorization header', async () => {
  const auth = createWorkerAuth({ verifyIdToken: async () => ({}) });
  const req = fakeReq(undefined);
  const res = fakeRes();
  let nexted = false;
  await auth(req, res, () => { nexted = true; });

  assert.equal(nexted, false);
  assert.equal(res.statusCode, 401);
  assert.equal(res.payload.code, 'WORKER_UNAUTHENTICATED');
});

test('rejects a header that is not a Bearer token', async () => {
  const auth = createWorkerAuth({ verifyIdToken: async () => ({}) });
  const req = fakeReq('Basic abc123');
  const res = fakeRes();
  await auth(req, res, () => {});
  assert.equal(res.statusCode, 401);
  assert.equal(res.payload.code, 'WORKER_UNAUTHENTICATED');
});

test('rejects a token the verifier refuses (expired / revoked / forged)', async () => {
  const auth = createWorkerAuth({
    verifyIdToken: async () => { throw new Error('auth/id-token-expired'); },
  });
  const req = fakeReq('Bearer stale');
  const res = fakeRes();
  let nexted = false;
  await auth(req, res, () => { nexted = true; });

  assert.equal(nexted, false);
  assert.equal(res.statusCode, 401);
  assert.equal(res.payload.code, 'WORKER_TOKEN_INVALID');
});

test('rejects a verified token with no phone number', async () => {
  const auth = createWorkerAuth({
    verifyIdToken: async () => ({ uid: 'u', email: 'x@y.z' }),
  });
  const req = fakeReq('Bearer good');
  const res = fakeRes();
  await auth(req, res, () => {});
  assert.equal(res.statusCode, 401);
  assert.equal(res.payload.code, 'WORKER_PHONE_UNVERIFIED');
});

test('rejects a verified token whose phone is not an Indian mobile', async () => {
  const auth = createWorkerAuth({
    verifyIdToken: async () => ({ uid: 'u', phone_number: '+14155550100' }),
  });
  const req = fakeReq('Bearer good');
  const res = fakeRes();
  await auth(req, res, () => {});
  assert.equal(res.statusCode, 401);
  assert.equal(res.payload.code, 'WORKER_PHONE_UNVERIFIED');
});
