-- Forces a deleted worker's trusted device session back through OTP before a
-- new enrollment can be started. Phone numbers are deliberately not retained.

CREATE TABLE IF NOT EXISTS worker_enrollment_resets (
  phone_hash CHAR(64) PRIMARY KEY,
  deleted_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
