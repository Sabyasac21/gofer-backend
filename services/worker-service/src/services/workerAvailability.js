const PRESENCE_FRESH_HOURS = 12;
const ACTIVE_JOB_STATUSES = Object.freeze([
  'accepted',
  'arrived',
  'started',
  'completion_requested',
]);

function availabilityStatus(checks, activeJobStatus) {
  if (!checks.verified) return 'not_verified';
  if (!checks.presenceRegistered || !checks.onlineEnabled) return 'offline';
  if (!checks.presenceFresh) return 'stale';
  if (activeJobStatus) return 'busy';
  if (!checks.notificationReady) return 'notification_unavailable';
  if (!checks.locationReady) return 'location_unavailable';
  if (!checks.serviceEligible || checks.withinTravelRadius === false) {
    return 'online_not_eligible';
  }
  return 'ready';
}

function eligibilityReasons(checks, { taskSpecific = false } = {}) {
  const reasons = [];
  if (!checks.verified) reasons.push('Worker verification is incomplete');
  if (!checks.presenceRegistered) reasons.push('Worker app has not registered presence');
  if (checks.presenceRegistered && !checks.onlineEnabled) {
    reasons.push('Worker switched offline');
  }
  if (checks.onlineEnabled && !checks.presenceFresh) {
    reasons.push('Online presence is older than the 12-hour work-shift lease');
  }
  if (!checks.notificationReady) reasons.push('Notification token is unavailable');
  if (!checks.locationReady) reasons.push('Current location is unavailable');
  if (!checks.available) reasons.push('Worker already has an active job');
  if (taskSpecific && !checks.serviceEligible) {
    reasons.push('Worker type or service category does not match');
  }
  if (taskSpecific && checks.withinTravelRadius === false) {
    reasons.push('Task is outside the worker travel radius');
  }
  return reasons;
}

function mapAvailabilityRow(row, { taskSpecific = false } = {}) {
  const checks = {
    verified: row.workerStatus === 'verified',
    presenceRegistered: row.presenceRegistered === true,
    onlineEnabled: row.onlineEnabled === true,
    presenceFresh: row.presenceFresh === true,
    notificationReady: row.notificationReady === true,
    locationReady: row.locationReady === true,
    serviceEligible: row.serviceEligible === true,
    available: row.activeJobStatus == null,
    withinTravelRadius: row.withinTravelRadius,
  };
  const readyNow = checks.verified &&
    checks.presenceRegistered &&
    checks.onlineEnabled &&
    checks.presenceFresh &&
    checks.notificationReady &&
    checks.locationReady &&
    checks.available;
  const taskEligible = readyNow &&
    checks.serviceEligible &&
    checks.withinTravelRadius !== false;
  return {
    id: row.id,
    phone: row.phone,
    fullName: row.fullName,
    city: row.city,
    workArea: row.workArea,
    region: row.region,
    enrollmentTypes: row.enrollmentTypes || [],
    professionalCategories: row.professionalCategories || [],
    travelRadiusKm: Number(row.travelRadiusKm || 0),
    workerStatus: row.workerStatus,
    kycStatus: row.kycStatus,
    submittedAt: row.submittedAt,
    updatedAt: row.updatedAt,
    latitude: row.latitude,
    longitude: row.longitude,
    onlineSince: row.onlineSince,
    lastSeenAt: row.lastSeenAt,
    lastOfflineAt: row.lastOfflineAt,
    locationUpdatedAt: row.locationUpdatedAt,
    tokenUpdatedAt: row.tokenUpdatedAt,
    presenceAgeSeconds: row.presenceAgeSeconds == null
      ? null
      : Number(row.presenceAgeSeconds),
    distanceKm: row.distanceKm == null ? null : Number(row.distanceKm),
    activeJob: row.activeJobId ? {
      id: row.activeJobId,
      status: row.activeJobStatus,
      category: row.activeJobCategory,
      title: row.activeJobTitle,
      customerTaskId: row.activeCustomerTaskId,
    } : null,
    checks,
    readyNow,
    taskEligible,
    status: availabilityStatus(checks, row.activeJobStatus),
    reasons: eligibilityReasons(checks, { taskSpecific }),
  };
}

