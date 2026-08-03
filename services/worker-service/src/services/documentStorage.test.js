const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs/promises');
const os = require('os');
const path = require('path');
const {
  readWorkerDocument,
  safeLocalPath,
  saveWorkerDocument,
} = require('./documentStorage');

test('local storage saves and reads a document inside the configured root', async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'gofer-documents-'));
  const previousProvider = process.env.DOCUMENT_STORAGE_PROVIDER;
  const previousRoot = process.env.DOCUMENT_STORAGE_ROOT;
  process.env.DOCUMENT_STORAGE_PROVIDER = 'local_mock';
  process.env.DOCUMENT_STORAGE_ROOT = root;

  try {
    const stored = await saveWorkerDocument({
      enrollmentId: 'enrollment-1',
      documentType: 'selfie',
      contentType: 'image/jpeg',
      bytes: Buffer.from('photo'),
    });
    assert.equal(stored.storageProvider, 'local_mock');
    assert.deepEqual(await readWorkerDocument(stored), Buffer.from('photo'));
  } finally {
    if (previousProvider === undefined) delete process.env.DOCUMENT_STORAGE_PROVIDER;
    else process.env.DOCUMENT_STORAGE_PROVIDER = previousProvider;
    if (previousRoot === undefined) delete process.env.DOCUMENT_STORAGE_ROOT;
    else process.env.DOCUMENT_STORAGE_ROOT = previousRoot;
    await fs.rm(root, { recursive: true, force: true });
  }
});

test('local storage rejects paths outside its configured root', () => {
  const previousRoot = process.env.DOCUMENT_STORAGE_ROOT;
  process.env.DOCUMENT_STORAGE_ROOT = path.resolve('safe-document-root');
  try {
    assert.throws(
      () => safeLocalPath(path.resolve('outside-document.jpg')),
      (error) => error.code === 'INVALID_DOCUMENT_PATH',
    );
  } finally {
    if (previousRoot === undefined) delete process.env.DOCUMENT_STORAGE_ROOT;
    else process.env.DOCUMENT_STORAGE_ROOT = previousRoot;
  }
});
