const MAX_DOCUMENT_BYTES = 10 * 1024 * 1024;

function documentBytes(document) {
  if (!document?.contentBase64 || typeof document.contentBase64 !== 'string') {
    return null;
  }
  const cleaned = document.contentBase64.includes(',')
    ? document.contentBase64.slice(document.contentBase64.indexOf(',') + 1)
    : document.contentBase64;
  const normalized = cleaned.replace(/\s/g, '');
  if (!normalized || !/^[a-zA-Z0-9+/]*={0,2}$/.test(normalized)) return null;

  const bytes = Buffer.from(normalized, 'base64');
  if (!bytes.length || bytes.length > MAX_DOCUMENT_BYTES) return null;
  return bytes;
}

function legacyDocument(documents, documentType) {
  if (!Array.isArray(documents)) return null;
  return documents.find((document) => document?.type === documentType) || null;
}

function legacyDocumentBytes(documents, documentType) {
  return documentBytes(legacyDocument(documents, documentType));
}

function documentMetadata(documents) {
  return documents.map(({ contentBase64, ...document }) => document);
}

module.exports = {
  documentBytes,
  documentMetadata,
  legacyDocument,
  legacyDocumentBytes,
  MAX_DOCUMENT_BYTES,
};