async function getWorkerAvailability(pool, options = {}) {
  const {
    region = null,
    serviceType = null,
    category = null,
    latitude = null,
    longitude = null,
  } = options;
  const taskSpecific = Boolean(serviceType && latitude != null && longitude != null);
  const result = await pool.query(`
    WITH evaluated AS (
      SELECT
        we.id,
        we.phone,
        we.full_name AS "fullName",
        we.city,
        we.work_area AS "workArea",
        COALESCE(NULLIF(we.work_area, ''), NULLIF(we.city, ''), 'Unassigned')
          AS region,
        we.enrollment_types AS "enrollmentTypes",
        we.professional_categories AS "professionalCategories",
        we.travel_radius_km AS "travelRadiusKm",
        we.worker_status AS "workerStatus",
        we.kyc_status AS "kycStatus",
        we.submitted_at AS "submittedAt",
        we.updated_at AS "updatedAt",
        (wp.worker_enrollment_id IS NOT NULL) AS "presenceRegistered",
        (wp.online = TRUE) AS "onlineEnabled",
        (
          wp.online = TRUE
          AND wp.last_seen_at > NOW() - INTERVAL '${PRESENCE_FRESH_HOURS} hours'
        ) AS "presenceFresh",
        (wp.fcm_token IS NOT NULL AND wp.fcm_token <> '')
          AS "notificationReady",
        (wp.latitude IS NOT NULL AND wp.longitude IS NOT NULL)
          AS "locationReady",
        CASE
          WHEN $2::text IS NULL THEN cardinality(we.enrollment_types) > 0
          WHEN $2 = 'helper' THEN 'helper' = ANY(we.enrollment_types)
          ELSE (
            'professional' = ANY(we.enrollment_types)
            AND (
              $3::text IS NULL OR EXISTS (
                SELECT 1 FROM unnest(we.professional_categories) worker_category
                WHERE LOWER(worker_category) = LOWER($3)
              )
            )
          )
        END AS "serviceEligible",
        wp.latitude,
        wp.longitude,
        wp.online_since AS "onlineSince",
        wp.last_seen_at AS "lastSeenAt",
        wp.last_offline_at AS "lastOfflineAt",
        wp.location_updated_at AS "locationUpdatedAt",
        wp.token_updated_at AS "tokenUpdatedAt",
        EXTRACT(EPOCH FROM (NOW() - wp.last_seen_at))::int
          AS "presenceAgeSeconds",
        active_job.id AS "activeJobId",
        active_job.status AS "activeJobStatus",
        active_job.category AS "activeJobCategory",
        active_job.title AS "activeJobTitle",
        active_job.customer_task_id AS "activeCustomerTaskId",
        CASE
          WHEN $4::double precision IS NULL OR $5::double precision IS NULL
            OR wp.latitude IS NULL OR wp.longitude IS NULL
          THEN NULL
          ELSE 6371 * 2 * ASIN(SQRT(
            POWER(SIN(RADIANS(wp.latitude - $4) / 2), 2) +
            COS(RADIANS($4)) * COS(RADIANS(wp.latitude)) *
            POWER(SIN(RADIANS(wp.longitude - $5) / 2), 2)
          ))
        END AS "distanceKm"
      FROM worker_enrollments we
      LEFT JOIN worker_presence wp ON wp.worker_enrollment_id = we.id
      LEFT JOIN LATERAL (
        SELECT id, status, category, title, customer_task_id
        FROM worker_job_dispatches
        WHERE accepted_worker_id = we.id
          AND status = ANY($6::varchar[])
        ORDER BY created_at DESC
        LIMIT 1
      ) active_job ON TRUE
      WHERE (
        $1::text IS NULL OR
        we.city ILIKE '%' || $1 || '%' OR
        we.work_area ILIKE '%' || $1 || '%'
      )
    )
    SELECT *,
      CASE
        WHEN "distanceKm" IS NULL THEN NULL
        ELSE "distanceKm" <= "travelRadiusKm"
      END AS "withinTravelRadius"
    FROM evaluated
    ORDER BY
      ("onlineEnabled" AND "presenceFresh") DESC,
      "lastSeenAt" DESC NULLS LAST,
      "fullName"
    LIMIT 500
  `, [
    region || null,
    serviceType || null,
    category || null,
    latitude,
    longitude,
    ACTIVE_JOB_STATUSES,
  ]);
  return result.rows.map((row) => mapAvailabilityRow(row, { taskSpecific }));
}

function summarizeAvailability(workers) {
  const totals = {
    total: workers.length,
    ready: 0,
    busy: 0,
    offline: 0,
    stale: 0,
    blocked: 0,
  };
  const regions = new Map();
  for (const worker of workers) {
    if (worker.status === 'ready') totals.ready += 1;
    else if (worker.status === 'busy') totals.busy += 1;
    else if (worker.status === 'offline') totals.offline += 1;
    else if (worker.status === 'stale') totals.stale += 1;
    else totals.blocked += 1;

    const region = regions.get(worker.region) || {
      region: worker.region,
      total: 0,
      ready: 0,
      busy: 0,
      offline: 0,
      blocked: 0,
    };
    region.total += 1;
    if (worker.status === 'ready') region.ready += 1;
    else if (worker.status === 'busy') region.busy += 1;
    else if (worker.status === 'offline') region.offline += 1;
    else region.blocked += 1;
    regions.set(worker.region, region);
  }
  return {
    totals,
    regions: [...regions.values()].sort((a, b) =>
      b.ready - a.ready || a.region.localeCompare(b.region)),
  };
}

module.exports = {
  PRESENCE_FRESH_HOURS,
  ACTIVE_JOB_STATUSES,
  availabilityStatus,
  eligibilityReasons,
  mapAvailabilityRow,
  getWorkerAvailability,
  summarizeAvailability,
};
