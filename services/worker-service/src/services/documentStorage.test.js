const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs/promises');
const os = require('os');
const path = require('path');
const {
  deleteWorkerDocumentsForEnrollment,
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

test('local storage purge removes every file for one enrollment only', async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'gofer-document-purge-'));
  const previousProvider = process.env.DOCUMENT_STORAGE_PROVIDER;
  const previousRoot = process.env.DOCUMENT_STORAGE_ROOT;
  process.env.DOCUMENT_STORAGE_PROVIDER = 'local_mock';
  process.env.DOCUMENT_STORAGE_ROOT = root;
  const enrollmentId = '11111111-1111-4111-8111-111111111111';
  const otherEnrollmentId = '22222222-2222-4222-8222-222222222222';

  try {
    const first = await saveWorkerDocument({
      enrollmentId,
      documentType: 'nationalIdFront',
      contentType: 'image/jpeg',
      bytes: Buffer.from('front'),
    });
    await saveWorkerDocument({
      enrollmentId,
      documentType: 'nationalIdBack',
      contentType: 'image/jpeg',
      bytes: Buffer.from('back'),
    });
    const other = await saveWorkerDocument({
      enrollmentId: otherEnrollmentId,
      documentType: 'selfie',
      contentType: 'image/jpeg',
      bytes: Buffer.from('other'),
    });

    await deleteWorkerDocumentsForEnrollment({
      enrollmentId,
      documents: [{
        storageProvider: first.storageProvider,
        storageKey: first.storageKey,
      }],
    });

    await assert.rejects(
      () => fs.access(path.join(root, enrollmentId)),
      (error) => error.code === 'ENOENT',
    );
    assert.deepEqual(await readWorkerDocument(other), Buffer.from('other'));
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
