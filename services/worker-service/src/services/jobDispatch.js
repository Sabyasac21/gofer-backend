const admin = require('firebase-admin');
const { v4: uuidv4 } = require('uuid');
const { previousStatusesFor } = require('./jobLifecycle');
const { getPendingWorkerJob } = require('./pendingJob');
const {
  messagingErrorCode,
  summarizeMessagingResponses,
} = require('./firebaseDiagnostics');

let messaging = null;
let messagingLogger = console;
let messagingProjectId = null;
const JOB_OFFER_TTL_MS = 120000;
const MAX_REPLACEMENT_ATTEMPTS = 2;

function initializeMessaging(logger) {
  messagingLogger = logger || console;
  const raw = process.env.FIREBASE_SERVICE_ACCOUNT_JSON;
  if (!raw) {
    logger.warn('FIREBASE_SERVICE_ACCOUNT_JSON is not configured; push delivery is disabled');
    return;
  }
  try {
    const credential = JSON.parse(raw);
    messagingProjectId = credential.project_id || null;
    const app = admin.apps.length
      ? admin.app()
      : admin.initializeApp({ credential: admin.credential.cert(credential) });
    messaging = app.messaging();
    messagingLogger.info('Firebase Admin messaging initialized', {
      projectId: messagingProjectId,
    });
  } catch (error) {
    logger.error('Firebase Admin initialization failed', { error: error.message });
  }
}

function getMessagingStatus() {
  return {
    configured: Boolean(messaging),
    projectId: messagingProjectId,
  };
}

async function ensureDispatchSchema(pool) {
  await pool.query(`
    CREATE TABLE IF NOT EXISTS worker_presence (
      worker_enrollment_id UUID PRIMARY KEY REFERENCES worker_enrollments(id) ON DELETE CASCADE,
      fcm_token TEXT,
      platform VARCHAR(20) NOT NULL DEFAULT 'android',
      online BOOLEAN NOT NULL DEFAULT FALSE,
      latitude DOUBLE PRECISION,
      longitude DOUBLE PRECISION,
      last_seen_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      online_since TIMESTAMPTZ,
      last_offline_at TIMESTAMPTZ,
      location_updated_at TIMESTAMPTZ,
      token_updated_at TIMESTAMPTZ
    );
    ALTER TABLE worker_presence
      ADD COLUMN IF NOT EXISTS online_since TIMESTAMPTZ;
    ALTER TABLE worker_presence
      ADD COLUMN IF NOT EXISTS last_offline_at TIMESTAMPTZ;
    ALTER TABLE worker_presence
      ADD COLUMN IF NOT EXISTS location_updated_at TIMESTAMPTZ;
    ALTER TABLE worker_presence
      ADD COLUMN IF NOT EXISTS token_updated_at TIMESTAMPTZ;
    UPDATE worker_presence
      SET online_since = COALESCE(online_since, last_seen_at)
      WHERE online = TRUE AND online_since IS NULL;
    UPDATE worker_presence
      SET location_updated_at = COALESCE(location_updated_at, last_seen_at)
      WHERE latitude IS NOT NULL AND longitude IS NOT NULL
        AND location_updated_at IS NULL;
    UPDATE worker_presence
      SET token_updated_at = COALESCE(token_updated_at, last_seen_at)
      WHERE fcm_token IS NOT NULL AND fcm_token <> ''
        AND token_updated_at IS NULL;
    CREATE INDEX IF NOT EXISTS worker_presence_online_idx
      ON worker_presence(online, last_seen_at DESC);
    CREATE TABLE IF NOT EXISTS worker_job_dispatches (
      id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
      customer_task_id VARCHAR(120) NOT NULL,
      service_type VARCHAR(30) NOT NULL,
      category VARCHAR(120) NOT NULL,
      title VARCHAR(160) NOT NULL,
      notes TEXT,
      address_text VARCHAR(500) NOT NULL,
      latitude DOUBLE PRECISION NOT NULL,
      longitude DOUBLE PRECISION NOT NULL,
      budget INTEGER NOT NULL,
      status VARCHAR(30) NOT NULL DEFAULT 'offered',
      accepted_worker_id UUID REFERENCES worker_enrollments(id),
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      expires_at TIMESTAMPTZ NOT NULL DEFAULT NOW() + INTERVAL '2 minutes'
    );
    ALTER TABLE worker_job_dispatches
      ADD COLUMN IF NOT EXISTS replacement_attempts INTEGER NOT NULL DEFAULT 0;
    ALTER TABLE worker_job_dispatches
      ADD COLUMN IF NOT EXISTS excluded_worker_ids UUID[] NOT NULL DEFAULT '{}';
    ALTER TABLE worker_job_dispatches
      ADD COLUMN IF NOT EXISTS completed_at TIMESTAMPTZ;
    ALTER TABLE worker_job_dispatches
      ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW();
    UPDATE worker_job_dispatches
      SET completed_at = COALESCE(completed_at, updated_at, created_at)
      WHERE status = 'completed' AND completed_at IS NULL;
    CREATE INDEX IF NOT EXISTS worker_job_dispatches_worker_history_idx
      ON worker_job_dispatches(accepted_worker_id, completed_at DESC)
      WHERE status = 'completed';
    CREATE TABLE IF NOT EXISTS worker_job_offers (
      job_id UUID NOT NULL REFERENCES worker_job_dispatches(id) ON DELETE CASCADE,
      worker_enrollment_id UUID NOT NULL REFERENCES worker_enrollments(id) ON DELETE CASCADE,
      status VARCHAR(30) NOT NULL DEFAULT 'offered',
      responded_at TIMESTAMPTZ,
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      PRIMARY KEY(job_id, worker_enrollment_id)
    );
  `);
}

