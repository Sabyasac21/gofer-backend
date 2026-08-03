ALTER TABLE worker_documents
  ADD COLUMN IF NOT EXISTS document_number_encrypted TEXT,
  ADD COLUMN IF NOT EXISTS document_number_last4 VARCHAR(4);
