'use strict';

const {
  VERSION,
  PricingError,
  buildPricingConfig,
  canonicalPricingModel,
  getBaseServices,
  getPublicPriceBook,
  publicService,
} = require('./workidaPricing');

const PRICING_MODELS = new Set([
  'hourly',
  'fixed',
  'inspection',
  'quote',
  'perUnit',
  'tiered',
]);

function pricingPresentation(pricingModel, variants = []) {
  const model = canonicalPricingModel(pricingModel);
  if (model === 'hourly') {
    return { billingMode: 'timeBased', fixedPriceKind: 'service' };
  }
  if ((variants || []).length > 0 || model === 'tiered') {
    return { billingMode: 'fixed', fixedPriceKind: 'options' };
  }
  if (['inspection', 'quote'].includes(model)) {
    return { billingMode: 'fixed', fixedPriceKind: 'assessment' };
  }
  if (model === 'perUnit') {
    return { billingMode: 'fixed', fixedPriceKind: 'quantity' };
  }
  return { billingMode: 'fixed', fixedPriceKind: 'service' };
}

async function ensurePricingAdminSchema(pool) {
  await pool.query(`
    CREATE TABLE IF NOT EXISTS service_pricing_versions (
      id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
      service_id VARCHAR(120) NOT NULL,
      revision INTEGER NOT NULL,
      pricing_version VARCHAR(180) NOT NULL UNIQUE,
      pricing_model VARCHAR(24) NOT NULL,
      base_price_minor INTEGER NOT NULL DEFAULT 0,
      included_duration_minutes INTEGER NOT NULL DEFAULT 0,
      hourly_rate_minor INTEGER NOT NULL DEFAULT 0,
      billing_increment_minutes INTEGER NOT NULL DEFAULT 15,
      visit_fee_minor INTEGER NOT NULL DEFAULT 0,
      worker_base_payout_minor INTEGER NOT NULL DEFAULT 0,
      worker_hourly_rate_minor INTEGER NOT NULL DEFAULT 0,
      worker_visit_payout_minor INTEGER NOT NULL DEFAULT 0,
      estimated_duration_min_minutes INTEGER NOT NULL,
      estimated_duration_max_minutes INTEGER NOT NULL,
      included_scope JSONB,
      exclusions JSONB,
      active BOOLEAN NOT NULL DEFAULT TRUE,
      effective_from TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      superseded_at TIMESTAMPTZ,
      created_by VARCHAR(120) NOT NULL,
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      CONSTRAINT service_pricing_versions_revision_unique
        UNIQUE(service_id, revision),
      CONSTRAINT service_pricing_versions_model_check
        CHECK (pricing_model IN ('hourly','fixed','inspection','quote','perUnit','tiered')),
      CONSTRAINT service_pricing_versions_duration_check
        CHECK (
          estimated_duration_min_minutes > 0
          AND estimated_duration_max_minutes >= estimated_duration_min_minutes
        ),
      CONSTRAINT service_pricing_versions_amounts_check
        CHECK (
          base_price_minor >= 0
          AND included_duration_minutes >= 0
          AND hourly_rate_minor >= 0
          AND billing_increment_minutes > 0
          AND visit_fee_minor >= 0
          AND worker_base_payout_minor >= 0
          AND worker_hourly_rate_minor >= 0
          AND worker_visit_payout_minor >= 0
        )
    );
    CREATE UNIQUE INDEX IF NOT EXISTS idx_service_pricing_current
      ON service_pricing_versions(service_id)
      WHERE superseded_at IS NULL;
    CREATE INDEX IF NOT EXISTS idx_service_pricing_effective
      ON service_pricing_versions(service_id, effective_from DESC);

    ALTER TABLE service_pricing_versions
      ADD COLUMN IF NOT EXISTS included_scope JSONB;
    ALTER TABLE service_pricing_versions
      ADD COLUMN IF NOT EXISTS exclusions JSONB;
    ALTER TABLE service_pricing_versions
      ADD COLUMN IF NOT EXISTS variants JSONB;

    CREATE TABLE IF NOT EXISTS pricing_admin_audit_logs (
      id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
      admin_id VARCHAR(120) NOT NULL,
      service_id VARCHAR(120) NOT NULL,
      pricing_version VARCHAR(180) NOT NULL,
      action VARCHAR(40) NOT NULL,
      before_state JSONB,
      after_state JSONB NOT NULL,
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    );

    CREATE TABLE IF NOT EXISTS admin_catalog_services (
      service_id VARCHAR(120) PRIMARY KEY,
      definition JSONB NOT NULL,
      created_by VARCHAR(120) NOT NULL,
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    );
    CREATE TABLE IF NOT EXISTS admin_catalog_service_audit_logs (
      id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
      admin_id VARCHAR(120) NOT NULL,
      service_id VARCHAR(120) NOT NULL,
      action VARCHAR(40) NOT NULL,
      after_state JSONB NOT NULL,
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    );
  `);
}

