function messagingErrorCode(error) {
  return error?.code || 'messaging/unknown-error';
}

function isInvalidRegistrationToken(code) {
  return code === 'messaging/invalid-registration-token'
    || code === 'messaging/registration-token-not-registered';
}

function summarizeMessagingResponses(response, recipients) {
  const failureCodes = {};
  const failures = [];
  response.responses.forEach((result, index) => {
    if (result.success) return;
    const code = messagingErrorCode(result.error);
    failureCodes[code] = (failureCodes[code] || 0) + 1;
    failures.push({
      workerId: recipients[index]?.id,
      code,
      invalidToken: isInvalidRegistrationToken(code),
    });
  });
  return { failureCodes, failures };
}

module.exports = {
  messagingErrorCode,
  isInvalidRegistrationToken,
  summarizeMessagingResponses,
};
