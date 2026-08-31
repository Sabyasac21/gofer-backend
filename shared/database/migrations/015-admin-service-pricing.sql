-- Versioned, admin-managed service pricing. Existing booking pricing_snapshot
-- values remain immutable and continue to be used for settlement.

CREATE TABLE IF NOT EXISTS service_pricing_versions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  service_id VARCHAR(120) NOT NULL,
  revision INTEGER NOT NULL,
  pricing_version VARCHAR(180) NOT NULL UNIQUE,
  pricing_model VARCHAR(24) NOT NULL,
  base_price_minor INTEGER NOT NULL DEFAULT 0,
  included_duration_minutes INTEGER NOT NULL DEFAULT 0,
  hourly_rate_minor INTEGER NOT NULL DEFAULT 0,
  billing_increment_minutes INTEGER NOT NULL DEFAULT 15,
  visit_fee_minor INTEGER NOT NULL DEFAULT 0,
  worker_base_payout_minor INTEGER NOT NULL DEFAULT 0,
  worker_hourly_rate_minor INTEGER NOT NULL DEFAULT 0,
  worker_visit_payout_minor INTEGER NOT NULL DEFAULT 0,
  estimated_duration_min_minutes INTEGER NOT NULL,
  estimated_duration_max_minutes INTEGER NOT NULL,
  active BOOLEAN NOT NULL DEFAULT TRUE,
  effective_from TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  superseded_at TIMESTAMPTZ,
  created_by VARCHAR(120) NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT service_pricing_versions_revision_unique UNIQUE(service_id, revision),
  CONSTRAINT service_pricing_versions_model_check CHECK (
    pricing_model IN ('hourly','fixed','inspection','quote','perUnit','tiered')
  ),
  CONSTRAINT service_pricing_versions_duration_check CHECK (
    estimated_duration_min_minutes > 0
    AND estimated_duration_max_minutes >= estimated_duration_min_minutes
  )
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_service_pricing_current
  ON service_pricing_versions(service_id)
  WHERE superseded_at IS NULL;

CREATE TABLE IF NOT EXISTS pricing_admin_audit_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  admin_id VARCHAR(120) NOT NULL,
  service_id VARCHAR(120) NOT NULL,
  pricing_version VARCHAR(180) NOT NULL,
  action VARCHAR(40) NOT NULL,
  before_state JSONB,
  after_state JSONB NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
