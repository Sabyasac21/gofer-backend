const WORKER_JOB_TRANSITIONS = Object.freeze({
  accepted: ['arrived', 'cancelled'],
  arrived: ['started', 'cancelled'],
  // `completed` remains accepted for workers on older app builds. Current
  // builds request customer confirmation before the dispatch is finalized.
  started: ['completion_requested', 'completed'],
});

function canWorkerTransition(currentStatus, nextStatus) {
  return WORKER_JOB_TRANSITIONS[currentStatus]?.includes(nextStatus) === true;
}

function previousStatusesFor(nextStatus) {
  return Object.entries(WORKER_JOB_TRANSITIONS)
    .filter(([, targets]) => targets.includes(nextStatus))
    .map(([source]) => source);
}

module.exports = {
  WORKER_JOB_TRANSITIONS,
  canWorkerTransition,
  previousStatusesFor,
};
