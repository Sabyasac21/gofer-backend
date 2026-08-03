# Worker Document Storage

Worker ID images and selfies are private verification data. Production stores
them as non-public Firebase Storage objects and only serves them through the
admin-authenticated worker-service preview endpoint.

## Production configuration

Configure these secrets/environment variables on the worker-service:

```text
NODE_ENV=production
DOCUMENT_STORAGE_PROVIDER=firebase
FIREBASE_STORAGE_BUCKET=<project bucket name>
FIREBASE_SERVICE_ACCOUNT_JSON=<raw service-account JSON>
DOCUMENT_FIELD_ENCRYPTION_KEY=<base64-encoded 32-byte key>
```

The service account must be able to create and read objects in the configured
bucket. Do not make the bucket public and do not generate public download URLs.
The service fails at startup when production Firebase storage configuration is
missing. `/health` reports the active provider without exposing credentials or
object names.

`DOCUMENT_FIELD_ENCRYPTION_KEY` protects full OCR-extracted ID numbers with
AES-256-GCM. Generate it once with
`node -e "console.log(require('crypto').randomBytes(32).toString('base64'))"`,
store it only in the worker-service secret manager, and back it up securely.
Losing this key makes encrypted ID numbers unrecoverable. Rotating it requires
decrypting and re-encrypting existing values first.

`local_mock` remains available for Docker/local development. Its files are
stored below `DOCUMENT_STORAGE_ROOT`, which Docker Compose mounts from
`./storage/worker-documents`.

## Recover and backfill existing workers

The migration command is dry-run by default. It checks the legacy Base64 copy
first and the old local file second; it never prints image data or worker PII.

```powershell
cd services/worker-service
$env:DOCUMENT_STORAGE_PROVIDER='firebase'
$env:FIREBASE_STORAGE_BUCKET='<project bucket name>'
npm run documents:backfill
```

Review the candidate, recoverable, and missing counts. Then apply:

```powershell
npm run documents:backfill -- --apply
```

The operation is idempotent: records already marked `firebase` are skipped,
and each database row is updated only if its original provider has not changed.
Use `--limit=100` for a smaller batch.

After deployment and backfill:

1. Open several front-ID, back-ID, and selfie previews in the admin.
2. Confirm the matching `worker_documents.storage_provider` values are
   `firebase` and the backfill reports no failed items.
3. Retain a protected database backup for the agreed compliance window.
4. Remove legacy `contentBase64` fields from `worker_enrollments.documents`
   only after storage and backup verification. New enrollments no longer write
   Base64 into this JSON column.

The preview endpoint temporarily falls back to legacy database payloads for old
records whose local files are gone. The admin now displays the actual protected
preview error when neither copy can be recovered.
