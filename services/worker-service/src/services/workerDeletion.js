const crypto = require('crypto');

function phoneResetHash(phone) {
  const secret = process.env.WORKER_RESET_HASH_SECRET
    || process.env.WORKER_ADMIN_KEY
    || 'workida-local-reset-secret';
  return crypto.createHmac('sha256', secret).update(phone).digest('hex');
}

async function ensureWorkerDeletionSchema(pool) {
  await pool.query(`
    CREATE TABLE IF NOT EXISTS worker_enrollment_resets (
      phone_hash CHAR(64) PRIMARY KEY,
      deleted_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
  `);
}

class WorkerDeletionError extends Error {
  constructor(message, code, statusCode) {
    super(message);
    this.name = 'WorkerDeletionError';
    this.code = code;
    this.statusCode = statusCode;
  }
}

async function permanentlyDeleteWorker({
  client,
  workerId,
  expectedPhone,
  adminId,
  requestId,
  deleteStoredDocuments,
}) {
  await client.query('BEGIN');
  try {
    const workerResult = await client.query(
      `
        SELECT id, phone
        FROM worker_enrollments
        WHERE id = $1
        FOR UPDATE
      `,
      [workerId],
    );
    if (workerResult.rowCount === 0) {
      throw new WorkerDeletionError(
        'Worker not found',
        'WORKER_NOT_FOUND',
        404,
      );
    }
    if (workerResult.rows[0].phone !== expectedPhone) {
      throw new WorkerDeletionError(
        'Worker details changed. Close the warning and try again.',
        'WORKER_CONFIRMATION_MISMATCH',
        409,
      );
    }

    await client.query(
      `INSERT INTO worker_enrollment_resets(phone_hash, deleted_at)
       VALUES($1, NOW())
       ON CONFLICT(phone_hash) DO UPDATE SET deleted_at = EXCLUDED.deleted_at`,
      [phoneResetHash(expectedPhone)],
    );

    const documentsResult = await client.query(
      `
        SELECT storage_provider AS "storageProvider", storage_key AS "storageKey"
        FROM worker_documents
        WHERE worker_enrollment_id = $1
      `,
      [workerId],
    );
    const countsResult = await client.query(
      `
        SELECT
          (SELECT COUNT(*)::int FROM worker_documents WHERE worker_enrollment_id = $1) AS documents,
          (SELECT COUNT(*)::int FROM worker_consents WHERE worker_enrollment_id = $1) AS consents,
          (SELECT COUNT(*)::int FROM kyc_verifications WHERE worker_enrollment_id = $1) AS "kycVerifications",
          (SELECT COUNT(*)::int FROM worker_job_offers WHERE worker_enrollment_id = $1) AS "jobOffers",
          (SELECT COUNT(*)::int FROM admin_audit_logs WHERE worker_enrollment_id = $1) AS "auditLogs"
      `,
      [workerId],
    );

    const detachedJobs = await client.query(
      `
        UPDATE worker_job_dispatches
        SET
          accepted_worker_id = NULL,
          status = CASE
            WHEN status IN ('accepted', 'arrived', 'started', 'completion_requested')
              THEN 'cancelled'
            ELSE status
          END,
          updated_at = NOW()
        WHERE accepted_worker_id = $1
        RETURNING id
      `,
      [workerId],
    );
    await client.query(
      `
        UPDATE worker_job_dispatches
        SET excluded_worker_ids = array_remove(excluded_worker_ids, $1::uuid)
        WHERE $1::uuid = ANY(excluded_worker_ids)
      `,
      [workerId],
    );
    await client.query(
      'DELETE FROM admin_audit_logs WHERE worker_enrollment_id = $1',
      [workerId],
    );
    const deleted = await client.query(
      'DELETE FROM worker_enrollments WHERE id = $1 RETURNING id',
      [workerId],
    );
    if (deleted.rowCount !== 1) {
      throw new WorkerDeletionError(
        'Worker could not be deleted',
        'WORKER_DELETE_FAILED',
        409,
      );
    }

    await deleteStoredDocuments({
      enrollmentId: workerId,
      documents: documentsResult.rows,
    });

    const summary = {
      ...countsResult.rows[0],
      detachedJobs: detachedJobs.rowCount,
    };
    await client.query(
      `
        INSERT INTO admin_audit_logs (admin_id, action, worker_enrollment_id, details)
        VALUES ($1, 'delete_worker_permanently', NULL, $2::jsonb)
      `,
      [
        adminId,
        JSON.stringify({
          requestId,
          deletedAt: new Date().toISOString(),
          deletedRecordCounts: summary,
        }),
      ],
    );

    await client.query('COMMIT');
    return summary;
  } catch (error) {
    await client.query('ROLLBACK');
    throw error;
  }
}

module.exports = {
  ensureWorkerDeletionSchema,
  permanentlyDeleteWorker,
  phoneResetHash,
  WorkerDeletionError,
};
