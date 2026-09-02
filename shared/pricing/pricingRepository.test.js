'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const { PricingError } = require('./workidaPricing');
const {
  applyWorkerPayoutPolicy,
  createCatalogService,
  displayPriceMinorFor,
  getEffectivePublicPriceBook,
  listAdminPricingServices,
  normalizeAdminPricing,
  pricingPresentation,
  validateAdminPricing,
} = require('./pricingRepository');

// Minimal service_pricing_versions row shaped like the admin editor would save.
function overrideRow(serviceId, overrides = {}) {
  return {
    service_id: serviceId,
    pricing_model: 'fixed',
    base_price_minor: 15900,
    included_duration_minutes: 0,
    hourly_rate_minor: 0,
    billing_increment_minutes: 1,
    visit_fee_minor: 0,
    worker_base_payout_minor: 10000,
    worker_hourly_rate_minor: 0,
    worker_visit_payout_minor: 0,
    estimated_duration_min_minutes: 50,
    estimated_duration_max_minutes: 90,
    active: true,
    pricing_version: 'v2',
    revision: 2,
    effective_from: new Date(0),
    created_at: new Date(0),
    created_by: 'admin-1',
    included_scope: null,
    exclusions: null,
    variants: null,
    ...overrides,
  };
}

function poolWithOverrides(rows) {
  return {
    query: async (sql) => {
      if (/admin_catalog_services/.test(sql)) return { rows: [] };
      if (/service_pricing_versions/.test(sql)) return { rows };
      return { rows: [] };
    },
  };
}

function validHourly() {
  return {
    pricingModel: 'hourly',
    basePriceMinor: 9900,
    includedDurationMinutes: 30,
    hourlyRateMinor: 19900,
    billingIncrementMinutes: 15,
    visitFeeMinor: 0,
    workerBasePayoutMinor: 7000,
    workerHourlyRateMinor: 14000,
    workerVisitPayoutMinor: 0,
    estimatedDurationMinMinutes: 30,
    estimatedDurationMaxMinutes: 240,
    active: true,
    includedScope: ['Work included in the booking'],
    exclusions: ['Materials charged separately'],
  };
}

test('admin accepts base plus hourly pricing with a 30 minute inclusion', () => {
  const service = validateAdminPricing(
    validHourly(),
    'household_help_session',
  );
  assert.equal(service.serviceId, 'household_help_session');
});

test('legacy catalogue models are normalized and presented as fixed pricing', async () => {
  const pool = { query: async () => ({ rows: [] }) };
  const services = await listAdminPricingServices(pool);
  const bedroom = services.find((service) => service.serviceId === 'bedroom_cleaning');

  assert.equal(bedroom.pricingModel, 'perUnit');
  assert.equal(bedroom.billingMode, 'fixed');
  assert.equal(bedroom.fixedPriceKind, 'quantity');
  assert.deepEqual(pricingPresentation('time_based'), {
    billingMode: 'timeBased',
    fixedPriceKind: 'service',
  });
});

test('legacy pricing names are canonicalized before validation and storage', () => {
  const normalized = normalizeAdminPricing({
    ...validHourly(),
    pricingModel: 'time_based',
  });
  assert.equal(normalized.pricingModel, 'hourly');
  assert.doesNotThrow(() => validateAdminPricing(
    normalized,
    'household_help_session',
  ));
});

test('switching to fixed pricing removes stale inspection charges', () => {
  const normalized = normalizeAdminPricing({
    pricingModel: 'fixed',
    basePriceMinor: 34900,
    workerBasePayoutMinor: 25000,
    visitFeeMinor: 29900,
    workerVisitPayoutMinor: 21000,
    includedDurationMinutes: 30,
    hourlyRateMinor: 50000,
    workerHourlyRateMinor: 30000,
    billingIncrementMinutes: 15,
  });

  assert.equal(normalized.visitFeeMinor, 0);
  assert.equal(normalized.workerVisitPayoutMinor, 0);
  assert.equal(normalized.includedDurationMinutes, 0);
  assert.equal(normalized.hourlyRateMinor, 0);
  assert.equal(normalized.billingIncrementMinutes, 1);
});

test('admin rejects time-based pricing without a base period', () => {
  assert.throws(
    () => validateAdminPricing(
      { ...validHourly(), includedDurationMinutes: 0 },
      'household_help_session',
    ),
    (error) => error instanceof PricingError
      && error.code === 'PRICING_ADMIN_INVALID',
  );
});

test('admin rejects an inspection service without a visit fee', () => {
  assert.throws(
    () => validateAdminPricing(
      {
        ...validHourly(),
        pricingModel: 'inspection',
        basePriceMinor: 0,
        includedDurationMinutes: 0,
        hourlyRateMinor: 0,
        visitFeeMinor: 0,
      },
      'refrigerator_repair',
    ),
    (error) => error instanceof PricingError
      && error.code === 'PRICING_ADMIN_INVALID',
  );
});

test('admin normalizes service scope lines before publishing', () => {
  const normalized = normalizeAdminPricing({
    ...validHourly(),
    includedScope: ['  First included item  '],
    exclusions: ['  First excluded item  '],
  });

  assert.deepEqual(normalized.includedScope, ['First included item']);
  assert.deepEqual(normalized.exclusions, ['First excluded item']);
});

test('admin rejects duplicate scope lines irrespective of case', () => {
  assert.throws(
    () => validateAdminPricing(
      {
        ...validHourly(),
        includedScope: ['Basic check', 'basic check'],
      },
      'household_help_session',
    ),
    (error) => error instanceof PricingError
      && error.code === 'PRICING_ADMIN_INVALID',
  );
});

