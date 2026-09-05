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

  // Worker identity is confirmed by a human reviewer (kyc_provider =
  // 'manual_review'); this gate is only a sanity filter that the applicant sent
  // the right kind of images in the right order, not a machine verification.
  // On-device OCR routinely cannot read the 12-digit number off the
  // address-only Aadhaar back, nor the bilingual cardholder name off the front,
  // so those fields are advisory and never block submission. Side/type
  // classification is also absent from older installed builds, so it only fails
  // when it is present and wrong (e.g. the two sides were swapped).
  if (frontFields.detectedDocumentType &&
      frontFields.detectedDocumentType !== 'aadhaar') {
    errors.push('The front image was not identified as Aadhaar.');
  }
  if (frontFields.detectedDocumentSide &&
      frontFields.detectedDocumentSide !== 'front') {
    errors.push('The first Aadhaar image must be the front side.');
  }

  if (backFields.detectedDocumentType &&
      backFields.detectedDocumentType !== 'aadhaar') {
    errors.push('The back image was not identified as Aadhaar.');
  }
  if (backFields.detectedDocumentSide &&
      backFields.detectedDocumentSide !== 'back') {
    errors.push('The second Aadhaar image must be the back side.');
  }

  // The Aadhaar number is often printed in very small type on the back
  // (when it appears there at all), so on-device OCR reading one digit
  // wrong there is a real, unavoidable failure mode - not evidence the two
  // images belong to different cards. A human reviewer confirms identity
  // from the photos regardless, so - like every other OCR-derived signal
  // above - a number mismatch is never blocking on its own.

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

module.exports = {
  validateAadhaarEnrollment,
};
