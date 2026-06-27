-- 007-worker-enrollments.sql
-- Durable worker onboarding submissions from the Gofer Worker app.
CREATE TABLE IF NOT EXISTS worker_enrollments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  phone VARCHAR(15) UNIQUE NOT NULL,
  full_name VARCHAR(120) NOT NULL,
  age INT,
  city VARCHAR(100) NOT NULL,
  work_area VARCHAR(150) NOT NULL,
  emergency_contact VARCHAR(20),
  language VARCHAR(40) NOT NULL DEFAULT 'English',
  experience VARCHAR(80) NOT NULL DEFAULT 'Beginner',
  travel_radius_km INT NOT NULL DEFAULT 3,
  enrollment_types TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[],
  professional_categories TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[],
  id_type VARCHAR(80),
  documents JSONB NOT NULL DEFAULT '{}'::JSONB,
  consent_accepted BOOLEAN NOT NULL DEFAULT false,
  review_status VARCHAR(40) NOT NULL DEFAULT 'under_review',
  submitted_at TIMESTAMP NOT NULL DEFAULT NOW(),
  created_at TIMESTAMP NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_worker_enrollments_phone
  ON worker_enrollments(phone);

CREATE INDEX IF NOT EXISTS idx_worker_enrollments_review_status
  ON worker_enrollments(review_status);

CREATE INDEX IF NOT EXISTS idx_worker_enrollments_city
  ON worker_enrollments(city);
