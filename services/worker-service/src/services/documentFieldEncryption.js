const crypto = require('crypto');

const VERSION = 'v1';

function encryptionKey() {
  const configured = process.env.DOCUMENT_FIELD_ENCRYPTION_KEY;
  if (!configured) return null;
  const key = /^[a-f0-9]{64}$/i.test(configured)
    ? Buffer.from(configured, 'hex')
    : Buffer.from(configured, 'base64');
  if (key.length !== 32) {
    throw new Error('DOCUMENT_FIELD_ENCRYPTION_KEY must decode to exactly 32 bytes');
  }
  return key;
}

function documentFieldEncryptionStatus() {
  try {
    return { configured: Boolean(encryptionKey()), algorithm: 'aes-256-gcm' };
  } catch (error) {
    return { configured: false, message: error.message };
  }
}

function encryptDocumentField(value) {
  const key = encryptionKey();
  if (!key) return null;
  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv('aes-256-gcm', key, iv);
  const encrypted = Buffer.concat([
    cipher.update(value, 'utf8'),
    cipher.final(),
  ]);
  const tag = cipher.getAuthTag();
  return [VERSION, iv, tag, encrypted]
    .map((part) => Buffer.isBuffer(part) ? part.toString('base64') : part)
    .join(':');
}

function decryptDocumentField(payload) {
  const key = encryptionKey();
  if (!key) throw new Error('Document field encryption is not configured');
  const [version, ivValue, tagValue, encryptedValue] = String(payload).split(':');
  if (version !== VERSION || !ivValue || !tagValue || !encryptedValue) {
    throw new Error('Encrypted document field has an unsupported format');
  }
  const decipher = crypto.createDecipheriv(
    'aes-256-gcm',
    key,
    Buffer.from(ivValue, 'base64'),
  );
  decipher.setAuthTag(Buffer.from(tagValue, 'base64'));
  return Buffer.concat([
    decipher.update(Buffer.from(encryptedValue, 'base64')),
    decipher.final(),
  ]).toString('utf8');
}

function normalizeDocumentNumber(idType, value) {
  if (!value || typeof value !== 'string') return null;
  const normalized = value.toUpperCase().replace(/[^A-Z0-9]/g, '');
  const pattern = {
    aadhaar: /^\d{12}$/,
    pan: /^[A-Z]{5}\d{4}[A-Z]$/,
    voterId: /^[A-Z]{2,4}\d{6,10}$/,
    drivingLicence: /^[A-Z]{2}\d{2}[A-Z0-9]{6,14}$/,
    passport: /^[A-Z][A-Z0-9]\d{6,8}$/,
  }[idType];
  return pattern?.test(normalized) ? normalized : null;
}

function protectExtractedFields(idType, extractedFields = {}) {
  const { documentNumber, ...safeFields } = extractedFields;
  const normalized = normalizeDocumentNumber(idType, documentNumber);
  return {
    safeFields,
    encryptedNumber: normalized ? encryptDocumentField(normalized) : null,
    numberLast4: normalized?.slice(-4) || null,
  };
}

async function ensureDocumentSensitiveFieldsSchema(pool) {
  await pool.query(`
    ALTER TABLE worker_documents
      ADD COLUMN IF NOT EXISTS document_number_encrypted TEXT,
      ADD COLUMN IF NOT EXISTS document_number_last4 VARCHAR(4)
  `);
}

module.exports = {
  decryptDocumentField,
  documentFieldEncryptionStatus,
  encryptDocumentField,
  ensureDocumentSensitiveFieldsSchema,
  normalizeDocumentNumber,
  protectExtractedFields,
};
