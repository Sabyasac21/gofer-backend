-- Shared push-notification platform for customer and worker app installations.
-- Recipient tables are intentionally polymorphic because current customers and
-- workers live in gofer_customers and worker_enrollments respectively.

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE IF NOT EXISTS notification_devices (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_type VARCHAR(20) NOT NULL CHECK (owner_type IN ('customer', 'worker')),
  owner_id UUID NOT NULL,
  installation_id VARCHAR(180) NOT NULL,
  app_flavor VARCHAR(20) NOT NULL CHECK (app_flavor IN ('customer', 'worker')),
  platform VARCHAR(20) NOT NULL CHECK (platform IN ('android', 'ios')),
  fcm_token TEXT NOT NULL UNIQUE,
  app_version VARCHAR(40),
  locale VARCHAR(20),
  active BOOLEAN NOT NULL DEFAULT TRUE,
  last_seen_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  token_updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE(app_flavor, installation_id)
);

CREATE INDEX IF NOT EXISTS notification_devices_owner_idx
  ON notification_devices(owner_type, owner_id, active);
CREATE INDEX IF NOT EXISTS notification_devices_last_seen_idx
  ON notification_devices(last_seen_at);

CREATE TABLE IF NOT EXISTS notification_preferences (
  owner_type VARCHAR(20) NOT NULL CHECK (owner_type IN ('customer', 'worker')),
  owner_id UUID NOT NULL,
  booking_updates BOOLEAN NOT NULL DEFAULT TRUE,
  payments BOOLEAN NOT NULL DEFAULT TRUE,
  account_updates BOOLEAN NOT NULL DEFAULT TRUE,
  reminders BOOLEAN NOT NULL DEFAULT TRUE,
  marketing BOOLEAN NOT NULL DEFAULT FALSE,
  quiet_hours_start TIME,
  quiet_hours_end TIME,
  timezone VARCHAR(80) NOT NULL DEFAULT 'Asia/Kolkata',
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  PRIMARY KEY(owner_type, owner_id)
);

CREATE TABLE IF NOT EXISTS notifications (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_type VARCHAR(20) NOT NULL CHECK (owner_type IN ('customer', 'worker')),
  owner_id UUID NOT NULL,
  type VARCHAR(100) NOT NULL,
  category VARCHAR(30) NOT NULL CHECK (
    category IN ('booking', 'payment', 'account', 'reminder', 'marketing', 'support')
  ),
  title VARCHAR(180) NOT NULL,
  body TEXT NOT NULL,
  data JSONB NOT NULL DEFAULT '{}'::jsonb,
  deduplication_key VARCHAR(240) NOT NULL,
  is_read BOOLEAN NOT NULL DEFAULT FALSE,
  read_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  expires_at TIMESTAMPTZ,
  UNIQUE(owner_type, owner_id, deduplication_key)
);

CREATE INDEX IF NOT EXISTS notifications_inbox_idx
  ON notifications(owner_type, owner_id, created_at DESC);
CREATE INDEX IF NOT EXISTS notifications_unread_idx
  ON notifications(owner_type, owner_id, is_read, created_at DESC);

CREATE TABLE IF NOT EXISTS notification_deliveries (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  notification_id UUID NOT NULL REFERENCES notifications(id) ON DELETE CASCADE,
  device_id UUID NOT NULL REFERENCES notification_devices(id) ON DELETE CASCADE,
  status VARCHAR(30) NOT NULL DEFAULT 'pending' CHECK (
    status IN ('pending', 'processing', 'sent', 'retrying', 'failed', 'invalid_device', 'skipped')
  ),
  attempts INTEGER NOT NULL DEFAULT 0,
  provider_message_id VARCHAR(300),
  error_code VARCHAR(120),
  error_message VARCHAR(500),
  next_attempt_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  sent_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE(notification_id, device_id)
);

CREATE INDEX IF NOT EXISTS notification_deliveries_pending_idx
  ON notification_deliveries(status, next_attempt_at);

CREATE TABLE IF NOT EXISTS notification_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id VARCHAR(240) NOT NULL UNIQUE,
  event_type VARCHAR(120) NOT NULL,
  payload JSONB NOT NULL,
  status VARCHAR(30) NOT NULL DEFAULT 'received' CHECK (
    status IN ('received', 'processed', 'ignored', 'failed')
  ),
  error_message VARCHAR(500),
  received_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  processed_at TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS notification_outbox (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  event_id VARCHAR(240) NOT NULL UNIQUE,
  event_type VARCHAR(120) NOT NULL,
  payload JSONB NOT NULL,
  status VARCHAR(20) NOT NULL DEFAULT 'pending' CHECK (
    status IN ('pending', 'publishing', 'published')
  ),
  attempts INTEGER NOT NULL DEFAULT 0,
  next_attempt_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  published_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS notification_outbox_pending_idx
  ON notification_outbox(status, next_attempt_at, created_at);

CREATE TABLE IF NOT EXISTS notification_campaigns (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  title VARCHAR(180) NOT NULL,
  body TEXT NOT NULL,
  target_owner_type VARCHAR(20) NOT NULL CHECK (target_owner_type IN ('customer', 'worker')),
  category VARCHAR(30) NOT NULL DEFAULT 'marketing',
  data JSONB NOT NULL DEFAULT '{}'::jsonb,
  status VARCHAR(20) NOT NULL DEFAULT 'draft' CHECK (
    status IN ('draft', 'scheduled', 'processing', 'sent', 'cancelled')
  ),
  scheduled_at TIMESTAMPTZ,
  created_by VARCHAR(160) NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  sent_at TIMESTAMPTZ
);