test('tiered services require an exact price for every customer option', () => {
  const variants = [
    {
      variantId: 'window',
      name: 'Window AC installation',
      customerPriceMinor: 139900,
      workerPayoutMinor: 95000,
      durationMinMinutes: 90,
      durationMaxMinutes: 150,
    },
    {
      variantId: 'split',
      name: 'Split AC installation',
      customerPriceMinor: 229900,
      workerPayoutMinor: 155000,
      durationMinMinutes: 120,
      durationMaxMinutes: 240,
    },
  ];
  const service = validateAdminPricing(
    {
      ...validHourly(),
      pricingModel: 'tiered',
      basePriceMinor: 139900,
      workerBasePayoutMinor: 95000,
      variants,
    },
    'ac_installation',
  );
  assert.equal(service.serviceId, 'ac_installation');
  assert.throws(
    () => validateAdminPricing(
      {
        ...validHourly(),
        pricingModel: 'fixed',
        basePriceMinor: 139900,
        variants,
      },
      'ac_installation',
    ),
    (error) => error instanceof PricingError
      && error.code === 'PRICING_ADMIN_INVALID',
  );
});

test('server derives variant payouts and ignores admin-supplied payout amounts', () => {
  const base = require('./workidaPricing').getBaseServices()
    .find((service) => service.serviceId === 'ac_installation');
  const result = applyWorkerPayoutPolicy({
    pricingModel: 'tiered',
    basePriceMinor: 17900,
    hourlyRateMinor: 0,
    visitFeeMinor: 0,
    workerBasePayoutMinor: 999999,
    variants: [
      {
        variantId: 'window',
        name: 'Window AC installation',
        customerPriceMinor: 17900,
        workerPayoutMinor: 999999,
        durationMinMinutes: 90,
        durationMaxMinutes: 150,
      },
      {
        variantId: 'split',
        name: 'Split AC installation',
        customerPriceMinor: 18900,
        workerPayoutMinor: 999999,
        durationMinMinutes: 120,
        durationMaxMinutes: 240,
      },
    ],
  }, base);

  assert.equal(result.variants[0].workerPayoutMinor, 12300);
  assert.equal(result.variants[1].workerPayoutMinor, 13100);
  assert.ok(result.workerBasePayoutMinor <= result.basePriceMinor);
});

test('admin service list exposes the bundled client guidance as defaults', async () => {
  const pool = { query: async () => ({ rows: [] }) };
  const services = await listAdminPricingServices(pool);
  const cleaning = services.find((service) => service.serviceId === 'whole_home_cleaning');

  assert.ok(cleaning.includedScope.some((line) => line.includes('bathroom cleaning')));
  assert.ok(cleaning.exclusions.some((line) => line.includes('Inside cabinets')));
  assert.equal(cleaning.customized, false);
  const acInstallation = services.find(
    (service) => service.serviceId === 'ac_installation',
  );
  assert.equal(acInstallation.pricingModel, 'tiered');
  assert.deepEqual(
    acInstallation.variants.map((variant) => variant.variantId),
    ['window', 'split'],
  );
});

test('admin creates an inactive service by cloning a dispatchable template', async () => {
  const pool = {
    async query(sql, params = []) {
      if (sql.includes('SELECT definition FROM admin_catalog_services')) {
        return { rows: [] };
      }
      throw new Error(`Unexpected SQL: ${sql}`);
    },
    async connect() {
      return {
        async query(sql, params = []) {
          if (sql.includes('INSERT INTO admin_catalog_services')) {
            return { rows: [{ definition: JSON.parse(params[1]) }] };
          }
          return { rows: [], rowCount: 0 };
        },
        release() {},
      };
    },
  };

  const created = await createCatalogService(pool, {
    sourceServiceId: 'ac_installation',
    serviceId: 'premium_ac_installation',
    serviceName: 'Premium AC installation',
    shortDescription: 'Premium installation using the standard AC workflow',
    adminId: 'admin-1',
  });

  assert.equal(created.serviceId, 'premium_ac_installation');
  assert.equal(created.active, false);
  assert.equal(created.catalog.template.serviceId, 'premium_ac_installation');
  assert.ok(created.catalog.template.questions.length > 0);
  assert.ok(created.includedScope.length > 0);
});

test('displayPriceMinorFor tracks the effective price per model', () => {
  assert.equal(
    displayPriceMinorFor({ pricingModel: 'perUnit', basePriceMinor: 15900 }),
    15900,
  );
  assert.equal(
    displayPriceMinorFor({ pricingModel: 'inspection', visitFeeMinor: 24900 }),
    24900,
  );
  assert.equal(
    displayPriceMinorFor({
      pricingModel: 'tiered',
      basePriceMinor: 0,
      variants: [
        { customerPriceMinor: 49900 },
        { customerPriceMinor: 29900 },
        { customerPriceMinor: 79900 },
      ],
    }),
    29900,
  );
});

test('an admin price change is reflected in the public catalogue card price', async () => {
  const pool = poolWithOverrides([
    overrideRow('bedroom_cleaning', { pricing_model: 'perUnit', base_price_minor: 15900 }),
  ]);
  const book = await getEffectivePublicPriceBook(pool);
  const bedroom = book.services.find((service) => service.serviceId === 'bedroom_cleaning');

  assert.equal(bedroom.basePriceMinor, 15900);
  assert.equal(
    bedroom.displayPriceMinor,
    15900,
    'displayPriceMinor must follow the override, not the stale catalogue value',
  );
});

test('services without an override keep their authored display price', async () => {
  const pool = poolWithOverrides([]);
  const book = await getEffectivePublicPriceBook(pool);
  const bedroom = book.services.find((service) => service.serviceId === 'bedroom_cleaning');

  assert.equal(bedroom.displayPriceMinor, 69900);
});