async function dynamicBaseServices(pool) {
  const result = await pool.query(
    'SELECT definition FROM admin_catalog_services ORDER BY created_at, service_id',
  );
  return result.rows.map((row) => row.definition);
}

async function allBaseServices(pool) {
  return [...getBaseServices(), ...await dynamicBaseServices(pool)];
}

function baseAdminService(service) {
  const pricingModel = canonicalPricingModel(service.pricingModel);
  const hourly = pricingModel === 'hourly';
  const inspection = ['inspection', 'quote'].includes(pricingModel);
  const variants = service.variants || [];
  return {
    serviceId: service.serviceId,
    serviceName: service.serviceName,
    unit: service.unit,
    pricingModel,
    ...pricingPresentation(pricingModel, variants),
    basePriceMinor: inspection
      ? 0
      : (service.basePriceMinor ?? service.customerPriceMinor),
    includedDurationMinutes: service.includedDurationMinutes
      ?? (hourly ? 60 : 0),
    hourlyRateMinor: service.hourlyRateMinor
      ?? (hourly ? service.customerPriceMinor : 0),
    billingIncrementMinutes: service.billingIncrementMinutes ?? 15,
    visitFeeMinor: service.visitFeeMinor || 0,
    workerBasePayoutMinor: service.workerBasePayoutMinor || 0,
    workerHourlyRateMinor: service.workerHourlyRateMinor
      ?? service.workerOvertimeRateMinor
      ?? 0,
    workerVisitPayoutMinor: service.workerVisitPayoutMinor || 0,
    estimatedDurationMinMinutes: service.estimatedDurationMinMinutes,
    estimatedDurationMaxMinutes: service.estimatedDurationMaxMinutes,
    active: service.active !== false,
    pricingVersion: VERSION,
    revision: 0,
    customized: false,
    effectiveFrom: null,
    updatedAt: null,
    includedScope: service.includedScope || [],
    exclusions: service.exclusions || [],
    variants,
  };
}

function rowToAdminService(row) {
  if (!row) return null;
  return {
    serviceId: row.service_id,
    pricingModel: canonicalPricingModel(row.pricing_model),
    basePriceMinor: row.base_price_minor,
    includedDurationMinutes: row.included_duration_minutes,
    hourlyRateMinor: row.hourly_rate_minor,
    billingIncrementMinutes: row.billing_increment_minutes,
    visitFeeMinor: row.visit_fee_minor,
    workerBasePayoutMinor: row.worker_base_payout_minor,
    workerHourlyRateMinor: row.worker_hourly_rate_minor,
    workerVisitPayoutMinor: row.worker_visit_payout_minor,
    minimumOrderMinor: 0,
    estimatedDurationMinMinutes: row.estimated_duration_min_minutes,
    estimatedDurationMaxMinutes: row.estimated_duration_max_minutes,
    active: row.active,
    pricingVersion: row.pricing_version,
    revision: row.revision,
    customized: true,
    effectiveFrom: row.effective_from,
    updatedAt: row.created_at,
    updatedBy: row.created_by,
    ...(row.included_scope == null ? {} : { includedScope: row.included_scope }),
    ...(row.exclusions == null ? {} : { exclusions: row.exclusions }),
    ...(row.variants == null ? {} : { variants: row.variants }),
  };
}

async function currentRows(pool, serviceId = null) {
  const values = [];
  const filter = serviceId ? 'AND service_id = $1' : '';
  if (serviceId) values.push(serviceId);
  const result = await pool.query(`
    SELECT *
    FROM service_pricing_versions
    WHERE superseded_at IS NULL
      AND effective_from <= NOW()
      ${filter}
    ORDER BY service_id
  `, values);
  return result.rows;
}

