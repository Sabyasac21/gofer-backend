// services/worker-service/scripts/seedReviewProfile.js
//
// Seeds a pre-approved worker profile for the Google Play review team so the
// reviewer's Firebase test phone number lands straight on the worker dashboard.
//
// One-time, idempotent. Run against the production database AFTER adding the
// matching "phone number for testing" in Firebase Console:
//
//   node services/worker-service/scripts/seedReviewProfile.js
//   node services/worker-service/scripts/seedReviewProfile.js --phone=9000000001 --remove
//
// See docs/PLAY_REVIEW_ACCESS.md.

const path = require('path');

require('dotenv').config({ path: path.resolve(__dirname, '../../../.env') });

const pool = require('../src/config/db');

const phoneArg = process.argv.find((a) => a.startsWith('--phone='));
const PHONE = (phoneArg ? phoneArg.split('=')[1] : '9000000001').replace(/\D/g, '');
const REMOVE = process.argv.includes('--remove');

if (!/^[6-9]\d{9}$/.test(PHONE)) {
  console.error(`Refusing to run: "${PHONE}" is not a valid 10-digit Indian mobile number.`);
  process.exit(1);
}

async function remove() {
  const existing = await pool.query(
    'SELECT id FROM worker_enrollments WHERE phone = $1',
    [PHONE],
  );
  if (existing.rowCount === 0) {
    console.log(`No review profile found for ${PHONE}. Nothing to remove.`);
    return;
  }
  const id = existing.rows[0].id;
  // FK rows (documents, consents, kyc, offers, presence) cascade on delete.
  await pool.query('DELETE FROM worker_enrollments WHERE id = $1', [id]);
  console.log(`Removed review profile ${id} for ${PHONE}.`);
}

async function seed() {
  const result = await pool.query(
    `
      INSERT INTO worker_enrollments (
        phone, full_name, age, city, work_area, language, experience,
        travel_radius_km, enrollment_types, professional_categories, id_type,
        documents, consent_accepted, consent_version, consent_accepted_at,
        review_status, worker_status, kyc_provider, kyc_status,
        kyc_reference_id, kyc_completed_at, submitted_at, updated_at
      ) VALUES (
        $1, 'Play Review Worker', 30, 'Bengaluru', 'Koramangala', 'English',
        'Beginner', 5, ARRAY['helper']::TEXT[], ARRAY[]::TEXT[], 'aadhaar',
        '{}'::JSONB, TRUE, 'worker-verification-v1', NOW(),
        'approved', 'verified', 'admin_manual', 'verified',
        'play-review-seed', NOW(), NOW(), NOW()
      )
      ON CONFLICT (phone) DO UPDATE SET
        review_status = 'approved',
        worker_status = 'verified',
        kyc_provider = 'admin_manual',
        kyc_status = 'verified',
        kyc_reference_id = 'play-review-seed',
        kyc_completed_at = NOW(),
        updated_at = NOW()
      RETURNING id, phone, worker_status AS "workerStatus"
    `,
    [PHONE],
  );
  // Clear any deletion tombstone so the seeded number is usable immediately.
  await pool.query(
    `DELETE FROM worker_enrollment_resets
     WHERE phone_hash = encode(hmac($1, $2, 'sha256'), 'hex')`,
    [
      PHONE,
      process.env.WORKER_RESET_HASH_SECRET
        || process.env.WORKER_ADMIN_KEY
        || 'workida-local-reset-secret',
    ],
  ).catch(() => { /* pgcrypto hmac may be unavailable; tombstone clear is best-effort */ });

  console.log('Seeded review profile:', result.rows[0]);
  console.log(
    `\nNext: in Firebase Console -> Authentication -> Sign-in method -> Phone,\n`
    + `add test number +91${PHONE} with a fixed 6-digit code, then enter both in\n`
    + `Play Console -> App content -> App access.`,
  );
}

(async () => {
  try {
    if (REMOVE) await remove();
    else await seed();
  } catch (error) {
    console.error('seedReviewProfile failed:', error.message);
    process.exitCode = 1;
  } finally {
    await pool.end();
  }
})();
