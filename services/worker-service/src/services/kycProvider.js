const { v4: uuidv4 } = require('uuid');

function buildMockHyperVergeResult({
  decision,
  faceMatchScore,
  reason,
  adminId,
}) {
  const passed = decision === 'verified';
  const needsReview = decision === 'manual_review';

  return {
    provider: 'mock_hyperverge',
    providerReferenceId: `mock-hv-${uuidv4()}`,
    status: decision,
    documentStatus: passed || needsReview ? 'passed' : 'failed',
    faceMatchStatus: passed || needsReview ? 'passed' : 'failed',
    livenessStatus: passed || needsReview ? 'passed' : 'failed',
    backgroundStatus: needsReview ? 'pending' : passed ? 'clear' : 'failed',
    faceMatchScore,
    decisionReason: reason,
    processedBy: adminId,
    rawResult: {
      source: 'admin_simulation',
      providerShape: 'hyperverge',
      decision,
      checks: {
        documentVerification: passed || needsReview,
        faceMatch: passed || needsReview,
        passiveLiveness: passed || needsReview,
        backgroundCheck: passed,
      },
    },
  };
}

module.exports = {
  buildMockHyperVergeResult,
};
