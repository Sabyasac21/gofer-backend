const path = require('path');

require('dotenv').config({ path: path.resolve(__dirname, '../../../.env') });

const pool = require('../src/config/db');
const {
  readWorkerDocument,
  saveWorkerDocument,
  validateDocumentStorageConfiguration,
} = require('../src/services/documentStorage');
const {
  legacyDocumentBytes,
} = require('../src/services/legacyDocumentPayload');

const apply = process.argv.includes('--apply');
const limitArgument = process.argv.find((argument) => argument.startsWith('--limit='));
const limit = Math.min(
  Math.max(Number.parseInt(limitArgument?.split('=')[1] || '500', 10), 1),
  5000,
);

async function run() {
  const storage = validateDocumentStorageConfiguration();
  if (storage.provider !== 'firebase') {
    throw new Error(
      'Backfill requires DOCUMENT_STORAGE_PROVIDER=firebase to prevent writing another local copy.'
    );
  }

  const result = await pool.query(
    `
      SELECT wd.id,
             wd.worker_enrollment_id AS "enrollmentId",
             wd.document_type AS "documentType",
             wd.storage_provider AS "storageProvider",
             wd.storage_key AS "storageKey",
             wd.content_type AS "contentType",
             we.documents AS "legacyDocuments"
      FROM worker_documents wd
      JOIN worker_enrollments we ON we.id = wd.worker_enrollment_id
      WHERE wd.storage_provider <> 'firebase'
      ORDER BY wd.uploaded_at ASC
      LIMIT $1
    `,
    [limit],
  );

  const summary = {
    mode: apply ? 'apply' : 'dry-run',
    candidates: result.rowCount,
    recoverable: 0,
    migrated: 0,
    missing: 0,
    failed: 0,
  };

  for (const document of result.rows) {
    let bytes = legacyDocumentBytes(
      document.legacyDocuments,
      document.documentType,
    );
    if (!bytes) {
      try {
        bytes = await readWorkerDocument(document);
      } catch (_) {
        bytes = null;
      }
    }
    if (!bytes) {
      summary.missing += 1;
      continue;
    }

    summary.recoverable += 1;
    if (!apply) continue;

    try {
      const stored = await saveWorkerDocument({
        enrollmentId: document.enrollmentId,
        documentType: document.documentType,
        contentType: document.contentType || 'image/jpeg',
        bytes,
      });
      const update = await pool.query(
        `
          UPDATE worker_documents
          SET storage_provider = $1,
              storage_key = $2,
              file_size_bytes = $3,
              updated_at = NOW()
          WHERE id = $4 AND storage_provider = $5
        `,
        [
          stored.storageProvider,
          stored.storageKey,
          bytes.length,
          document.id,
          document.storageProvider,
        ],
      );
      if (update.rowCount === 1) summary.migrated += 1;
      else summary.failed += 1;
    } catch (error) {
      summary.failed += 1;
      console.error(`Failed document ${document.id}: ${error.message}`);
    }
  }

  console.log(JSON.stringify(summary, null, 2));
  if (!apply) {
    console.log('Dry run only. Re-run with --apply after reviewing the counts.');
  }
  if (summary.failed > 0) process.exitCode = 1;
}

run()
  .catch((error) => {
    console.error(error.message);
    process.exitCode = 1;
  })
  .finally(() => pool.end());
