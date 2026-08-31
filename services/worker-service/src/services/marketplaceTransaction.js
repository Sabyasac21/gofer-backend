const crypto = require('crypto');

class MarketplaceError extends Error {
  constructor(message, statusCode = 400, code = 'MARKETPLACE_ERROR') {
    super(message);
    this.name = 'MarketplaceError';
    this.statusCode = statusCode;
    this.code = code;
  }
}

const hashToken = (token) => crypto.createHash('sha256').update(token).digest('hex');

async function ensureMarketplaceSchema(pool) {
  await pool.query(`
    ALTER TABLE worker_job_dispatches ADD COLUMN IF NOT EXISTS customer_id UUID;
    ALTER TABLE worker_job_dispatches ADD COLUMN IF NOT EXISTS original_scope JSONB NOT NULL DEFAULT '[]'::jsonb;
    ALTER TABLE worker_job_dispatches ADD COLUMN IF NOT EXISTS original_labour INTEGER;
    ALTER TABLE worker_job_dispatches ADD COLUMN IF NOT EXISTS current_labour INTEGER;
    ALTER TABLE worker_job_dispatches ADD COLUMN IF NOT EXISTS financial_hold BOOLEAN NOT NULL DEFAULT FALSE;
    ALTER TABLE worker_job_dispatches ADD COLUMN IF NOT EXISTS closed_at TIMESTAMPTZ;
    ALTER TABLE worker_job_dispatches ADD COLUMN IF NOT EXISTS estimated_duration_minutes INTEGER;
    ALTER TABLE worker_job_dispatches ADD COLUMN IF NOT EXISTS pricing_snapshot JSONB;
    ALTER TABLE worker_job_dispatches ADD COLUMN IF NOT EXISTS arrival_verified_at TIMESTAMPTZ;
    UPDATE worker_job_dispatches
      SET original_labour = COALESCE(original_labour, budget),
          current_labour = COALESCE(current_labour, budget),
          original_scope = CASE
            WHEN original_scope = '[]'::jsonb
              THEN jsonb_build_array(jsonb_build_object('id', 'original', 'label', title))
            ELSE original_scope
          END;
    DO $$
    BEGIN
      IF to_regclass('public.gofer_customer_tasks') IS NOT NULL THEN
        UPDATE worker_job_dispatches d
          SET customer_id = t.customer_id
          FROM gofer_customer_tasks t
          WHERE t.id::text = d.customer_task_id AND d.customer_id IS NULL;
      END IF;
    END $$;
    CREATE UNIQUE INDEX IF NOT EXISTS worker_job_dispatches_customer_task_unique
      ON worker_job_dispatches(customer_task_id);
    CREATE INDEX IF NOT EXISTS worker_job_dispatches_customer_idx
      ON worker_job_dispatches(customer_id, created_at DESC);

    CREATE TABLE IF NOT EXISTS marketplace_job_events (
      id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
      job_id UUID NOT NULL REFERENCES worker_job_dispatches(id) ON DELETE CASCADE,
      event_type VARCHAR(80) NOT NULL,
      actor_type VARCHAR(20) NOT NULL,
      actor_id VARCHAR(160),
      metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
      idempotency_key UUID,
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    );
    CREATE UNIQUE INDEX IF NOT EXISTS marketplace_job_events_idempotency_idx
      ON marketplace_job_events(job_id, idempotency_key)
      WHERE idempotency_key IS NOT NULL;
    CREATE INDEX IF NOT EXISTS marketplace_job_events_timeline_idx
      ON marketplace_job_events(job_id, created_at, id);

    CREATE TABLE IF NOT EXISTS marketplace_scope_versions (
      id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
      job_id UUID NOT NULL REFERENCES worker_job_dispatches(id) ON DELETE CASCADE,
      version INTEGER NOT NULL,
      scope JSONB NOT NULL,
      initiated_by_type VARCHAR(20) NOT NULL,
      initiated_by_id VARCHAR(160),
      approved_by_type VARCHAR(20),
      approved_by_id VARCHAR(160),
      price_difference INTEGER NOT NULL DEFAULT 0,
      source_request_id UUID,
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      UNIQUE(job_id, version),
      UNIQUE(source_request_id)
    );

    CREATE TABLE IF NOT EXISTS marketplace_requirements (
      id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
      job_id UUID NOT NULL REFERENCES worker_job_dispatches(id) ON DELETE CASCADE,
      kind VARCHAR(30) NOT NULL CHECK (kind IN ('material', 'special_tool')),
      description VARCHAR(500) NOT NULL,
      quantity VARCHAR(80),
      reason VARCHAR(500) NOT NULL,
      image_uri TEXT,
      standard_tool BOOLEAN NOT NULL DEFAULT FALSE,
      status VARCHAR(30) NOT NULL DEFAULT 'requested'
        CHECK (status IN ('requested','acknowledged','arranged','confirmed','cancelled','rejected')),
      requested_by_worker_id UUID NOT NULL REFERENCES worker_enrollments(id),
      customer_acknowledged_at TIMESTAMPTZ,
      customer_arranged_at TIMESTAMPTZ,
      worker_confirmed_at TIMESTAMPTZ,
      idempotency_key UUID NOT NULL,
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      UNIQUE(job_id, idempotency_key)
    );

    CREATE TABLE IF NOT EXISTS marketplace_time_segments (
      id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
      job_id UUID NOT NULL REFERENCES worker_job_dispatches(id) ON DELETE CASCADE,
      segment_type VARCHAR(40) NOT NULL CHECK (segment_type IN
        ('working','customer_waiting','worker_break','worker_delay','system_pause','material_wait','special_tool_wait')),
      reason VARCHAR(500),
      created_by_type VARCHAR(20) NOT NULL,
      created_by_id VARCHAR(160),
      started_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      ended_at TIMESTAMPTZ,
      waiting_compensation INTEGER NOT NULL DEFAULT 0,
      idempotency_key UUID NOT NULL,
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      UNIQUE(job_id, idempotency_key)
    );
    CREATE UNIQUE INDEX IF NOT EXISTS marketplace_time_one_open_idx
      ON marketplace_time_segments(job_id) WHERE ended_at IS NULL;

    CREATE TABLE IF NOT EXISTS marketplace_additional_work (
      id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
      job_id UUID NOT NULL REFERENCES worker_job_dispatches(id) ON DELETE CASCADE,
      description VARCHAR(1000) NOT NULL,
      additional_labour INTEGER NOT NULL CHECK (additional_labour > 0),
      estimated_minutes INTEGER NOT NULL CHECK (estimated_minutes > 0),
      reason VARCHAR(500) NOT NULL,
      evidence JSONB NOT NULL DEFAULT '[]'::jsonb,
      worker_id UUID NOT NULL REFERENCES worker_enrollments(id),
      status VARCHAR(20) NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending','approved','declined','expired','cancelled')),
      expires_at TIMESTAMPTZ NOT NULL,
      resolved_at TIMESTAMPTZ,
      resolved_by_customer_id UUID,
      request_idempotency_key UUID NOT NULL,
      decision_idempotency_key UUID,
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      UNIQUE(job_id, request_idempotency_key),
      UNIQUE(job_id, decision_idempotency_key)
    );

    CREATE TABLE IF NOT EXISTS marketplace_completion_evidence (
      id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
      job_id UUID NOT NULL REFERENCES worker_job_dispatches(id) ON DELETE CASCADE,
      kind VARCHAR(30) NOT NULL CHECK (kind IN ('before_photo','after_photo','worker_note','customer_note')),
      uri TEXT,
      note VARCHAR(1000),
      created_by_type VARCHAR(20) NOT NULL,
      created_by_id VARCHAR(160),
      idempotency_key UUID NOT NULL,
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      UNIQUE(job_id, idempotency_key)
    );

    CREATE TABLE IF NOT EXISTS marketplace_remaining_work (
      id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
      job_id UUID NOT NULL REFERENCES worker_job_dispatches(id) ON DELETE CASCADE,
      customer_id UUID NOT NULL,
      description VARCHAR(1500) NOT NULL,
      evidence JSONB NOT NULL DEFAULT '[]'::jsonb,
      idempotency_key UUID NOT NULL,
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      UNIQUE(job_id, idempotency_key)
    );

    CREATE TABLE IF NOT EXISTS marketplace_disputes (
      id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
      job_id UUID NOT NULL REFERENCES worker_job_dispatches(id) ON DELETE CASCADE,
      customer_id UUID NOT NULL,
      category VARCHAR(60) NOT NULL,
      description VARCHAR(2000) NOT NULL,
      evidence JSONB NOT NULL DEFAULT '[]'::jsonb,
      status VARCHAR(30) NOT NULL DEFAULT 'open'
        CHECK (status IN ('open','reviewing','resolved','rejected','cancelled')),
      scope_version INTEGER,
      idempotency_key UUID NOT NULL,
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      UNIQUE(job_id, idempotency_key)
    );

    CREATE TABLE IF NOT EXISTS marketplace_safety_events (
      id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
      job_id UUID NOT NULL REFERENCES worker_job_dispatches(id) ON DELETE CASCADE,
      actor_type VARCHAR(20) NOT NULL,
      actor_id VARCHAR(160),
      category VARCHAR(80) NOT NULL,
      description VARCHAR(2000) NOT NULL,
      status VARCHAR(30) NOT NULL DEFAULT 'open',
      idempotency_key UUID NOT NULL,
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      UNIQUE(job_id, idempotency_key)
    );

    CREATE TABLE IF NOT EXISTS marketplace_payments (
      id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
      job_id UUID NOT NULL UNIQUE REFERENCES worker_job_dispatches(id) ON DELETE CASCADE,
      customer_id UUID NOT NULL,
      worker_id UUID NOT NULL REFERENCES worker_enrollments(id),
      original_labour INTEGER NOT NULL,
      approved_additional_labour INTEGER NOT NULL DEFAULT 0,
      waiting_compensation INTEGER NOT NULL DEFAULT 0,
      final_labour INTEGER NOT NULL,
      currency VARCHAR(3) NOT NULL DEFAULT 'INR',
      status VARCHAR(30) NOT NULL DEFAULT 'pending'
        CHECK (status IN ('not_required','pending','processing','success','failed','cancelled','refund_pending','refunded','partially_refunded')),
      financial_hold BOOLEAN NOT NULL DEFAULT FALSE,
      paid_at TIMESTAMPTZ,
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    );
    ALTER TABLE marketplace_payments ADD COLUMN IF NOT EXISTS visit_fee_minor BIGINT;
    ALTER TABLE marketplace_payments ADD COLUMN IF NOT EXISTS customer_labour_minor BIGINT;
    ALTER TABLE marketplace_payments ADD COLUMN IF NOT EXISTS final_customer_amount_minor BIGINT;
    ALTER TABLE marketplace_payments ADD COLUMN IF NOT EXISTS customer_amount_due_minor BIGINT;
    ALTER TABLE marketplace_payments ADD COLUMN IF NOT EXISTS worker_payout_minor BIGINT;
    ALTER TABLE marketplace_payments ADD COLUMN IF NOT EXISTS worker_visit_payout_minor BIGINT;
    ALTER TABLE marketplace_payments ADD COLUMN IF NOT EXISTS worker_labour_minor BIGINT;
    ALTER TABLE marketplace_payments ADD COLUMN IF NOT EXISTS platform_margin_minor BIGINT;
    ALTER TABLE marketplace_payments ADD COLUMN IF NOT EXISTS verified_minutes INTEGER;
    ALTER TABLE marketplace_payments ADD COLUMN IF NOT EXISTS approved_overtime_minutes INTEGER;
    ALTER TABLE marketplace_payments ADD COLUMN IF NOT EXISTS visit_fee_paid BOOLEAN NOT NULL DEFAULT FALSE;
    ALTER TABLE marketplace_payments ADD COLUMN IF NOT EXISTS pricing_version VARCHAR(80);

    CREATE TABLE IF NOT EXISTS marketplace_payment_attempts (
      id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
      payment_id UUID NOT NULL REFERENCES marketplace_payments(id) ON DELETE CASCADE,
      idempotency_key UUID NOT NULL,
      provider VARCHAR(60) NOT NULL,
      provider_reference VARCHAR(200),
      status VARCHAR(30) NOT NULL DEFAULT 'pending',
      failure_code VARCHAR(100),
      failure_message VARCHAR(500),
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      UNIQUE(payment_id, idempotency_key)
    );

    CREATE TABLE IF NOT EXISTS marketplace_ledger_entries (
      id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
      job_id UUID NOT NULL REFERENCES worker_job_dispatches(id) ON DELETE CASCADE,
      payment_id UUID REFERENCES marketplace_payments(id),
      entry_type VARCHAR(50) NOT NULL,
      account VARCHAR(80) NOT NULL,
      amount INTEGER NOT NULL,
      currency VARCHAR(3) NOT NULL DEFAULT 'INR',
      reference_id UUID,
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    );
    ALTER TABLE marketplace_ledger_entries ADD COLUMN IF NOT EXISTS amount_minor BIGINT;

    CREATE TABLE IF NOT EXISTS marketplace_worker_earnings (
      id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
      job_id UUID NOT NULL UNIQUE REFERENCES worker_job_dispatches(id) ON DELETE CASCADE,
      worker_id UUID NOT NULL REFERENCES worker_enrollments(id),
      labour INTEGER NOT NULL,
      platform_fee INTEGER NOT NULL,
      adjustments INTEGER NOT NULL DEFAULT 0,
      payable INTEGER NOT NULL,
      status VARCHAR(30) NOT NULL DEFAULT 'pending',
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    );
    ALTER TABLE marketplace_worker_earnings ADD COLUMN IF NOT EXISTS visit_payout_minor BIGINT;
    ALTER TABLE marketplace_worker_earnings ADD COLUMN IF NOT EXISTS labour_payout_minor BIGINT;
    ALTER TABLE marketplace_worker_earnings ADD COLUMN IF NOT EXISTS payable_minor BIGINT;

    CREATE TABLE IF NOT EXISTS marketplace_cancellations (
      id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
      job_id UUID NOT NULL UNIQUE REFERENCES worker_job_dispatches(id) ON DELETE CASCADE,
      cancelled_by_type VARCHAR(20) NOT NULL,
      arrival_verified BOOLEAN NOT NULL DEFAULT FALSE,
      customer_charge_minor BIGINT NOT NULL DEFAULT 0,
      worker_payout_minor BIGINT NOT NULL DEFAULT 0,
      currency VARCHAR(3) NOT NULL DEFAULT 'INR',
      pricing_version VARCHAR(80),
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    );

    CREATE TABLE IF NOT EXISTS marketplace_ratings (
      id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
      job_id UUID NOT NULL UNIQUE REFERENCES worker_job_dispatches(id) ON DELETE CASCADE,
      customer_id UUID NOT NULL,
      worker_id UUID NOT NULL REFERENCES worker_enrollments(id),
      quality INTEGER NOT NULL CHECK (quality BETWEEN 1 AND 5),
      professionalism INTEGER NOT NULL CHECK (professionalism BETWEEN 1 AND 5),
      punctuality INTEGER NOT NULL CHECK (punctuality BETWEEN 1 AND 5),
      communication INTEGER NOT NULL CHECK (communication BETWEEN 1 AND 5),
      comment VARCHAR(1000),
      idempotency_key UUID NOT NULL,
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      UNIQUE(job_id, idempotency_key)
    );
  `);
}

