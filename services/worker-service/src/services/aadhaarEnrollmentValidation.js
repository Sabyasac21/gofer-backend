const REQUIRED_DOCUMENT_TYPES = [
  'nationalIdFront',
  'nationalIdBack',
  'selfie',
];

function validateAadhaarEnrollment({ idType, documents = [] }) {
  const errors = [];
  if (idType !== 'aadhaar') {
    errors.push('Only Aadhaar is accepted for worker enrollment.');
  }

  const documentsByType = new Map();
  for (const document of documents) {
    if (!REQUIRED_DOCUMENT_TYPES.includes(document.type)) {
      errors.push(`Unsupported worker document type: ${document.type}.`);
      continue;
    }
    if (documentsByType.has(document.type)) {
      errors.push(`Duplicate worker document type: ${document.type}.`);
      continue;
    }
    documentsByType.set(document.type, document);
  }

  for (const type of REQUIRED_DOCUMENT_TYPES) {
    if (!documentsByType.has(type)) {
      errors.push(`Missing required worker document: ${type}.`);
    }
  }
  if (errors.length > 0) return errors;

  for (const [type, document] of documentsByType) {
    if (!document.contentBase64 || document.contentBase64.length < 100) {
      errors.push(`${type} must contain an uploaded image.`);
    }
    if (
      !Array.isArray(document.validationChecks) ||
      document.validationChecks.length === 0 ||
      document.validationChecks.some((check) => check.passed !== true)
    ) {
      errors.push(`${type} did not pass every required validation check.`);
    }
  }

  const front = documentsByType.get('nationalIdFront');
  const back = documentsByType.get('nationalIdBack');
  const selfie = documentsByType.get('selfie');
  const frontFields = front.extractedFields || {};
  const backFields = back.extractedFields || {};
  const frontNumber = normalizeAadhaarNumber(frontFields.documentNumber);
  const backNumber = normalizeAadhaarNumber(backFields.documentNumber);

  if (frontFields.detectedDocumentType !== 'aadhaar') {
    errors.push('The front image was not identified as Aadhaar.');
  }
  if (frontFields.detectedDocumentSide !== 'front') {
    errors.push('The first Aadhaar image must be the front side.');
  }
  if (!frontNumber) {
    errors.push('A valid 12-digit Aadhaar number was not detected on the front.');
  }
  if (!frontFields.documentName || frontFields.documentName.trim().length < 3) {
    errors.push('The Aadhaar cardholder name was not detected on the front.');
  }

  if (backFields.detectedDocumentType !== 'aadhaar') {
    errors.push('The back image was not identified as Aadhaar.');
  }
  if (backFields.detectedDocumentSide !== 'back') {
    errors.push('The second Aadhaar image must be the back side.');
  }
  if (!backNumber) {
    errors.push('A valid 12-digit Aadhaar number was not detected on the back.');
  }
  if (frontNumber && backNumber && frontNumber !== backNumber) {
    errors.push('The Aadhaar front and back numbers do not match.');
  }

  const localLivenessChecks = [
    'Camera-only selfie',
    'Face continuity',
    'Random temporal challenge',
    'Local liveness score',
  ];
  const legacySelfieChecks = [
    'Camera-only selfie',
    'Face detected',
    'Movement liveness',
  ];
  const passedSelfieChecks = new Set(
    selfie.validationChecks
      .filter((check) => check.passed === true)
      .map((check) => check.label),
  );
  const passedLocalLiveness = localLivenessChecks.every(
    (label) => passedSelfieChecks.has(label),
  );
  // Keep accepting the immediately previous app version during rollout. Its
  // evidence is intentionally isolated here and can be removed after workers
  // have migrated to the automatic temporal challenge flow.
  const passedLegacyLiveness = legacySelfieChecks.every(
    (label) => passedSelfieChecks.has(label),
  );
  if (!passedLocalLiveness && !passedLegacyLiveness) {
    errors.push(
      'Live selfie is missing continuous face tracking and temporal challenge evidence.',
    );
  }

  return errors;
}

function normalizeAadhaarNumber(value) {
  const normalized = String(value || '').replace(/\D/g, '');
  return /^\d{12}$/.test(normalized) ? normalized : '';
}

module.exports = {
  validateAadhaarEnrollment,
};
