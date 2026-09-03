// services/worker-service/src/middleware/workerAuth.js
//
// Authenticates a worker request from its Firebase ID token. The phone number
// (and therefore the worker identity) is derived from the *verified* token, never
// from client-supplied input. Every worker-facing endpoint must sit behind this.

const { getFirebaseAuth } = require('../services/firebaseAdmin');

const INDIAN_MOBILE = /^[6-9]\d{9}$/;

function normalizeIndianPhone(rawPhoneNumber) {
  return String(rawPhoneNumber || '').replace(/^\+91/, '').replace(/\s+/g, '');
}

/**
 * @param {object} [options]
 * @param {(token: string, checkRevoked?: boolean) => Promise<object>} [options.verifyIdToken]
 *   Injectable for tests. Defaults to Firebase Admin's verifier with revocation checks.
 */
function createWorkerAuth({ verifyIdToken } = {}) {
  const verify = verifyIdToken
    || ((token, checkRevoked) => getFirebaseAuth().verifyIdToken(token, checkRevoked));

  return async function workerAuth(req, res, next) {
    const header = req.get('authorization') || '';
    const token = header.startsWith('Bearer ')
      ? header.slice('Bearer '.length).trim()
      : '';

    if (!token) {
      return res.status(401).json({
        success: false,
        code: 'WORKER_UNAUTHENTICATED',
        message: 'Sign in again to continue.',
      });
    }

    let decoded;
    try {
      decoded = await verify(token, true);
    } catch (error) {
      return res.status(401).json({
        success: false,
        code: 'WORKER_TOKEN_INVALID',
        message: 'Your session has expired. Sign in again.',
      });
    }

    const phone = normalizeIndianPhone(decoded && decoded.phone_number);
    if (!INDIAN_MOBILE.test(phone)) {
      return res.status(401).json({
        success: false,
        code: 'WORKER_PHONE_UNVERIFIED',
        message: 'This account is not linked to a verified mobile number.',
      });
    }

    req.workerPhone = phone;
    req.firebaseUid = decoded.uid;
    return next();
  };
}

module.exports = { createWorkerAuth, normalizeIndianPhone };
