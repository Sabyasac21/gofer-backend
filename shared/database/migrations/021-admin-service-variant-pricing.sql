-- Preserve and version option-level pricing for tiered services such as
-- Window AC and Split AC installation.

ALTER TABLE service_pricing_versions
  ADD COLUMN IF NOT EXISTS variants JSONB;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'service_pricing_versions_variants_array_check'
  ) THEN
    ALTER TABLE service_pricing_versions
      ADD CONSTRAINT service_pricing_versions_variants_array_check
      CHECK (variants IS NULL OR jsonb_typeof(variants) = 'array');
  END IF;
END $$;
