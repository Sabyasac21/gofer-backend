-- Version customer-facing service inclusions and exclusions alongside pricing.
-- Existing revisions remain valid; their null values fall back to the bundled
-- catalogue defaults.

ALTER TABLE service_pricing_versions
  ADD COLUMN IF NOT EXISTS included_scope JSONB;

ALTER TABLE service_pricing_versions
  ADD COLUMN IF NOT EXISTS exclusions JSONB;

ALTER TABLE service_pricing_versions
  DROP CONSTRAINT IF EXISTS service_pricing_versions_included_scope_check;
ALTER TABLE service_pricing_versions
  ADD CONSTRAINT service_pricing_versions_included_scope_check CHECK (
    included_scope IS NULL OR jsonb_typeof(included_scope) = 'array'
  );

ALTER TABLE service_pricing_versions
  DROP CONSTRAINT IF EXISTS service_pricing_versions_exclusions_check;
ALTER TABLE service_pricing_versions
  ADD CONSTRAINT service_pricing_versions_exclusions_check CHECK (
    exclusions IS NULL OR jsonb_typeof(exclusions) = 'array'
  );