async function listAdminPricingServices(pool) {
  const overrides = new Map(
    (await currentRows(pool)).map((row) => [row.service_id, rowToAdminService(row)]),
  );
  const dynamicIds = new Set((await dynamicBaseServices(pool)).map((service) => service.serviceId));
  return (await allBaseServices(pool)).map((service) => {
    const override = overrides.get(service.serviceId);
    const variants = override?.variants ?? service.variants ?? [];
    const pricingModel = variants.length > 0
      ? 'tiered'
      : canonicalPricingModel(override?.pricingModel ?? service.pricingModel);
    return {
      ...baseAdminService(service),
      ...(override || {}),
      serviceName: service.serviceName,
      unit: service.unit,
      includedScope: override?.includedScope ?? service.includedScope ?? [],
      exclusions: override?.exclusions ?? service.exclusions ?? [],
      variants,
      pricingModel,
      ...pricingPresentation(pricingModel, variants),
      catalog: service.catalog,
      adminCreated: dynamicIds.has(service.serviceId),
    };
  });
}

async function getEffectiveServiceOverride(pool, serviceId) {
  const [row] = await currentRows(pool, serviceId);
  if (!row) return null;
  // Also normalize legacy revisions saved before model-specific fields were
  // cleared. This makes an already-published fixed price authoritative at
  // once; publishing again persists the cleaned record as a new revision.
  const normalized = normalizeAdminPricing({
    pricingModel: row.pricing_model,
    basePriceMinor: row.base_price_minor,
    includedDurationMinutes: row.included_duration_minutes,
    hourlyRateMinor: row.hourly_rate_minor,
    billingIncrementMinutes: row.billing_increment_minutes,
    visitFeeMinor: row.visit_fee_minor,
    workerBasePayoutMinor: row.worker_base_payout_minor,
    workerHourlyRateMinor: row.worker_hourly_rate_minor,
    workerVisitPayoutMinor: row.worker_visit_payout_minor,
    estimatedDurationMinMinutes: row.estimated_duration_min_minutes,
    estimatedDurationMaxMinutes: row.estimated_duration_max_minutes,
    active: row.active,
    ...(row.variants == null ? {} : { variants: row.variants }),
  });
  const result = {
    ...normalized,
    customerPriceMinor: normalized.basePriceMinor,
    workerOvertimeRateMinor: normalized.workerHourlyRateMinor,
    pricingVersion: row.pricing_version,
    disableVariants: false,
    ...(row.included_scope == null ? {} : { includedScope: row.included_scope }),
    ...(row.exclusions == null ? {} : { exclusions: row.exclusions }),
  };
  if (row.variants == null) delete result.variants;
  return result;
}

async function buildEffectivePricingConfig(pool, input) {
  const dynamic = (await dynamicBaseServices(pool))
    .find((service) => service.serviceId === input.serviceId);
  const override = await getEffectiveServiceOverride(pool, input.serviceId);
  const base = dynamic || getBaseServices()
    .find((service) => service.serviceId === input.serviceId);
  const effectiveOverride = override && (base?.variants || []).length > 0
    ? { ...override, pricingModel: 'tiered', disableVariants: false }
    : override;
  return buildPricingConfig(
    input,
    dynamic ? { ...dynamic, ...(effectiveOverride || {}) } : effectiveOverride,
  );
}

async function getEffectivePublicPriceBook(pool) {
  const book = getPublicPriceBook();
  const overrides = new Map(
    (await currentRows(pool)).map((row) => [row.service_id, rowToAdminService(row)]),
  );
  const dynamic = (await dynamicBaseServices(pool)).map(publicService);
  const baseServices = [...book.services, ...dynamic];
  return {
    ...book,
    services: baseServices.map((service) => {
      const override = overrides.get(service.serviceId);
      if (!override) return service;
      const variants = override.variants ?? service.variants ?? [];
      return {
        ...service,
        ...override,
        includedScope: override.includedScope ?? service.includedScope ?? [],
        exclusions: override.exclusions ?? service.exclusions ?? [],
        variants,
        pricingModel: variants.length > 0 ? 'tiered' : override.pricingModel,
      };
    }),
  };
}