async function updatePresence(pool, value) {
  const worker = await pool.query(
    `SELECT id FROM worker_enrollments WHERE phone = $1 AND worker_status = 'verified' LIMIT 1`,
    [value.phone]
  );
  if (!worker.rowCount) return null;
  if (!value.online) {
    const activeJob = await pool.query(`
      SELECT id, status
      FROM worker_job_dispatches
      WHERE accepted_worker_id = $1
        AND status IN ('accepted', 'arrived', 'started', 'completion_requested')
      ORDER BY created_at DESC
      LIMIT 1
    `, [worker.rows[0].id]);
    if (activeJob.rowCount) {
      return {
        workerId: worker.rows[0].id,
        online: true,
        blockedByActiveJob: true,
        activeJobId: activeJob.rows[0].id,
        activeJobStatus: activeJob.rows[0].status,
      };
    }
  }
  const result = await pool.query(`
    INSERT INTO worker_presence (
      worker_enrollment_id, fcm_token, platform, online, latitude, longitude,
      last_seen_at, updated_at, online_since, last_offline_at,
      location_updated_at, token_updated_at
    ) VALUES (
      $1::uuid,$2::text,$3::varchar,$4::boolean,
      $5::double precision,$6::double precision,NOW(),NOW(),
      CASE WHEN $4::boolean THEN NOW() ELSE NULL END,
      CASE WHEN NOT $4::boolean THEN NOW() ELSE NULL END,
      CASE
        WHEN $5::double precision IS NOT NULL
          AND $6::double precision IS NOT NULL
        THEN NOW()
        ELSE NULL
      END,
      CASE
        WHEN $2::text IS NOT NULL AND $2::text <> ''
        THEN NOW()
        ELSE NULL
      END
    )
    ON CONFLICT (worker_enrollment_id) DO UPDATE SET
      fcm_token = COALESCE(EXCLUDED.fcm_token, worker_presence.fcm_token),
      platform = EXCLUDED.platform,
      online = EXCLUDED.online,
      latitude = COALESCE(EXCLUDED.latitude, worker_presence.latitude),
      longitude = COALESCE(EXCLUDED.longitude, worker_presence.longitude),
      last_seen_at = NOW(),
      updated_at = NOW(),
      online_since = CASE
        WHEN EXCLUDED.online AND NOT worker_presence.online THEN NOW()
        WHEN EXCLUDED.online THEN COALESCE(worker_presence.online_since, NOW())
        ELSE NULL
      END,
      last_offline_at = CASE
        WHEN NOT EXCLUDED.online AND worker_presence.online THEN NOW()
        ELSE worker_presence.last_offline_at
      END,
      location_updated_at = CASE
        WHEN EXCLUDED.latitude IS NOT NULL AND EXCLUDED.longitude IS NOT NULL
          AND (
            worker_presence.latitude IS DISTINCT FROM EXCLUDED.latitude OR
            worker_presence.longitude IS DISTINCT FROM EXCLUDED.longitude
          )
        THEN NOW()
        ELSE worker_presence.location_updated_at
      END,
      token_updated_at = CASE
        WHEN EXCLUDED.fcm_token IS NOT NULL
          AND worker_presence.fcm_token IS DISTINCT FROM EXCLUDED.fcm_token
        THEN NOW()
        ELSE worker_presence.token_updated_at
      END
    RETURNING worker_enrollment_id AS "workerId", online,
      online_since AS "onlineSince", last_seen_at AS "lastSeenAt"
  `, [worker.rows[0].id, value.fcmToken, value.platform, value.online,
    value.latitude, value.longitude]);
  return result.rows[0];
}

