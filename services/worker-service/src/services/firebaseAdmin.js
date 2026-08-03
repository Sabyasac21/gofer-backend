const admin = require('firebase-admin');

function getFirebaseApp() {
  if (admin.apps.length) return admin.app();

  const raw = process.env.FIREBASE_SERVICE_ACCOUNT_JSON;
  if (!raw) {
    throw new Error('FIREBASE_SERVICE_ACCOUNT_JSON is not configured');
  }

  let credential;
  try {
    credential = JSON.parse(raw);
  } catch (error) {
    throw new Error(`FIREBASE_SERVICE_ACCOUNT_JSON is invalid: ${error.message}`);
  }

  return admin.initializeApp({ credential: admin.credential.cert(credential) });
}

function getFirebaseAuth() {
  return getFirebaseApp().auth();
}

function getFirebaseStorageBucket() {
  const bucketName = process.env.FIREBASE_STORAGE_BUCKET;
  if (!bucketName) {
    throw new Error('FIREBASE_STORAGE_BUCKET is not configured');
  }
  return getFirebaseApp().storage().bucket(bucketName);
}

module.exports = { getFirebaseApp, getFirebaseAuth, getFirebaseStorageBucket };
