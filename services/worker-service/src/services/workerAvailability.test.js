const test = require('node:test');
const assert = require('node:assert/strict');
const {
  availabilityStatus,
  eligibilityReasons,
  mapAvailabilityRow,
  summarizeAvailability,
} = require('./workerAvailability');

function readyChecks(overrides = {}) {
  return {
    verified: true,
    presenceRegistered: true,
    onlineEnabled: true,
    presenceFresh: true,
    notificationReady: true,
    locationReady: true,
    serviceEligible: true,
    available: true,
    withinTravelRadius: true,
    ...overrides,
  };
}

test('availability status identifies ready, busy, stale, and blocked workers', () => {
  assert.equal(availabilityStatus(readyChecks(), null), 'ready');
  assert.equal(availabilityStatus(readyChecks({ available: false }), 'accepted'), 'busy');
  assert.equal(availabilityStatus(readyChecks({ presenceFresh: false }), null), 'stale');
  assert.equal(
    availabilityStatus(readyChecks({ notificationReady: false }), null),
    'notification_unavailable',
  );
  assert.equal(
    availabilityStatus(readyChecks({ locationReady: false }), null),
    'location_unavailable',
  );
  assert.equal(
    availabilityStatus(readyChecks({ withinTravelRadius: false }), null),
    'online_not_eligible',
  );
});

test('eligibility reasons explain every failed production check', () => {
  const reasons = eligibilityReasons(readyChecks({
    notificationReady: false,
    locationReady: false,
    serviceEligible: false,
    available: false,
    withinTravelRadius: false,
  }), { taskSpecific: true });

  assert.deepEqual(reasons, [
    'Notification token is unavailable',
    'Current location is unavailable',
    'Worker already has an active job',
    'Worker type or service category does not match',
    'Task is outside the worker travel radius',
  ]);
});

test('row mapping separates general readiness from task eligibility', () => {
  const worker = mapAvailabilityRow({
    id: 'worker-1',
    phone: '9876543210',
    fullName: 'Ready Worker',
    city: 'Noida',
    workArea: 'Sector 62',
    region: 'Sector 62',
    enrollmentTypes: ['helper'],
    professionalCategories: [],
    travelRadiusKm: 8,
    workerStatus: 'verified',
    kycStatus: 'verified',
    presenceRegistered: true,
    onlineEnabled: true,
    presenceFresh: true,
    notificationReady: true,
    locationReady: true,
    serviceEligible: true,
    withinTravelRadius: false,
    activeJobStatus: null,
    presenceAgeSeconds: 30,
    distanceKm: 12,
  }, { taskSpecific: true });

  assert.equal(worker.readyNow, true);
  assert.equal(worker.taskEligible, false);
  assert.equal(worker.status, 'online_not_eligible');
  assert.match(worker.reasons[0], /travel radius/);
});

test('regional summary reports operational states', () => {
  const summary = summarizeAvailability([
    { region: 'Noida', status: 'ready' },
    { region: 'Noida', status: 'busy' },
    { region: 'Delhi', status: 'offline' },
    { region: 'Delhi', status: 'location_unavailable' },
  ]);

  assert.deepEqual(summary.totals, {
    total: 4,
    ready: 1,
    busy: 1,
    offline: 1,
    stale: 0,
    blocked: 1,
  });
  assert.equal(summary.regions.find((item) => item.region === 'Noida').ready, 1);
  assert.equal(summary.regions.find((item) => item.region === 'Delhi').blocked, 1);
});
