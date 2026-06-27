const fs = require('fs/promises');
const path = require('path');

const STORAGE_PROVIDER = process.env.DOCUMENT_STORAGE_PROVIDER || 'local_mock';
const STORAGE_ROOT = process.env.DOCUMENT_STORAGE_ROOT || '/app/storage/worker-documents';

function extensionForContentType(contentType) {
  if (contentType === 'image/png') return 'png';
  if (contentType === 'image/heic') return 'heic';
  if (contentType === 'image/heif') return 'heif';
  return 'jpg';
}

async function saveWorkerDocument({
  enrollmentId,
  documentType,
  contentType,
  bytes,
}) {
  const extension = extensionForContentType(contentType);
  const safeType = documentType.replace(/[^a-zA-Z0-9_-]/g, '-');
  const relativeKey = `${enrollmentId}/${safeType}-${Date.now()}.${extension}`;
  const absolutePath = path.join(STORAGE_ROOT, relativeKey);

  await fs.mkdir(path.dirname(absolutePath), { recursive: true });
  await fs.writeFile(absolutePath, bytes);

  return {
    storageProvider: STORAGE_PROVIDER,
    storageKey:
      STORAGE_PROVIDER === 'firebase'
        ? `worker-documents/${relativeKey}`
        : absolutePath,
  };
}

module.exports = {
  saveWorkerDocument,
};