async function getMatchDiagnostics(client, value) {
  const result = await client.query(`
    WITH evaluated AS (
      SELECT
        we.id,
        (wp.worker_enrollment_id IS NOT NULL) AS has_presence,
        (wp.online = TRUE) AS is_online,
        (wp.last_seen_at > NOW() - INTERVAL '12 hours') AS is_fresh,
        (wp.fcm_token IS NOT NULL AND wp.fcm_token <> '') AS has_token,
        (wp.latitude IS NOT NULL AND wp.longitude IS NOT NULL) AS has_location,
        (
          ($3 = 'helper' AND 'helper' = ANY(we.enrollment_types)) OR
          ($3 = 'professional' AND 'professional' = ANY(we.enrollment_types)
            AND EXISTS (
              SELECT 1 FROM unnest(we.professional_categories) category
              WHERE LOWER(category) = LOWER($4)
            ))
        ) AS matches_service,
        NOT EXISTS (
          SELECT 1 FROM worker_job_dispatches active_job
          WHERE active_job.accepted_worker_id = we.id
            AND active_job.status IN ('accepted', 'arrived', 'started', 'completion_requested')
        ) AS is_available,
        CASE
          WHEN wp.latitude IS NULL OR wp.longitude IS NULL THEN NULL
          ELSE 6371 * 2 * ASIN(SQRT(
            POWER(SIN(RADIANS(wp.latitude - $1) / 2), 2) +
            COS(RADIANS($1)) * COS(RADIANS(wp.latitude)) *
            POWER(SIN(RADIANS(wp.longitude - $2) / 2), 2)
          ))
        END AS distance_km,
        we.travel_radius_km
      FROM worker_enrollments we
      LEFT JOIN worker_presence wp ON wp.worker_enrollment_id = we.id
      WHERE we.worker_status = 'verified'
    )
    SELECT
      COUNT(*)::int AS "verifiedWorkers",
      COUNT(*) FILTER (WHERE has_presence)::int AS "withPresence",
      COUNT(*) FILTER (WHERE has_presence AND is_online)::int AS "online",
      COUNT(*) FILTER (
        WHERE has_presence AND is_online AND is_fresh
      )::int AS "fresh",
      COUNT(*) FILTER (
        WHERE has_presence AND is_online AND is_fresh AND has_token
      )::int AS "tokenReady",
      COUNT(*) FILTER (
        WHERE has_presence AND is_online AND is_fresh AND has_token
          AND has_location
      )::int AS "locationReady",
      COUNT(*) FILTER (
        WHERE has_presence AND is_online AND is_fresh AND has_token
          AND has_location AND matches_service
      )::int AS "serviceEligible",
      COUNT(*) FILTER (
        WHERE has_presence AND is_online AND is_fresh AND has_token
          AND has_location AND matches_service AND is_available
      )::int AS "available",
      COUNT(*) FILTER (
        WHERE has_presence AND is_online AND is_fresh AND has_token
          AND has_location AND matches_service AND is_available
          AND distance_km <= travel_radius_km
      )::int AS "withinTravelRadius"
    FROM evaluated
  `, [value.latitude, value.longitude, value.serviceType, value.category]);
  return result.rows[0];
}

