const test = require('node:test');
const assert = require('node:assert/strict');
const {
  documentBytes,
  documentMetadata,
  legacyDocumentBytes,
} = require('./legacyDocumentPayload');

test('decodes plain and data URL legacy payloads', () => {
  const expected = Buffer.from('worker-photo');
  const encoded = expected.toString('base64');

  assert.deepEqual(documentBytes({ contentBase64: encoded }), expected);
  assert.deepEqual(
    documentBytes({ contentBase64: `data:image/jpeg;base64,${encoded}` }),
    expected,
  );
});

test('finds a legacy payload by document type', () => {
  const bytes = legacyDocumentBytes([
    { type: 'selfie', contentBase64: Buffer.from('face').toString('base64') },
  ], 'selfie');

  assert.equal(bytes.toString(), 'face');
  assert.equal(legacyDocumentBytes([], 'selfie'), null);
});

test('removes Base64 content from newly persisted enrollment metadata', () => {
  assert.deepEqual(documentMetadata([
    { type: 'selfie', contentBase64: 'private-payload', fileName: 'selfie.jpg' },
  ]), [
    { type: 'selfie', fileName: 'selfie.jpg' },
  ]);
});
