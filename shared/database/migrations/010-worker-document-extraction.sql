ALTER TABLE worker_documents
  ADD COLUMN IF NOT EXISTS extracted_fields JSONB NOT NULL DEFAULT '{}'::JSONB;
