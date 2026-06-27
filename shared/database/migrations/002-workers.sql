-- 002-workers-table.sql
CREATE TABLE workers (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID UNIQUE NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  aadhaar_encrypted VARCHAR(255) NOT NULL,
  aadhaar_hash VARCHAR(255) UNIQUE NOT NULL,
  face_match_score DECIMAL(4,3),
  verification_tier VARCHAR(50) DEFAULT 'basic',
  is_online BOOLEAN DEFAULT false,
  current_lat DECIMAL(10,8),
  current_lng DECIMAL(11,8),
  service_radius_km INT DEFAULT 2,
  avg_rating DECIMAL(3,2) DEFAULT 4.5,
  total_tasks_completed INT DEFAULT 0,
  acceptance_rate DECIMAL(4,3) DEFAULT 1.0,
  badge_level VARCHAR(50) DEFAULT 'starter',
  bank_account_id VARCHAR(100),
  upi_id VARCHAR(100),
  is_suspended BOOLEAN DEFAULT false,
  suspension_reason TEXT,
  last_location_update TIMESTAMP,
  created_at TIMESTAMP DEFAULT NOW(),
  updated_at TIMESTAMP DEFAULT NOW()
);

CREATE INDEX idx_workers_user_id ON workers(user_id);
CREATE INDEX idx_workers_is_online ON workers(is_online);
CREATE INDEX idx_workers_current_location ON workers(current_lat, current_lng);
CREATE INDEX idx_workers_is_suspended ON workers(is_suspended);
