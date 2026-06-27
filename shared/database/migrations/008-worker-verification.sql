-- 008-worker-verification.sql
-- Consent, durable document metadata, and KYC simulation/provider status.

ALTER TABLE worker_enrollments
  ADD COLUMN IF NOT EXISTS worker_status VARCHAR(40) NOT NULL DEFAULT 'kyc_pending',
  ADD COLUMN IF NOT EXISTS consent_version VARCHAR(40),
  ADD COLUMN IF NOT EXISTS consent_accepted_at TIMESTAMP,
  ADD COLUMN IF NOT EXISTS kyc_provider VARCHAR(80) NOT NULL DEFAULT 'mock_hyperverge',
  ADD COLUMN IF NOT EXISTS kyc_status VARCHAR(40) NOT NULL DEFAULT 'not_started',
  ADD COLUMN IF NOT EXISTS kyc_reference_id VARCHAR(120),
  ADD COLUMN IF NOT EXISTS kyc_completed_at TIMESTAMP;

CREATE TABLE IF NOT EXISTS worker_consents (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  worker_enrollment_id UUID NOT NULL REFERENCES worker_enrollments(id) ON DELETE CASCADE,
  phone VARCHAR(15) NOT NULL,
  consent_version VARCHAR(40) NOT NULL,
  consent_text TEXT NOT NULL,
  accepted BOOLEAN NOT NULL DEFAULT false,
  accepted_at TIMESTAMP NOT NULL DEFAULT NOW(),
  ip_address VARCHAR(80),
  user_agent TEXT,
  created_at TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_worker_consents_enrollment_id
  ON worker_consents(worker_enrollment_id);

CREATE TABLE IF NOT EXISTS worker_documents (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  worker_enrollment_id UUID NOT NULL REFERENCES worker_enrollments(id) ON DELETE CASCADE,
  phone VARCHAR(15) NOT NULL,
  document_type VARCHAR(80) NOT NULL,
  id_type VARCHAR(80),
  storage_provider VARCHAR(40) NOT NULL DEFAULT 'local_mock',
  storage_key TEXT NOT NULL,
  file_name VARCHAR(255),
  content_type VARCHAR(120),
  file_size_bytes INT,
  validation_checks JSONB NOT NULL DEFAULT '[]'::JSONB,
  uploaded_at TIMESTAMP NOT NULL DEFAULT NOW(),
  created_at TIMESTAMP NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMP NOT NULL DEFAULT NOW(),
  UNIQUE(worker_enrollment_id, document_type)
);

CREATE INDEX IF NOT EXISTS idx_worker_documents_enrollment_id
  ON worker_documents(worker_enrollment_id);

CREATE INDEX IF NOT EXISTS idx_worker_documents_phone
  ON worker_documents(phone);

CREATE TABLE IF NOT EXISTS kyc_verifications (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  worker_enrollment_id UUID NOT NULL REFERENCES worker_enrollments(id) ON DELETE CASCADE,
  provider VARCHAR(80) NOT NULL DEFAULT 'mock_hyperverge',
  provider_reference_id VARCHAR(120),
  status VARCHAR(40) NOT NULL DEFAULT 'not_started',
  document_status VARCHAR(40) NOT NULL DEFAULT 'pending',
  face_match_status VARCHAR(40) NOT NULL DEFAULT 'pending',
  liveness_status VARCHAR(40) NOT NULL DEFAULT 'pending',
  background_status VARCHAR(40) NOT NULL DEFAULT 'pending',
  face_match_score DECIMAL(5,2),
  decision_reason TEXT,
  raw_result JSONB NOT NULL DEFAULT '{}'::JSONB,
  processed_by VARCHAR(120),
  processed_at TIMESTAMP,
  created_at TIMESTAMP NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_kyc_verifications_enrollment_id
  ON kyc_verifications(worker_enrollment_id);

CREATE INDEX IF NOT EXISTS idx_kyc_verifications_status
  ON kyc_verifications(status);

CREATE TABLE IF NOT EXISTS admin_audit_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  admin_id VARCHAR(120) NOT NULL,
  action VARCHAR(120) NOT NULL,
  worker_enrollment_id UUID REFERENCES worker_enrollments(id) ON DELETE SET NULL,
  details JSONB NOT NULL DEFAULT '{}'::JSONB,
  created_at TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_admin_audit_logs_worker_enrollment_id
  ON admin_audit_logs(worker_enrollment_id);
