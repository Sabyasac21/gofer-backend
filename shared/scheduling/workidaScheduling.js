'use strict';

const IST_OFFSET_MS = 5.5 * 60 * 60 * 1000;
const DAY_MS = 24 * 60 * 60 * 1000;

class SchedulingError extends Error {
  constructor(message, code = 'INVALID_SCHEDULE') {
    super(message);
    this.name = 'SchedulingError';
    this.code = code;
  }
}

function indiaDayIndex(timestampMs) {
  return Math.floor((timestampMs + IST_OFFSET_MS) / DAY_MS);
}

function validateScheduledAt({ urgency, scheduledAt, nowMs = Date.now() }) {
  if (urgency === 'now') {
    if (scheduledAt != null) {
      throw new SchedulingError('Immediate bookings cannot include a scheduled time.');
    }
    return null;
  }
  if (typeof scheduledAt !== 'string' || !/(?:Z|[+-]\d{2}:\d{2})$/.test(scheduledAt)) {
    throw new SchedulingError('A timezone-aware scheduledAt value is required.');
  }
  const scheduledMs = Date.parse(scheduledAt);
  if (!Number.isFinite(scheduledMs) || scheduledMs <= nowMs) {
    throw new SchedulingError('The selected booking time must be in the future.');
  }

  const today = indiaDayIndex(nowMs);
  const selectedDay = indiaDayIndex(scheduledMs);
  if (urgency === 'today' && selectedDay !== today) {
    throw new SchedulingError('Today bookings must be scheduled before midnight today.');
  }
  if (urgency === 'scheduled' &&
      (selectedDay < today + 1 || selectedDay > today + 3)) {
    throw new SchedulingError('Later bookings must be within the next three India calendar days.');
  }
  return new Date(scheduledMs).toISOString();
}

module.exports = { SchedulingError, indiaDayIndex, validateScheduledAt };