function validateAdminPricing(value, serviceId, baseServices = getBaseServices()) {
  const base = baseServices.find((service) => service.serviceId === serviceId);
  if (!base) throw new PricingError('Unknown service.', 'PRICING_CONFIG_MISSING');
  if (!PRICING_MODELS.has(value.pricingModel)) {
    throw new PricingError('Unsupported pricing model.', 'PRICING_ADMIN_INVALID');
  }
  validateScopeLines(value.includedScope, 'Included scope');
  validateScopeLines(value.exclusions, 'Exclusions');
  validateVariants(value, base);
  const amountFields = [
    'basePriceMinor',
    'hourlyRateMinor',
    'visitFeeMinor',
    'workerBasePayoutMinor',
    'workerHourlyRateMinor',
    'workerVisitPayoutMinor',
  ];
  for (const field of amountFields) {
    if (!Number.isSafeInteger(value[field]) || value[field] < 0) {
      throw new PricingError(`${field} must be a non-negative integer amount.`, 'PRICING_ADMIN_INVALID');
    }
  }
  const payoutPairs = [
    ['base price', value.basePriceMinor, value.workerBasePayoutMinor],
    ['hourly rate', value.hourlyRateMinor, value.workerHourlyRateMinor],
    ['visit fee', value.visitFeeMinor, value.workerVisitPayoutMinor],
  ];
  if (payoutPairs.some(([, customer, worker]) => worker > customer)) {
    throw new PricingError(
      'Calculated worker payout cannot exceed the customer amount.',
      'PRICING_ADMIN_INVALID',
    );
  }
  if (!Number.isInteger(value.includedDurationMinutes)
      || value.includedDurationMinutes < 0
      || value.includedDurationMinutes > 240) {
    throw new PricingError('Included duration must be between 0 and 240 minutes.', 'PRICING_ADMIN_INVALID');
  }
  if (![1, 5, 10, 15, 30, 60].includes(value.billingIncrementMinutes)) {
    throw new PricingError('Unsupported billing increment.', 'PRICING_ADMIN_INVALID');
  }
  if (!Number.isInteger(value.estimatedDurationMinMinutes)
      || !Number.isInteger(value.estimatedDurationMaxMinutes)
      || value.estimatedDurationMinMinutes < 10
      || value.estimatedDurationMaxMinutes > 1440
      || value.estimatedDurationMaxMinutes < value.estimatedDurationMinMinutes) {
    throw new PricingError('Invalid service duration range.', 'PRICING_ADMIN_INVALID');
  }
  if (value.pricingModel === 'hourly') {
    if (value.basePriceMinor <= 0 || value.hourlyRateMinor <= 0
        || value.includedDurationMinutes !== 30
        || value.estimatedDurationMinMinutes < 30) {
      throw new PricingError(
        'Time-based services require a base price covering 30 minutes and an hourly rate.',
        'PRICING_ADMIN_INVALID',
      );
    }
  }
  if (['inspection', 'quote'].includes(value.pricingModel)
      && value.visitFeeMinor <= 0) {
    throw new PricingError(
      'Inspection and quotation services require a visit fee.',
      'PRICING_ADMIN_INVALID',
    );
  }
  if (!['hourly', 'inspection', 'quote'].includes(value.pricingModel)
      && value.basePriceMinor <= 0) {
    throw new PricingError('Fixed services require a base price.', 'PRICING_ADMIN_INVALID');
  }
  return base;
}

function workerPayoutPolicyBps(customerMinor, workerMinor) {
  if (!Number.isSafeInteger(customerMinor) || customerMinor <= 0
      || !Number.isSafeInteger(workerMinor) || workerMinor < 0) {
    return null;
  }
  return Math.min(10000, Math.max(0, Math.round(
    workerMinor * 10000 / customerMinor,
  )));
}

function payoutFromPolicy(customerMinor, preferredBps, fallbackBps) {
  if (!Number.isSafeInteger(customerMinor) || customerMinor <= 0) return 0;
  const bps = preferredBps ?? fallbackBps;
  if (!Number.isInteger(bps)) {
    throw new PricingError(
      'Worker payout policy is missing for this service.',
      'WORKER_PAYOUT_POLICY_MISSING',
    );
  }
  const rounded = Math.round((customerMinor * bps / 10000) / 100) * 100;
  return Math.min(customerMinor, Math.max(100, rounded));
}

