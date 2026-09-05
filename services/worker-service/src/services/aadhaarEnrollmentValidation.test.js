const test = require('node:test');
const assert = require('node:assert/strict');

const {
  validateAadhaarEnrollment,
} = require('./aadhaarEnrollmentValidation');

function validEnrollment() {
  const passed = (label) => ({ label, passed: true, message: 'Passed' });
  return {
    idType: 'aadhaar',
    documents: [
      {
        type: 'nationalIdFront',
        contentBase64: 'a'.repeat(200),
        validationChecks: [passed('Aadhaar front side')],
        extractedFields: {
          detectedDocumentType: 'aadhaar',
          detectedDocumentSide: 'front',
          documentNumber: '944780700173',
          documentName: 'Sabyasachi Nishant',
        },
      },
      {
        type: 'nationalIdBack',
        contentBase64: 'b'.repeat(200),
        validationChecks: [passed('Aadhaar back side')],
        extractedFields: {
          detectedDocumentType: 'aadhaar',
          detectedDocumentSide: 'back',
          documentNumber: '944780700173',
        },
      },
      {
        type: 'selfie',
        contentBase64: 'c'.repeat(200),
        extractedFields: {},
        validationChecks: [
          passed('Camera-only selfie'),
          passed('Face continuity'),
          passed('Random temporal challenge'),
          passed('Local liveness score'),
        ],
      },
    ],
  };
}

test('accepts a complete Aadhaar-only enrollment', () => {
  assert.deepEqual(validateAadhaarEnrollment(validEnrollment()), []);
});

test('temporarily accepts legacy movement evidence during app migration', () => {
  const enrollment = validEnrollment();
  enrollment.documents[2].validationChecks = [
    { label: 'Camera-only selfie', passed: true, message: 'Passed' },
    { label: 'Face detected', passed: true, message: 'Passed' },
    { label: 'Movement liveness', passed: true, message: 'Passed' },
  ];
  assert.deepEqual(validateAadhaarEnrollment(enrollment), []);
});

test('accepts an Aadhaar back with no machine-readable number (address-only side)', () => {
  const enrollment = validEnrollment();
  delete enrollment.documents[1].extractedFields.documentNumber;
  assert.deepEqual(validateAadhaarEnrollment(enrollment), []);
});

test('accepts a front whose bilingual name or number could not be OCR-read', () => {
  const enrollment = validEnrollment();
  delete enrollment.documents[0].extractedFields.documentName;
  delete enrollment.documents[0].extractedFields.documentNumber;
  assert.deepEqual(validateAadhaarEnrollment(enrollment), []);
});

test('accepts submissions from older builds that do not classify the document side', () => {
  const enrollment = validEnrollment();
  for (const index of [0, 1]) {
    delete enrollment.documents[index].extractedFields.detectedDocumentSide;
    delete enrollment.documents[index].extractedFields.detectedDocumentType;
  }
  assert.deepEqual(validateAadhaarEnrollment(enrollment), []);
});

test('rejects a non-Aadhaar enrollment', () => {
  const enrollment = validEnrollment();
  enrollment.idType = 'pan';
  assert.match(validateAadhaarEnrollment(enrollment).join(' '), /Only Aadhaar/);
});

test('rejects reversed Aadhaar sides', () => {
  const enrollment = validEnrollment();
  enrollment.documents[0].extractedFields.detectedDocumentSide = 'back';
  enrollment.documents[1].extractedFields.detectedDocumentSide = 'front';
  const errors = validateAadhaarEnrollment(enrollment).join(' ');
  assert.match(errors, /first Aadhaar image must be the front/);
  assert.match(errors, /second Aadhaar image must be the back/);
});

test('accepts a front/back Aadhaar number mismatch (small back-side print is unreliable to OCR)', () => {
  const enrollment = validEnrollment();
  enrollment.documents[1].extractedFields.documentNumber = '604068325141';
  assert.deepEqual(validateAadhaarEnrollment(enrollment), []);
});

test('rejects missing liveness evidence and failed validation', () => {
  const enrollment = validEnrollment();
  enrollment.documents[2].validationChecks = [
    { label: 'Face detected', passed: false, message: 'No face' },
  ];
  const errors = validateAadhaarEnrollment(enrollment).join(' ');
  assert.match(errors, /did not pass every required validation check/);
  assert.match(errors, /continuous face tracking and temporal challenge/);
});
