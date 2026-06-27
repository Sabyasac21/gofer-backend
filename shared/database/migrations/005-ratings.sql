-- 005-ratings-table.sql
CREATE TABLE ratings (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  task_id UUID NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
  rated_by UUID NOT NULL REFERENCES users(id),
  rated_entity_id UUID NOT NULL,
  rated_entity_type VARCHAR(50) NOT NULL,
  rating INT NOT NULL CHECK (rating >= 1 AND rating <= 5),
  review TEXT,
  created_at TIMESTAMP DEFAULT NOW()
);

CREATE INDEX idx_ratings_task_id ON ratings(task_id);
CREATE INDEX idx_ratings_rated_by ON ratings(rated_by);
CREATE INDEX idx_ratings_rated_entity ON ratings(rated_entity_id, rated_entity_type);