function applyWorkerPayoutPolicy(value, base) {
  const referencePairs = [
    [base.basePriceMinor ?? base.customerPriceMinor, base.workerBasePayoutMinor],
    [base.hourlyRateMinor ?? base.customerPriceMinor,
      base.workerHourlyRateMinor ?? base.workerOvertimeRateMinor],
    [base.visitFeeMinor, base.workerVisitPayoutMinor],
    ...(base.variants || []).map((variant) => [
      variant.customerPriceMinor,
      variant.workerPayoutMinor,
    ]),
  ];
  const fallbackBps = referencePairs
    .map(([customer, worker]) => workerPayoutPolicyBps(customer, worker))
    .find((bps) => bps != null);
  const baseBps = workerPayoutPolicyBps(
    base.basePriceMinor ?? base.customerPriceMinor,
    base.workerBasePayoutMinor,
  );
  const hourlyBps = workerPayoutPolicyBps(
    base.hourlyRateMinor ?? base.customerPriceMinor,
    base.workerHourlyRateMinor ?? base.workerOvertimeRateMinor,
  );
  const visitBps = workerPayoutPolicyBps(
    base.visitFeeMinor,
    base.workerVisitPayoutMinor,
  );
  const baseVariants = new Map(
    (base.variants || []).map((variant) => [variant.variantId, variant]),
  );
  return {
    ...value,
    workerBasePayoutMinor: payoutFromPolicy(
      value.basePriceMinor,
      baseBps,
      fallbackBps,
    ),
    workerHourlyRateMinor: payoutFromPolicy(
      value.hourlyRateMinor,
      hourlyBps,
      fallbackBps,
    ),
    workerVisitPayoutMinor: payoutFromPolicy(
      value.visitFeeMinor,
      visitBps,
      fallbackBps,
    ),
    variants: (value.variants || []).map((variant) => {
      const reference = baseVariants.get(variant.variantId);
      return {
        ...variant,
        workerPayoutMinor: payoutFromPolicy(
          variant.customerPriceMinor,
          workerPayoutPolicyBps(
            reference?.customerPriceMinor,
            reference?.workerPayoutMinor,
          ),
          fallbackBps,
        ),
      };
    }),
  };
}

function validateVariants(value, base) {
  const expected = base.variants || [];
  const variants = value.variants || [];
  if (expected.length === 0) {
    if (!Array.isArray(variants) || variants.length > 0) {
      throw new PricingError(
        'This service does not define price options.',
        'PRICING_ADMIN_INVALID',
      );
    }
    return;
  }
  if (value.pricingModel !== 'tiered') {
    throw new PricingError(
      'Services with customer options must use tiered pricing.',
      'PRICING_ADMIN_INVALID',
    );
  }
  if (!Array.isArray(variants) || variants.length !== expected.length) {
    throw new PricingError(
      'Every service option requires its own price and duration.',
      'PRICING_ADMIN_INVALID',
    );
  }
  const expectedIds = new Set(expected.map((item) => item.variantId));
  const receivedIds = new Set();
  for (const variant of variants) {
    if (!variant || !expectedIds.has(variant.variantId)
        || receivedIds.has(variant.variantId)) {
      throw new PricingError(
        'Service option IDs must match the catalogue.',
        'PRICING_ADMIN_INVALID',
      );
    }
    receivedIds.add(variant.variantId);
    if (!Number.isSafeInteger(variant.customerPriceMinor)
        || variant.customerPriceMinor <= 0
        || !Number.isSafeInteger(variant.workerPayoutMinor)
        || variant.workerPayoutMinor <= 0
        || variant.workerPayoutMinor > variant.customerPriceMinor) {
      throw new PricingError(
        'Each option requires a valid customer price and worker payout.',
        'PRICING_ADMIN_INVALID',
      );
    }
    if (!Number.isInteger(variant.durationMinMinutes)
        || !Number.isInteger(variant.durationMaxMinutes)
        || variant.durationMinMinutes < 10
        || variant.durationMaxMinutes > 1440
        || variant.durationMaxMinutes < variant.durationMinMinutes) {
      throw new PricingError(
        'Each option requires a valid duration range.',
        'PRICING_ADMIN_INVALID',
      );
    }
  }
}

function validateScopeLines(lines, label) {
  if (!Array.isArray(lines) || lines.length > 20) {
    throw new PricingError(`${label} must contain no more than 20 lines.`, 'PRICING_ADMIN_INVALID');
  }
  if (lines.some((line) => typeof line !== 'string'
      || line.trim().length === 0 || line.trim().length > 240)) {
    throw new PricingError(
      `${label} lines must contain between 1 and 240 characters.`,
      'PRICING_ADMIN_INVALID',
    );
  }
  const normalized = lines.map((line) => line.trim().toLowerCase());
  if (new Set(normalized).size !== normalized.length) {
    throw new PricingError(`${label} cannot contain duplicate lines.`, 'PRICING_ADMIN_INVALID');
  }
}

