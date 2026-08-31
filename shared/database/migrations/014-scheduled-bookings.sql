ALTER TABLE gofer_customer_tasks
  ADD COLUMN IF NOT EXISTS scheduled_at TIMESTAMPTZ;

ALTER TABLE worker_job_dispatches
  ADD COLUMN IF NOT EXISTS scheduled_at TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS gofer_customer_tasks_scheduled_idx
  ON gofer_customer_tasks(scheduled_at)
  WHERE scheduled_at IS NOT NULL;

CREATE INDEX IF NOT EXISTS worker_job_dispatches_scheduled_idx
  ON worker_job_dispatches(scheduled_at)
  WHERE scheduled_at IS NOT NULL;
