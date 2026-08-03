const test = require('node:test');
const assert = require('node:assert/strict');
const {
  decryptDocumentField,
  encryptDocumentField,
  normalizeDocumentNumber,
  protectExtractedFields,
} = require('./documentFieldEncryption');

test('encrypts authenticated document fields without storing plaintext', () => {
  const previous = process.env.DOCUMENT_FIELD_ENCRYPTION_KEY;
  process.env.DOCUMENT_FIELD_ENCRYPTION_KEY = Buffer.alloc(32, 7).toString('base64');
  try {
    const encrypted = encryptDocumentField('ABCDE1234F');
    assert.ok(!encrypted.includes('ABCDE1234F'));
    assert.equal(decryptDocumentField(encrypted), 'ABCDE1234F');
  } finally {
    if (previous === undefined) delete process.env.DOCUMENT_FIELD_ENCRYPTION_KEY;
    else process.env.DOCUMENT_FIELD_ENCRYPTION_KEY = previous;
  }
});

test('validates document numbers against the selected ID type', () => {
  assert.equal(normalizeDocumentNumber('pan', 'abcde 1234 f'), 'ABCDE1234F');
  assert.equal(normalizeDocumentNumber('pan', '123456789012'), null);
});

test('removes plaintext number when encryption is not configured', () => {
  const previous = process.env.DOCUMENT_FIELD_ENCRYPTION_KEY;
  delete process.env.DOCUMENT_FIELD_ENCRYPTION_KEY;
  try {
    const protectedFields = protectExtractedFields('pan', {
      documentName: 'PRIYA SHARMA',
      documentNumber: 'ABCDE1234F',
      documentNumberMasked: 'XXXXXX234F',
    });
    assert.equal(protectedFields.safeFields.documentNumber, undefined);
    assert.equal(protectedFields.safeFields.documentName, 'PRIYA SHARMA');
    assert.equal(protectedFields.encryptedNumber, null);
    assert.equal(protectedFields.numberLast4, '234F');
  } finally {
    if (previous !== undefined) process.env.DOCUMENT_FIELD_ENCRYPTION_KEY = previous;
  }
});