// A pricing model owns only the fields that can affect its customer total.
// Clear values left behind after a model switch (for example, an inspection
// visit fee on a now-fixed service) so the preview and the booking API cannot
// disagree about the amount payable.
function normalizeAdminPricing(value) {
  const normalized = {
    ...value,
    pricingModel: canonicalPricingModel(value.pricingModel),
  };
  normalized.variants = Array.isArray(normalized.variants)
    ? normalized.variants.map((variant) => ({
      variantId: variant.variantId,
      name: variant.name,
      customerPriceMinor: variant.customerPriceMinor,
      workerPayoutMinor: variant.workerPayoutMinor,
      durationMinMinutes: variant.durationMinMinutes,
      durationMaxMinutes: variant.durationMaxMinutes,
    }))
    : [];
  if (Array.isArray(normalized.includedScope)) {
    normalized.includedScope = normalized.includedScope.map((line) => line.trim());
  }
  if (Array.isArray(normalized.exclusions)) {
    normalized.exclusions = normalized.exclusions.map((line) => line.trim());
  }
  if (normalized.pricingModel === 'hourly') {
    normalized.visitFeeMinor = 0;
    normalized.workerVisitPayoutMinor = 0;
  } else if (['inspection', 'quote'].includes(normalized.pricingModel)) {
    normalized.basePriceMinor = 0;
    normalized.workerBasePayoutMinor = 0;
    normalized.includedDurationMinutes = 0;
    normalized.hourlyRateMinor = 0;
    normalized.workerHourlyRateMinor = 0;
    normalized.billingIncrementMinutes = 1;
  } else {
    normalized.visitFeeMinor = 0;
    normalized.workerVisitPayoutMinor = 0;
    normalized.includedDurationMinutes = 0;
    normalized.hourlyRateMinor = 0;
    normalized.workerHourlyRateMinor = 0;
    normalized.billingIncrementMinutes = 1;
  }
  return normalized;
}

async function savePricingVersion(pool, { serviceId, adminId, value }) {
  const baseServices = await allBaseServices(pool);
  const base = baseServices.find((service) => service.serviceId === serviceId);
  if (!base) {
    throw new PricingError('Unknown service.', 'PRICING_CONFIG_MISSING');
  }
  const normalizedValue = normalizeAdminPricing(
    applyWorkerPayoutPolicy(value, base),
  );
  validateAdminPricing(
    normalizedValue,
    serviceId,
    baseServices,
  );
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query(
      'SELECT pg_advisory_xact_lock(hashtext($1))',
      [`service-pricing:${serviceId}`],
    );
    const current = await client.query(`
      SELECT * FROM service_pricing_versions
      WHERE service_id = $1 AND superseded_at IS NULL
      FOR UPDATE
    `, [serviceId]);
    const revisionResult = await client.query(`
      SELECT COALESCE(MAX(revision), 0) + 1 AS revision
      FROM service_pricing_versions
      WHERE service_id = $1
    `, [serviceId]);
    const revision = Number(revisionResult.rows[0].revision);
    const pricingVersion = `${VERSION}-admin-${serviceId}-r${revision}`;
    if (current.rowCount) {
      await client.query(`
        UPDATE service_pricing_versions
        SET superseded_at = NOW()
        WHERE service_id = $1 AND superseded_at IS NULL
      `, [serviceId]);
    }
    const inserted = await client.query(`
      INSERT INTO service_pricing_versions(
        service_id, revision, pricing_version, pricing_model,
        base_price_minor, included_duration_minutes, hourly_rate_minor,
        billing_increment_minutes, visit_fee_minor,
        worker_base_payout_minor, worker_hourly_rate_minor,
        worker_visit_payout_minor, estimated_duration_min_minutes,
        estimated_duration_max_minutes, active, created_by,
        included_scope, exclusions, variants
      ) VALUES(
        $1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17::jsonb,$18::jsonb,$19::jsonb
      ) RETURNING *
    `, [
      serviceId,
      revision,
      pricingVersion,
      normalizedValue.pricingModel,
      normalizedValue.basePriceMinor,
      normalizedValue.includedDurationMinutes,
      normalizedValue.hourlyRateMinor,
      normalizedValue.billingIncrementMinutes,
      normalizedValue.visitFeeMinor,
      normalizedValue.workerBasePayoutMinor,
      normalizedValue.workerHourlyRateMinor,
      normalizedValue.workerVisitPayoutMinor,
      normalizedValue.estimatedDurationMinMinutes,
      normalizedValue.estimatedDurationMaxMinutes,
      normalizedValue.active !== false,
      adminId,
      JSON.stringify(normalizedValue.includedScope),
      JSON.stringify(normalizedValue.exclusions),
      JSON.stringify(normalizedValue.variants),
    ]);
    await client.query(`
      INSERT INTO pricing_admin_audit_logs(
        admin_id, service_id, pricing_version, action, before_state, after_state
      ) VALUES($1,$2,$3,'service_configuration_updated',$4::jsonb,$5::jsonb)
    `, [
      adminId,
      serviceId,
      pricingVersion,
      current.rows[0] ? JSON.stringify(rowToAdminService(current.rows[0])) : null,
      JSON.stringify(rowToAdminService(inserted.rows[0])),
    ]);
    await client.query('COMMIT');
    return {
      ...baseAdminService(base),
      ...rowToAdminService(inserted.rows[0]),
      serviceName: base.serviceName,
      unit: base.unit,
      ...pricingPresentation(
        inserted.rows[0].pricing_model,
        normalizedValue.variants,
      ),
    };
  } catch (error) {
    await client.query('ROLLBACK');
    throw error;
  } finally {
    client.release();
  }
}

