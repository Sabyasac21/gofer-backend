// shared/constants/taskStatus.js

const TASK_STATUS = {
  POSTED: 'posted',
  MATCHING: 'matching',
  ACCEPTED: 'accepted',
  IN_PROGRESS: 'in_progress',
  COMPLETED: 'completed',
  CANCELLED: 'cancelled',
  DISPUTED: 'disputed'
};

const TASK_STATUS_LABELS = {
  [TASK_STATUS.POSTED]: 'Posted',
  [TASK_STATUS.MATCHING]: 'Finding Worker',
  [TASK_STATUS.ACCEPTED]: 'Accepted',
  [TASK_STATUS.IN_PROGRESS]: 'In Progress',
  [TASK_STATUS.COMPLETED]: 'Completed',
  [TASK_STATUS.CANCELLED]: 'Cancelled',
  [TASK_STATUS.DISPUTED]: 'Disputed'
};

module.exports = {
  TASK_STATUS,
  TASK_STATUS_LABELS
};