async function dispatchJob(pool, value) {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const matchDiagnostics = await getMatchDiagnostics(client, value);
    const existing = await client.query(`
      SELECT id, status
      FROM worker_job_dispatches
      WHERE customer_task_id = $1
      ORDER BY created_at DESC
      LIMIT 1
      FOR UPDATE
    `, [value.customerTaskId]);
    if (existing.rowCount) {
      await client.query('COMMIT');
      return {
        id: existing.rows[0].id,
        status: existing.rows[0].status,
        matchedWorkers: 0,
        matchDiagnostics,
        push: { configured: Boolean(messaging), attempted: 0, succeeded: 0 },
        existing: true,
      };
    }
    const job = await client.query(`
      INSERT INTO worker_job_dispatches (
        customer_task_id, service_type, category, title, notes, address_text,
        latitude, longitude, budget
      ) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9) RETURNING *
    `, [value.customerTaskId, value.serviceType, value.category, value.title,
      value.notes, value.address, value.latitude, value.longitude, value.budget]);
    const candidates = await client.query(`
      SELECT we.id, wp.fcm_token,
        6371 * 2 * ASIN(SQRT(
          POWER(SIN(RADIANS(wp.latitude - $1) / 2), 2) +
          COS(RADIANS($1)) * COS(RADIANS(wp.latitude)) *
          POWER(SIN(RADIANS(wp.longitude - $2) / 2), 2)
        )) AS distance_km
      FROM worker_enrollments we
      JOIN worker_presence wp ON wp.worker_enrollment_id = we.id
      WHERE we.worker_status = 'verified'
        AND wp.online = TRUE
        AND wp.fcm_token IS NOT NULL AND wp.fcm_token <> ''
        -- Android may suspend the Flutter process while the worker app is in
        -- the background. Keep an explicit "online" choice valid for a work
        -- shift; the app refreshes this lease every minute while foregrounded.
        AND wp.last_seen_at > NOW() - INTERVAL '12 hours'
        AND wp.latitude IS NOT NULL AND wp.longitude IS NOT NULL
        AND NOT EXISTS (
          SELECT 1 FROM worker_job_dispatches active_job
          WHERE active_job.accepted_worker_id = we.id
            AND active_job.status IN ('accepted', 'arrived', 'started', 'completion_requested')
        )
        AND (
          ($3 = 'helper' AND 'helper' = ANY(we.enrollment_types)) OR
          ($3 = 'professional' AND 'professional' = ANY(we.enrollment_types)
            AND EXISTS (SELECT 1 FROM unnest(we.professional_categories) c WHERE LOWER(c) = LOWER($4)))
        )
        AND 6371 * 2 * ASIN(SQRT(
          POWER(SIN(RADIANS(wp.latitude - $1) / 2), 2) +
          COS(RADIANS($1)) * COS(RADIANS(wp.latitude)) *
          POWER(SIN(RADIANS(wp.longitude - $2) / 2), 2)
        )) <= we.travel_radius_km
      ORDER BY distance_km ASC LIMIT 50
    `, [value.latitude, value.longitude, value.serviceType, value.category]);
    for (const worker of candidates.rows) {
      await client.query(
        'INSERT INTO worker_job_offers(job_id, worker_enrollment_id) VALUES ($1,$2)',
        [job.rows[0].id, worker.id]
      );
    }
    await client.query('COMMIT');

    const recipients = candidates.rows.filter((row) => Boolean(row.fcm_token));
    const tokens = recipients.map((row) => row.fcm_token);
    let push = { configured: Boolean(messaging), attempted: tokens.length, succeeded: 0 };
    if (messaging && tokens.length) {
      try {
        const expiresAt = new Date(job.rows[0].expires_at).toISOString();
        const response = await messaging.sendEach(recipients.map((recipient) => ({
          token: recipient.fcm_token,
          notification: { title: 'New Gofer job nearby', body: `${value.title} · Rs ${value.budget}` },
          data: {
            type: 'job_offer', jobId: job.rows[0].id, workType: value.category,
            customerArea: value.address,
            distanceKm: Number(recipient.distance_km).toFixed(1),
            durationLabel: 'New request',
            notes: value.notes || '',
            budget: String(value.budget),
            status: 'offered',
            expiresAt,
          },
          android: {
            priority: 'high',
            ttl: 120000,
            notification: { channelId: 'gofer_jobs_v2', sound: 'default', priority: 'max', visibility: 'public' }
          }
        })));
        push.succeeded = response.successCount;
        const summary = summarizeMessagingResponses(response, recipients);
        if (summary.failures.length) {
          push.failureCodes = summary.failureCodes;
          messagingLogger.warn('Firebase job push delivery failed', {
            jobId: job.rows[0].id,
            projectId: messagingProjectId,
            attempted: tokens.length,
            succeeded: response.successCount,
            failures: summary.failures,
          });

          const invalidWorkerIds = summary.failures
            .filter((failure) => failure.invalidToken && failure.workerId)
            .map((failure) => failure.workerId);
          if (invalidWorkerIds.length) {
            await client.query(`
              UPDATE worker_presence
              SET fcm_token = NULL, online = FALSE, updated_at = NOW()
              WHERE worker_enrollment_id = ANY($1::uuid[])
            `, [invalidWorkerIds]);
          }
        }
      } catch (error) {
        const code = messagingErrorCode(error);
        push.failureCodes = { [code]: tokens.length };
        messagingLogger.error('Firebase job push request failed', {
          jobId: job.rows[0].id,
          projectId: messagingProjectId,
          attempted: tokens.length,
          code,
        });
      }
    }
    return {
      id: job.rows[0].id,
      matchedWorkers: candidates.rowCount,
      matchDiagnostics,
      push,
    };
  } catch (error) {
    await client.query('ROLLBACK');
    throw error;
  } finally { client.release(); }
}

