-- Admin-created services keep a complete cloned booking definition so the
-- customer app and dispatch APIs can consume them without an app release.

CREATE TABLE IF NOT EXISTS admin_catalog_services (
  service_id VARCHAR(120) PRIMARY KEY,
  definition JSONB NOT NULL,
  created_by VARCHAR(120) NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS admin_catalog_service_audit_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  admin_id VARCHAR(120) NOT NULL,
  service_id VARCHAR(120) NOT NULL,
  action VARCHAR(40) NOT NULL,
  after_state JSONB NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