async function authenticateCustomer(pool, customerId, token) {
  if (!customerId || !token) return false;
  const result = await pool.query(
    'SELECT 1 FROM gofer_customers WHERE id=$1 AND session_token_hash=$2',
    [customerId, hashToken(token)]
  );
  return result.rowCount === 1;
}

async function customerJob(pool, customerTaskId, customerId, { lock = false } = {}) {
  const result = await pool.query(`
    SELECT * FROM worker_job_dispatches
    WHERE customer_task_id=$1 AND customer_id=$2
    ORDER BY created_at DESC LIMIT 1 ${lock ? 'FOR UPDATE' : ''}
  `, [customerTaskId, customerId]);
  return result.rows[0] || null;
}

async function workerJob(pool, jobId, phone, { lock = false } = {}) {
  const result = await pool.query(`
    SELECT d.*, we.phone AS worker_phone
    FROM worker_job_dispatches d
    JOIN worker_enrollments we ON we.id=d.accepted_worker_id
    WHERE d.id=$1 AND we.phone=$2
    ${lock ? 'FOR UPDATE' : ''}
  `, [jobId, phone]);
  return result.rows[0] || null;
}

async function appendEvent(client, {
  jobId, eventType, actorType, actorId, metadata = {}, idempotencyKey = null,
}) {
  const result = await client.query(`
    INSERT INTO marketplace_job_events(
      job_id,event_type,actor_type,actor_id,metadata,idempotency_key
    ) VALUES($1,$2,$3,$4,$5::jsonb,$6)
    ON CONFLICT (job_id,idempotency_key) WHERE idempotency_key IS NOT NULL
    DO UPDATE SET idempotency_key=EXCLUDED.idempotency_key
    RETURNING *
  `, [jobId, eventType, actorType, actorId, JSON.stringify(metadata), idempotencyKey]);
  return result.rows[0];
}