async function respondToJob(pool, jobId, phone, decision) {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const worker = await client.query('SELECT id FROM worker_enrollments WHERE phone=$1', [phone]);
    if (!worker.rowCount) return null;
    const offer = await client.query(`
      UPDATE worker_job_offers SET status=$1, responded_at=NOW()
      WHERE job_id=$2 AND worker_enrollment_id=$3 AND status='offered' RETURNING *
    `, [decision, jobId, worker.rows[0].id]);
    if (!offer.rowCount) { await client.query('ROLLBACK'); return null; }
    if (decision === 'accepted') {
      const claimed = await client.query(`
        UPDATE worker_job_dispatches SET status='accepted', accepted_worker_id=$1
        WHERE id=$2 AND status='offered' AND expires_at>NOW() RETURNING id
      `, [worker.rows[0].id, jobId]);
      if (!claimed.rowCount) { await client.query('ROLLBACK'); return { accepted: false }; }
      await client.query(`UPDATE worker_job_offers SET status='expired', responded_at=NOW()
        WHERE job_id=$1 AND worker_enrollment_id<>$2 AND status='offered'`, [jobId, worker.rows[0].id]);
    }
    await client.query('COMMIT');
    return { accepted: decision === 'accepted', decision };
  } catch (error) { await client.query('ROLLBACK'); throw error; }
  finally { client.release(); }
}

async function getDispatchStatus(pool, customerTaskId) {
  await pool.query(`
    UPDATE worker_job_dispatches
    SET status = 'expired'
    WHERE customer_task_id = $1 AND status = 'offered' AND expires_at <= NOW()
  `, [customerTaskId]);
  const result = await pool.query(`
    SELECT
      d.id, d.customer_task_id, d.status, d.category, d.budget,
      d.created_at, d.expires_at, d.replacement_attempts,
      we.id AS worker_id, we.full_name,
      we.enrollment_types, we.professional_categories,
      wp.latitude, wp.longitude,
      (SELECT COUNT(*)::int FROM worker_job_offers o
        WHERE o.job_id = d.id AND o.status IN ('offered', 'accepted')) AS offer_count
    FROM worker_job_dispatches d
    LEFT JOIN worker_enrollments we ON we.id = d.accepted_worker_id
    LEFT JOIN worker_presence wp ON wp.worker_enrollment_id = we.id
    WHERE d.customer_task_id = $1
    ORDER BY d.created_at DESC
    LIMIT 1
  `, [customerTaskId]);
  if (!result.rowCount) return null;
  const row = result.rows[0];
  return {
    id: row.id,
    customerTaskId: row.customer_task_id,
    status: row.status,
    offerCount: row.offer_count,
    createdAt: row.created_at,
    expiresAt: row.expires_at,
    replacementAttempts: row.replacement_attempts,
    worker: row.worker_id ? {
      id: row.worker_id,
      name: row.full_name,
      workerType: row.enrollment_types?.includes('professional') ? 'professional' : 'helper',
      skill: row.professional_categories?.[0] || row.category || 'General helper',
      verified: true,
      availability: true,
      locationVerified: row.latitude != null && row.longitude != null,
      latitude: row.latitude,
      longitude: row.longitude,
      rating: 0,
      jobsCompleted: 0,
      distanceKm: 0,
      etaMinutes: 0,
      hourlyRate: row.budget,
    } : null,
  };
}

