-- Workida centralized pricing engine. Legacy rupee columns remain intact for
-- historical reads; new exact monetary values are stored in integer paise.

ALTER TABLE IF EXISTS gofer_customer_tasks
  ADD COLUMN IF NOT EXISTS estimated_duration_minutes INTEGER;
ALTER TABLE IF EXISTS gofer_customer_tasks
  ADD COLUMN IF NOT EXISTS pricing_snapshot JSONB;

ALTER TABLE IF EXISTS worker_job_dispatches
  ADD COLUMN IF NOT EXISTS estimated_duration_minutes INTEGER;
ALTER TABLE IF EXISTS worker_job_dispatches
  ADD COLUMN IF NOT EXISTS pricing_snapshot JSONB;
ALTER TABLE IF EXISTS worker_job_dispatches
  ADD COLUMN IF NOT EXISTS arrival_verified_at TIMESTAMPTZ;

ALTER TABLE IF EXISTS marketplace_payments
  ADD COLUMN IF NOT EXISTS visit_fee_minor BIGINT;
ALTER TABLE IF EXISTS marketplace_payments
  ADD COLUMN IF NOT EXISTS customer_labour_minor BIGINT;
ALTER TABLE IF EXISTS marketplace_payments
  ADD COLUMN IF NOT EXISTS final_customer_amount_minor BIGINT;
ALTER TABLE IF EXISTS marketplace_payments
  ADD COLUMN IF NOT EXISTS customer_amount_due_minor BIGINT;
ALTER TABLE IF EXISTS marketplace_payments
  ADD COLUMN IF NOT EXISTS worker_payout_minor BIGINT;
ALTER TABLE IF EXISTS marketplace_payments
  ADD COLUMN IF NOT EXISTS worker_visit_payout_minor BIGINT;
ALTER TABLE IF EXISTS marketplace_payments
  ADD COLUMN IF NOT EXISTS worker_labour_minor BIGINT;
ALTER TABLE IF EXISTS marketplace_payments
  ADD COLUMN IF NOT EXISTS platform_margin_minor BIGINT;
ALTER TABLE IF EXISTS marketplace_payments
  ADD COLUMN IF NOT EXISTS verified_minutes INTEGER;
ALTER TABLE IF EXISTS marketplace_payments
  ADD COLUMN IF NOT EXISTS approved_overtime_minutes INTEGER;
ALTER TABLE IF EXISTS marketplace_payments
  ADD COLUMN IF NOT EXISTS visit_fee_paid BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE IF EXISTS marketplace_payments
  ADD COLUMN IF NOT EXISTS pricing_version VARCHAR(80);

ALTER TABLE IF EXISTS marketplace_ledger_entries
  ADD COLUMN IF NOT EXISTS amount_minor BIGINT;

ALTER TABLE IF EXISTS marketplace_worker_earnings
  ADD COLUMN IF NOT EXISTS visit_payout_minor BIGINT;
ALTER TABLE IF EXISTS marketplace_worker_earnings
  ADD COLUMN IF NOT EXISTS labour_payout_minor BIGINT;
ALTER TABLE IF EXISTS marketplace_worker_earnings
  ADD COLUMN IF NOT EXISTS payable_minor BIGINT;

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
