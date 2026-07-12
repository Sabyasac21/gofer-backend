const WORKER_JOB_TRANSITIONS = Object.freeze({
  accepted: ['arrived'],
  arrived: ['started'],
  started: ['completed'],
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