async function updateJobStatusByCustomerTask(pool, customerTaskId, status) {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const allowedPrevious = status === 'started'
      ? ['completion_requested', 'started']
      : ['offered', 'accepted', 'arrived', 'started', 'completion_requested', status];
    const result = await client.query(`
      UPDATE worker_job_dispatches
      SET status = $2,
          updated_at = NOW(),
          completed_at = CASE
            WHEN $2 = 'completed' THEN COALESCE(completed_at, NOW())
            ELSE completed_at
          END
      WHERE customer_task_id = $1
        AND status = ANY($3::varchar[])
      RETURNING id, customer_task_id AS "customerTaskId", status
    `, [customerTaskId, status, allowedPrevious]);
    if (result.rowCount) {
      await client.query(`
        UPDATE worker_job_offers
        SET status = CASE WHEN status = 'offered' THEN 'expired' ELSE status END,
            responded_at = COALESCE(responded_at, NOW())
        WHERE job_id = $1
      `, [result.rows[0].id]);
    }
    await client.query('COMMIT');
    return result.rows[0] || null;
  } catch (error) {
    await client.query('ROLLBACK');
    throw error;
  } finally {
    client.release();
  }
}

async function sendReplacementOffers(pool, job, candidates) {
  const recipients = candidates.filter((candidate) => Boolean(candidate.fcm_token));
  const push = {
    configured: Boolean(messaging),
    attempted: recipients.length,
    succeeded: 0,
  };
  if (!messaging || !recipients.length) return push;

  try {
    const expiresAt = new Date(job.expires_at).toISOString();
    const response = await messaging.sendEach(recipients.map((recipient) => ({
      token: recipient.fcm_token,
      notification: {
        title: 'New Gofer job nearby',
        body: `${job.title} · Rs ${job.budget}`,
      },
      data: {
        type: 'job_offer',
        jobId: job.id,
        workType: job.category,
        customerArea: job.address_text,
        distanceKm: Number(recipient.distance_km).toFixed(1),
        durationLabel: 'Replacement request',
        notes: job.notes || '',
        budget: String(job.budget),
        status: 'offered',
        expiresAt,
      },
      android: {
        priority: 'high',
        ttl: JOB_OFFER_TTL_MS,
        notification: {
          channelId: 'gofer_jobs_v2',
          sound: 'default',
          priority: 'max',
          visibility: 'public',
        },
      },
    })));
    push.succeeded = response.successCount;
    const summary = summarizeMessagingResponses(response, recipients);
    if (summary.failures.length) {
      push.failureCodes = summary.failureCodes;
      messagingLogger.warn('Firebase replacement push delivery failed', {
        jobId: job.id,
        attempted: recipients.length,
        succeeded: response.successCount,
        failures: summary.failures,
      });
      const invalidWorkerIds = summary.failures
        .filter((failure) => failure.invalidToken && failure.workerId)
        .map((failure) => failure.workerId);
      if (invalidWorkerIds.length) {
        await pool.query(`
          UPDATE worker_presence
          SET fcm_token=NULL, online=FALSE, updated_at=NOW()
          WHERE worker_enrollment_id=ANY($1::uuid[])
        `, [invalidWorkerIds]);
      }
    }
  } catch (error) {
    const code = messagingErrorCode(error);
    push.failureCodes = { [code]: recipients.length };
    messagingLogger.error('Firebase replacement push request failed', {
      jobId: job.id,
      attempted: recipients.length,
      code,
    });
  }
  return push;
}

