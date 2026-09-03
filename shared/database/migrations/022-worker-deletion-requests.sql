-- 022-worker-deletion-requests.sql
-- Backs the public "request account deletion" form on the Workida Worker website
-- (Google Play data-deletion requirement) for people who cannot open the app.
-- The endpoint is unauthenticated, so it only records the request; an admin
-- actions it via DELETE /api/admin/workers/:id.

CREATE TABLE IF NOT EXISTS worker_deletion_requests (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  phone VARCHAR(10) NOT NULL,
  reason TEXT,
  status VARCHAR(20) NOT NULL DEFAULT 'pending',
  source VARCHAR(20) NOT NULL DEFAULT 'web',
  requested_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  resolved_at TIMESTAMPTZ,
  resolved_by VARCHAR(120)
);

CREATE INDEX IF NOT EXISTS worker_deletion_requests_status_idx
  ON worker_deletion_requests(status, requested_at DESC);