function cloneServiceDefinition(source, { serviceId, serviceName, shortDescription }) {
  const definition = JSON.parse(JSON.stringify(source));
  definition.serviceId = serviceId;
  definition.variantId = `${serviceId}_base`;
  definition.serviceName = serviceName;
  definition.active = false;
  definition.variants = [];
  definition.catalog = {
    ...definition.catalog,
    shortDescription,
    isFeatured: false,
    badge: null,
    sortOrder: Number(definition.catalog?.sortOrder || 0) + 1,
    template: {
      ...definition.catalog?.template,
      id: `${serviceId}_template`,
      serviceId,
      name: serviceName,
      description: shortDescription,
    },
  };
  return definition;
}

async function createCatalogService(pool, {
  sourceServiceId,
  serviceId,
  serviceName,
  shortDescription,
  adminId,
}) {
  const services = await allBaseServices(pool);
  if (services.some((service) => service.serviceId === serviceId)) {
    throw new PricingError('That service ID already exists.', 'SERVICE_ID_EXISTS');
  }
  const source = services.find((service) => service.serviceId === sourceServiceId);
  if (!source) {
    throw new PricingError('Template service not found.', 'SERVICE_TEMPLATE_NOT_FOUND');
  }
  const definition = cloneServiceDefinition(source, {
    serviceId,
    serviceName,
    shortDescription,
  });
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query('SELECT pg_advisory_xact_lock(hashtext($1))', [`service-catalog:${serviceId}`]);
    const result = await client.query(
      `INSERT INTO admin_catalog_services(service_id, definition, created_by)
       VALUES($1,$2::jsonb,$3) RETURNING definition`,
      [serviceId, JSON.stringify(definition), adminId],
    );
    await client.query(
      `INSERT INTO admin_catalog_service_audit_logs(
         admin_id, service_id, action, after_state
       ) VALUES($1,$2,'service_created',$3::jsonb)`,
      [adminId, serviceId, JSON.stringify(definition)],
    );
    await client.query('COMMIT');
    return {
      ...baseAdminService(result.rows[0].definition),
      catalog: result.rows[0].definition.catalog,
      adminCreated: true,
    };
  } catch (error) {
    await client.query('ROLLBACK');
    if (error.code === '23505') {
      throw new PricingError('That service ID already exists.', 'SERVICE_ID_EXISTS');
    }
    throw error;
  } finally {
    client.release();
  }
}

module.exports = {
  allBaseServices,
  applyWorkerPayoutPolicy,
  buildEffectivePricingConfig,
  createCatalogService,
  ensurePricingAdminSchema,
  getEffectivePublicPriceBook,
  getEffectiveServiceOverride,
  listAdminPricingServices,
  normalizeAdminPricing,
  pricingPresentation,
  savePricingVersion,
  validateAdminPricing,
};