async function transactionSnapshot(pool, jobId) {
  const [job, requirements, segments, additionalWork, scopes, evidence,
    remainingWork, disputes, safety, payment, earnings, cancellation, rating, events] = await Promise.all([
    pool.query(`SELECT id,customer_task_id AS "customerTaskId",customer_id AS "customerId",
      accepted_worker_id AS "workerId",status,original_scope AS "originalScope",
      original_labour AS "originalLabour",current_labour AS "currentLabour",
      estimated_duration_minutes AS "estimatedDurationMinutes",
      pricing_snapshot AS "pricingSnapshot",
      arrival_verified_at AS "arrivalVerifiedAt",
      financial_hold AS "financialHold",created_at AS "createdAt",updated_at AS "updatedAt"
      FROM worker_job_dispatches WHERE id=$1`, [jobId]),
    pool.query('SELECT * FROM marketplace_requirements WHERE job_id=$1 ORDER BY created_at', [jobId]),
    pool.query('SELECT * FROM marketplace_time_segments WHERE job_id=$1 ORDER BY started_at', [jobId]),
    pool.query('SELECT * FROM marketplace_additional_work WHERE job_id=$1 ORDER BY created_at', [jobId]),
    pool.query('SELECT * FROM marketplace_scope_versions WHERE job_id=$1 ORDER BY version', [jobId]),
    pool.query('SELECT * FROM marketplace_completion_evidence WHERE job_id=$1 ORDER BY created_at', [jobId]),
    pool.query('SELECT * FROM marketplace_remaining_work WHERE job_id=$1 ORDER BY created_at', [jobId]),
    pool.query('SELECT * FROM marketplace_disputes WHERE job_id=$1 ORDER BY created_at', [jobId]),
    pool.query('SELECT * FROM marketplace_safety_events WHERE job_id=$1 ORDER BY created_at', [jobId]),
    pool.query('SELECT * FROM marketplace_payments WHERE job_id=$1', [jobId]),
    pool.query('SELECT * FROM marketplace_worker_earnings WHERE job_id=$1', [jobId]),
    pool.query('SELECT * FROM marketplace_cancellations WHERE job_id=$1', [jobId]),
    pool.query('SELECT * FROM marketplace_ratings WHERE job_id=$1', [jobId]),
    pool.query(`SELECT id,event_type AS "eventType",actor_type AS "actorType",
      actor_id AS "actorId",metadata,created_at AS "createdAt"
      FROM marketplace_job_events WHERE job_id=$1 ORDER BY created_at,id`, [jobId]),
  ]);
  if (!job.rowCount) return null;
  return {
    job: job.rows[0], requirements: requirements.rows, timeSegments: segments.rows,
    additionalWork: additionalWork.rows, scopeVersions: scopes.rows,
    completionEvidence: evidence.rows, remainingWork: remainingWork.rows,
    disputes: disputes.rows, safetyEvents: safety.rows, payment: payment.rows[0] || null,
    workerEarning: earnings.rows[0] || null,
    cancellation: cancellation.rows[0] || null,
    rating: rating.rows[0] || null,
    events: events.rows,
  };
}

function requireStatus(job, allowed) {
  if (!allowed.includes(job.status)) {
    throw new MarketplaceError(
      'This action is no longer available for the current job state.',
      409,
      'INVALID_JOB_STATE'
    );
  }
}

module.exports = {
  MarketplaceError,
  appendEvent,
  authenticateCustomer,
  customerJob,
  ensureMarketplaceSchema,
  hashToken,
  requireStatus,
  transactionSnapshot,
  workerJob,
};