async function cancelAndRematchJob(pool, jobId, phone) {
  const client = await pool.connect();
  let rematch;
  try {
    await client.query('BEGIN');
    const worker = await client.query(
      'SELECT id FROM worker_enrollments WHERE phone=$1 LIMIT 1',
      [phone],
    );
    if (!worker.rowCount) {
      await client.query('ROLLBACK');
      return null;
    }

    const workerId = worker.rows[0].id;
    const locked = await client.query(`
      SELECT *
      FROM worker_job_dispatches
      WHERE id=$1 AND accepted_worker_id=$2
        AND status IN ('accepted', 'arrived')
      FOR UPDATE
    `, [jobId, workerId]);
    if (!locked.rowCount) {
      const priorCancellation = await client.query(`
        SELECT d.id, d.customer_task_id, d.status, d.replacement_attempts,
          (SELECT COUNT(*)::int FROM worker_job_offers active_offer
            WHERE active_offer.job_id=d.id
              AND active_offer.status IN ('offered','accepted')) AS matched_workers
        FROM worker_job_dispatches d
        JOIN worker_job_offers worker_offer
          ON worker_offer.job_id=d.id AND worker_offer.worker_enrollment_id=$2
        WHERE d.id=$1 AND d.accepted_worker_id IS NULL
          AND worker_offer.status='cancelled'
          AND d.status IN ('offered','expired')
        FOR UPDATE OF d
      `, [jobId, workerId]);
      if (priorCancellation.rowCount) {
        await client.query('COMMIT');
        const prior = priorCancellation.rows[0];
        return {
          id: prior.id,
          customerTaskId: prior.customer_task_id,
          status: prior.status,
          rematching: prior.status === 'offered',
          replacementAttempts: prior.replacement_attempts,
          matchedWorkers: prior.matched_workers,
          push: {
            configured: Boolean(messaging),
            attempted: 0,
            succeeded: 0,
          },
          existing: true,
        };
      }
      await client.query('ROLLBACK');
      return null;
    }

    const current = locked.rows[0];
    const replacementAttempts = Number(current.replacement_attempts || 0) + 1;
    const canRematch = replacementAttempts <= MAX_REPLACEMENT_ATTEMPTS;
    const excludedWorkerIds = [
      ...(current.excluded_worker_ids || []),
      workerId,
    ];
    const updated = await client.query(`
      UPDATE worker_job_dispatches
      SET status=$3,
          accepted_worker_id=NULL,
          replacement_attempts=$4,
          excluded_worker_ids=$5::uuid[],
          expires_at=CASE
            WHEN $6 THEN NOW() + INTERVAL '2 minutes'
            ELSE NOW()
          END
      WHERE id=$1 AND accepted_worker_id=$2
      RETURNING *
    `, [
      jobId,
      workerId,
      canRematch ? 'offered' : 'expired',
      replacementAttempts,
      excludedWorkerIds,
      canRematch,
    ]);
    await client.query(`
      UPDATE worker_job_offers
      SET status='cancelled', responded_at=NOW()
      WHERE job_id=$1 AND worker_enrollment_id=$2
    `, [jobId, workerId]);

    let candidates = { rows: [], rowCount: 0 };
    if (canRematch) {
      candidates = await client.query(`
        SELECT we.id, wp.fcm_token,
          6371 * 2 * ASIN(SQRT(
            POWER(SIN(RADIANS(wp.latitude - $1) / 2), 2) +
            COS(RADIANS($1)) * COS(RADIANS(wp.latitude)) *
            POWER(SIN(RADIANS(wp.longitude - $2) / 2), 2)
          )) AS distance_km
        FROM worker_enrollments we
        JOIN worker_presence wp ON wp.worker_enrollment_id=we.id
        WHERE we.worker_status='verified'
          AND wp.online=TRUE
          AND wp.fcm_token IS NOT NULL AND wp.fcm_token<>''
          AND wp.last_seen_at > NOW() - INTERVAL '12 hours'
          AND wp.latitude IS NOT NULL AND wp.longitude IS NOT NULL
          AND NOT (we.id=ANY($5::uuid[]))
          AND NOT EXISTS (
            SELECT 1 FROM worker_job_dispatches active_job
            WHERE active_job.accepted_worker_id=we.id
              AND active_job.status IN ('accepted','arrived','started','completion_requested')
          )
          AND (
            ($3='helper' AND 'helper'=ANY(we.enrollment_types)) OR
            ($3='professional' AND 'professional'=ANY(we.enrollment_types)
              AND EXISTS (
                SELECT 1 FROM unnest(we.professional_categories) category
                WHERE LOWER(category)=LOWER($4)
              ))
          )
          AND 6371 * 2 * ASIN(SQRT(
            POWER(SIN(RADIANS(wp.latitude - $1) / 2), 2) +
            COS(RADIANS($1)) * COS(RADIANS(wp.latitude)) *
            POWER(SIN(RADIANS(wp.longitude - $2) / 2), 2)
          )) <= we.travel_radius_km
          AND NOT EXISTS (
            SELECT 1 FROM worker_job_offers prior
            WHERE prior.job_id=$6 AND prior.worker_enrollment_id=we.id
              AND prior.status='rejected'
          )
        ORDER BY distance_km ASC
        LIMIT 50
      `, [
        current.latitude,
        current.longitude,
        current.service_type,
        current.category,
        excludedWorkerIds,
        jobId,
      ]);
      for (const candidate of candidates.rows) {
        await client.query(`
          INSERT INTO worker_job_offers(job_id, worker_enrollment_id)
          VALUES ($1,$2)
          ON CONFLICT (job_id, worker_enrollment_id) DO UPDATE
          SET status='offered', responded_at=NULL, created_at=NOW()
          WHERE worker_job_offers.status NOT IN ('rejected','cancelled')
        `, [jobId, candidate.id]);
      }
    }

    await client.query('COMMIT');
    rematch = {
      job: updated.rows[0],
      candidates: candidates.rows,
      matchedWorkers: candidates.rowCount,
      canRematch,
      replacementAttempts,
    };
  } catch (error) {
    await client.query('ROLLBACK');
    throw error;
  } finally {
    client.release();
  }

  const push = rematch.canRematch
    ? await sendReplacementOffers(pool, rematch.job, rematch.candidates)
    : { configured: Boolean(messaging), attempted: 0, succeeded: 0 };
  return {
    id: rematch.job.id,
    customerTaskId: rematch.job.customer_task_id,
    status: rematch.job.status,
    rematching: rematch.canRematch,
    replacementAttempts: rematch.replacementAttempts,
    matchedWorkers: rematch.matchedWorkers,
    push,
  };
}

