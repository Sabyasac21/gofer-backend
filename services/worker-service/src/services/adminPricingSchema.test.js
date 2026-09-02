const test = require('node:test');
const assert = require('node:assert/strict');

const { adminPricingSchema, PRICING_MODELS } = require('./adminPricingSchema');

function validPricing(overrides = {}) {
  return {
    pricingModel: 'hourly',
    basePriceMinor: 34900,
    includedDurationMinutes: 30,
    hourlyRateMinor: 50000,
    billingIncrementMinutes: 15,
    visitFeeMinor: 0,
    estimatedDurationMinMinutes: 30,
    estimatedDurationMaxMinutes: 180,
    active: true,
    includedScope: ['Standard labour for the confirmed task'],
    exclusions: ['Spare parts and consumables'],
    variants: [],
    ...overrides,
  };
}

test('accepts every billing model the admin editor can publish', () => {
  for (const pricingModel of ['hourly', 'fixed', 'inspection', 'quote', 'perUnit', 'tiered']) {
    const { error } = adminPricingSchema.validate(validPricing({ pricingModel }));
    assert.equal(error, undefined, `expected ${pricingModel} to be accepted`);
  }
});

test('accepts the legacy snake_case aliases from cached clients and old catalogue rows', () => {
  for (const pricingModel of ['per_unit', 'time_based']) {
    const { error } = adminPricingSchema.validate(validPricing({ pricingModel }));
    assert.equal(error, undefined, `expected ${pricingModel} alias to be accepted`);
  }
  assert.ok(PRICING_MODELS.includes('per_unit'));
  assert.ok(PRICING_MODELS.includes('time_based'));
});

test('rejects an unknown billing model', () => {
  const { error } = adminPricingSchema.validate(validPricing({ pricingModel: 'auction' }));
  assert.ok(error);
  assert.match(error.message, /pricingModel/);
});

test('rejects a billing increment outside the published steps', () => {
  const { error } = adminPricingSchema.validate(
    validPricing({ billingIncrementMinutes: 7 }),
  );
  assert.ok(error);
  assert.match(error.message, /billingIncrementMinutes/);
});

test('rejects duplicate client guidance lines irrespective of case', () => {
  const { error } = adminPricingSchema.validate(
    validPricing({
      includedScope: ['Standard labour', 'standard labour'],
    }),
  );
  assert.ok(error);
  assert.match(error.message, /includedScope/);
});

test('accepts a tiered service that carries customer options', () => {
  const { error } = adminPricingSchema.validate(
    validPricing({
      pricingModel: 'tiered',
      variants: [
        {
          variantId: 'window_ac',
          name: 'Window AC',
          customerPriceMinor: 49900,
          durationMinMinutes: 45,
          durationMaxMinutes: 90,
        },
      ],
    }),
  );
  assert.equal(error, undefined);
});

test('reports every problem at once instead of stopping at the first', () => {
  const { error } = adminPricingSchema.validate(
    { pricingModel: 'fixed', basePriceMinor: 34900 },
    { abortEarly: false },
  );
  assert.ok(error);
  assert.ok(error.details.length > 1);
});
