const { v4: uuidv4 } = require('uuid');

// Workida verifies worker identity by manual review: a Workida reviewer checks the
// submitted ID, selfie and profile in the admin console and records the decision.
// There is no automated KYC vendor in the loop. This helper shapes that manual
// decision into the row stored in `kyc_verifications`.
function buildManualReviewResult({
  decision,
  faceMatchScore,
  reason,
  adminId,
}) {
  const passed = decision === 'verified';
  const needsReview = decision === 'manual_review';

  return {
    provider: 'admin_manual',
    providerReferenceId: `manual-${uuidv4()}`,
    status: decision,
    documentStatus: passed || needsReview ? 'passed' : 'failed',
    faceMatchStatus: passed || needsReview ? 'passed' : 'failed',
    livenessStatus: passed || needsReview ? 'passed' : 'failed',
    backgroundStatus: needsReview ? 'pending' : passed ? 'clear' : 'failed',
    faceMatchScore,
    decisionReason: reason,
    processedBy: adminId,
    rawResult: {
      source: 'admin_manual_review',
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
  buildManualReviewResult,
};