async function updateJobStatusByWorker(pool, jobId, phone, nextStatus) {
  if (nextStatus === 'cancelled') {
    return cancelAndRematchJob(pool, jobId, phone);
  }
  const worker = await pool.query(
    'SELECT id FROM worker_enrollments WHERE phone=$1 LIMIT 1',
    [phone]
  );
  if (!worker.rowCount) return null;
  const allowedPrevious = previousStatusesFor(nextStatus);
  const result = await pool.query(`
    UPDATE worker_job_dispatches
    SET status = $3,
        updated_at = NOW(),
        completed_at = CASE
          WHEN $3 = 'completed' THEN COALESCE(completed_at, NOW())
          ELSE completed_at
        END
    WHERE id = $1 AND accepted_worker_id = $2
      AND status = ANY($4::varchar[])
    RETURNING id, customer_task_id AS "customerTaskId", status
  `, [jobId, worker.rows[0].id, nextStatus, allowedPrevious]);
  return result.rows[0] || null;
}

async function getWorkerDashboard(pool, phone, limit = 50) {
  const worker = await pool.query(
    `SELECT id FROM worker_enrollments
     WHERE phone = $1 AND worker_status = 'verified'
     LIMIT 1`,
    [phone],
  );
  if (!worker.rowCount) return null;

  const workerId = worker.rows[0].id;
  const [summary, history] = await Promise.all([
    pool.query(`
      SELECT
        COALESCE(SUM(budget) FILTER (
          WHERE completed_at >= date_trunc('day', NOW() AT TIME ZONE 'Asia/Kolkata')
            AT TIME ZONE 'Asia/Kolkata'
        ), 0)::int AS "earningsToday",
        COALESCE(SUM(budget), 0)::int AS "totalEarnings",
        COUNT(*)::int AS "completedJobs"
      FROM worker_job_dispatches
      WHERE accepted_worker_id = $1 AND status = 'completed'
    `, [workerId]),
    pool.query(`
      SELECT id,
        customer_task_id AS "customerTaskId",
        category AS "workType",
        address_text AS "customerArea",
        budget,
        status,
        created_at AS "createdAt",
        completed_at AS "completedAt"
      FROM worker_job_dispatches
      WHERE accepted_worker_id = $1 AND status = 'completed'
      ORDER BY completed_at DESC NULLS LAST, created_at DESC
      LIMIT $2
    `, [workerId, limit]),
  ]);

  return {
    ...summary.rows[0],
    history: history.rows,
  };
}

async function getWorkerJobStatus(pool, jobId, phone) {
  const result = await pool.query(`
    SELECT d.id, d.customer_task_id AS "customerTaskId", d.status,
      o.status AS "offerStatus",
      (d.accepted_worker_id = we.id) AS "isAcceptedWorker"
    FROM worker_job_dispatches d
    JOIN worker_job_offers o ON o.job_id = d.id
    JOIN worker_enrollments we ON we.id = o.worker_enrollment_id
    WHERE d.id = $1 AND we.phone = $2
    LIMIT 1
  `, [jobId, phone]);
  return result.rows[0] || null;
}

module.exports = {
  initializeMessaging,
  getMessagingStatus,
  ensureDispatchSchema,
  updatePresence,
  dispatchJob,
  respondToJob,
  getDispatchStatus,
  updateJobStatusByCustomerTask,
  updateJobStatusByWorker,
  getWorkerJobStatus,
  getWorkerDashboard,
  getPendingWorkerJob,
  cancelAndRematchJob,
  MAX_REPLACEMENT_ATTEMPTS,
};
