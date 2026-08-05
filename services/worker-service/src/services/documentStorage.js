const fs = require('fs/promises');
const path = require('path');
const { getFirebaseStorageBucket } = require('./firebaseAdmin');

const SUPPORTED_PROVIDERS = new Set(['local_mock', 'firebase']);

class DocumentNotFoundError extends Error {
  constructor(message = 'Document file not found') {
    super(message);
    this.name = 'DocumentNotFoundError';
    this.code = 'DOCUMENT_NOT_FOUND';
  }
}

function storageProvider() {
  const configured = process.env.DOCUMENT_STORAGE_PROVIDER
    || (process.env.NODE_ENV === 'production' ? 'firebase' : 'local_mock');
  if (!SUPPORTED_PROVIDERS.has(configured)) {
    throw new Error(`Unsupported DOCUMENT_STORAGE_PROVIDER: ${configured}`);
  }
  return configured;
}

function storageRoot() {
  return path.resolve(
    process.env.DOCUMENT_STORAGE_ROOT || '/app/storage/worker-documents'
  );
}

function validateDocumentStorageConfiguration() {
  const provider = storageProvider();
  if (provider === 'firebase') {
    if (!process.env.FIREBASE_STORAGE_BUCKET) {
      throw new Error('FIREBASE_STORAGE_BUCKET is required for Firebase document storage');
    }
    if (!process.env.FIREBASE_SERVICE_ACCOUNT_JSON) {
      throw new Error('FIREBASE_SERVICE_ACCOUNT_JSON is required for Firebase document storage');
    }
  }
  return { configured: true, provider, durable: provider === 'firebase' };
}

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
  const provider = storageProvider();
  const extension = extensionForContentType(contentType);
  const safeType = documentType.replace(/[^a-zA-Z0-9_-]/g, '-');
  const relativeKey = `${enrollmentId}/${safeType}-${Date.now()}.${extension}`;
  if (provider === 'firebase') {
    const storageKey = `worker-documents/${relativeKey}`;
    await getFirebaseStorageBucket().file(storageKey).save(bytes, {
      resumable: false,
      validation: 'crc32c',
      metadata: {
        contentType,
        cacheControl: 'private, no-store, max-age=0',
        metadata: {
          enrollmentId,
          documentType,
        },
      },
    });
    return { storageProvider: provider, storageKey };
  }

  const absolutePath = path.join(storageRoot(), relativeKey);
  await fs.mkdir(path.dirname(absolutePath), { recursive: true });
  await fs.writeFile(absolutePath, bytes);
  return { storageProvider: provider, storageKey: absolutePath };
}

function safeLocalPath(storageKey) {
  const root = storageRoot();
  const resolved = path.resolve(storageKey);
  if (resolved !== root && !resolved.startsWith(`${root}${path.sep}`)) {
    const error = new Error('Invalid document path');
    error.code = 'INVALID_DOCUMENT_PATH';
    throw error;
  }
  return resolved;
}

async function readWorkerDocument({ storageProvider: provider, storageKey }) {
  if (provider === 'firebase') {
    try {
      const [bytes] = await getFirebaseStorageBucket().file(storageKey).download();
      return bytes;
    } catch (error) {
      if (error.code === 404 || error.code === '404') {
        throw new DocumentNotFoundError();
      }
      throw error;
    }
  }

  if (provider === 'local_mock') {
    try {
      return await fs.readFile(safeLocalPath(storageKey));
    } catch (error) {
      if (error.code === 'ENOENT') throw new DocumentNotFoundError();
      throw error;
    }
  }

  throw new DocumentNotFoundError(
    `Document storage provider ${provider || 'unknown'} cannot be read`
  );
}

async function deleteWorkerDocument({ storageProvider: provider, storageKey }) {
  if (provider === 'firebase') {
    await getFirebaseStorageBucket().file(storageKey).delete({
      ignoreNotFound: true,
    });
    return;
  }

  if (provider === 'local_mock') {
    try {
      await fs.unlink(safeLocalPath(storageKey));
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
    }
    return;
  }

  const error = new Error(
    `Document storage provider ${provider || 'unknown'} cannot be deleted`,
  );
  error.code = 'UNSUPPORTED_DOCUMENT_STORAGE_PROVIDER';
  throw error;
}

async function deleteWorkerDocumentPrefix({ enrollmentId, provider }) {
  if (!/^[a-f0-9-]{36}$/i.test(enrollmentId)) {
    const error = new Error('Invalid worker enrollment id');
    error.code = 'INVALID_ENROLLMENT_ID';
    throw error;
  }

  if (provider === 'firebase') {
    await getFirebaseStorageBucket().deleteFiles({
      prefix: `worker-documents/${enrollmentId}/`,
      force: true,
    });
    return;
  }

  if (provider === 'local_mock') {
    await fs.rm(safeLocalPath(path.join(storageRoot(), enrollmentId)), {
      recursive: true,
      force: true,
    });
    return;
  }

  const error = new Error(
    `Document storage provider ${provider || 'unknown'} cannot be deleted`,
  );
  error.code = 'UNSUPPORTED_DOCUMENT_STORAGE_PROVIDER';
  throw error;
}

async function deleteWorkerDocumentsForEnrollment({ enrollmentId, documents = [] }) {
  const providers = new Set([storageProvider()]);
  for (const document of documents) {
    if (document.storageProvider) providers.add(document.storageProvider);
    await deleteWorkerDocument(document);
  }
  for (const provider of providers) {
    await deleteWorkerDocumentPrefix({ enrollmentId, provider });
  }
}

module.exports = {
  deleteWorkerDocument,
  deleteWorkerDocumentPrefix,
  deleteWorkerDocumentsForEnrollment,
  DocumentNotFoundError,
  readWorkerDocument,
  saveWorkerDocument,
  safeLocalPath,
  storageProvider,
  validateDocumentStorageConfiguration,
};
