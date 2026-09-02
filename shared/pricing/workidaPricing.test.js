'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  VERSION,
  PricingError,
  buildPricingConfig,
  calculateCancellation,
  calculateEstimate,
  calculateFinal,
  getPublicPriceBook,
} = require('./workidaPricing');

const helper = buildPricingConfig({
  serviceId: 'household_help_session',
  serviceType: 'helper',
  category: 'Labour',
});

test('price book exposes every active client service exactly once', () => {
  const book = getPublicPriceBook();
  assert.equal(book.services.length, 68);
  assert.equal(new Set(book.services.map((item) => item.serviceId)).size, 68);
  assert.equal(book.version, VERSION);
});

test('hourly household estimate includes 30 minutes then charges the hourly rate', () => {
  assert.deepEqual(calculateEstimate(helper, 60), {
    estimatedMinutes: 60,
    visitFeeMinor: 0,
    labourRateMinor: 19900,
    basePriceMinor: 19900,
    includedDurationMinutes: 30,
    billingIncrementMinutes: 15,
    labourAmountMinor: 29850,
    estimatedTotalMinor: 29850,
    workerPayoutMinor: 21000,
    pricingModel: 'hourly',
    version: VERSION,
    currency: 'INR',
  });
});

test('three helper hours include the base period plus additional time', () => {
  const result = calculateFinal(helper, {
    estimatedMinutes: 180,
    verifiedActualMinutes: 180,
  });
  assert.equal(result.customerLabourMinor, 69650);
  assert.equal(result.workerLabourMinor, 49000);
});

test('existing v1 hourly snapshots remain billable during rollout', () => {
  const legacy = { ...helper, version: 'workida-in-v1' };
  delete legacy.pricingModel;
  delete legacy.customerBasePriceMinor;
  delete legacy.workerBasePayoutMinor;
  delete legacy.includedDurationMinutes;
  delete legacy.billingIncrementMinutes;
  const estimate = calculateEstimate(legacy, 60);
  assert.equal(estimate.estimatedTotalMinor, 19900);
  assert.equal(estimate.workerPayoutMinor, 14000);
});

test('inspection fee is charged exactly once', () => {
  const inspection = buildPricingConfig({
    serviceId: 'refrigerator_repair',
    serviceType: 'professional',
  });
  const estimate = calculateEstimate(inspection, 30);
  assert.equal(estimate.visitFeeMinor, 19900);
  assert.equal(estimate.labourAmountMinor, 0);
  assert.equal(estimate.estimatedTotalMinor, 19900);
  assert.equal(estimate.workerPayoutMinor, 14000);
});

test('fixed service remains fixed when actual work ends early', () => {
  const fixed = buildPricingConfig({
    serviceId: 'router_network_setup',
    serviceType: 'professional',
  });
  const result = calculateFinal(fixed, {
    estimatedMinutes: 30,
    verifiedActualMinutes: 10,
  });
  assert.equal(result.totalCustomerAmountMinor, 29900);
  assert.equal(result.workerPayoutMinor, 20000);
});

test('micro-service minimum order protects standalone dispatch economics', () => {
  const fan = buildPricingConfig({
    serviceId: 'fan_cleaning',
    serviceType: 'helper',
  });
  assert.equal(calculateEstimate(fan, 10).estimatedTotalMinor, 19900);
});

test('legacy per-unit services use canonical fixed quantity pricing', () => {
  const single = buildPricingConfig({
    serviceId: 'bedroom_cleaning',
    serviceType: 'helper',
  });
  const double = buildPricingConfig({
    serviceId: 'bedroom_cleaning',
    serviceType: 'helper',
    quantity: 2,
  });

  assert.equal(single.pricingModel, 'perUnit');
  assert.equal(double.minimumCustomerLabourMinor, single.minimumCustomerLabourMinor * 2);
  assert.equal(double.estimatedDurationMinMinutes, single.estimatedDurationMinMinutes * 2);
  assert.equal(double.estimatedDurationMaxMinutes, single.estimatedDurationMaxMinutes * 2);
});

test('tier variants select an exact scope and price', () => {
  const split = buildPricingConfig({
    serviceId: 'ac_installation',
    serviceType: 'professional',
    variantId: 'split',
  });
  assert.equal(split.variantId, 'split');
  assert.equal(calculateEstimate(split, 120).estimatedTotalMinor, 209900);
});

test('customer and worker city adjustments move together', () => {
  const mumbai = buildPricingConfig({
    serviceId: 'bathroom_cleaning',
    serviceType: 'helper',
    city: 'mumbai',
  });
  const estimate = calculateEstimate(mumbai, 50);
  assert.equal(estimate.estimatedTotalMinor, 48500);
  assert.equal(estimate.workerPayoutMinor, 32400);
});

test('unknown services, variants and cities fail closed', () => {
  assert.throws(
    () => buildPricingConfig({ serviceId: 'unknown', serviceType: 'helper' }),
    (error) => error instanceof PricingError && error.code === 'PRICING_CONFIG_MISSING',
  );
  assert.throws(
    () => buildPricingConfig({ serviceId: 'ac_installation', serviceType: 'professional', variantId: 'unknown' }),
    (error) => error.code === 'VARIANT_NOT_FOUND',
  );
  assert.throws(
    () => buildPricingConfig({ serviceId: 'bathroom_cleaning', serviceType: 'helper', city: 'unknown' }),
    (error) => error.code === 'CITY_NOT_SUPPORTED',
  );
});

test('unapproved overtime cannot increase either side', () => {
  const result = calculateFinal(helper, {
    estimatedMinutes: 60,
    verifiedActualMinutes: 180,
  });
  assert.equal(result.customerLabourMinor, 29850);
  assert.equal(result.workerLabourMinor, 21000);
});

test('approved overtime is capped by verified actual time', () => {
  const result = calculateFinal(helper, {
    estimatedMinutes: 60,
    verifiedActualMinutes: 75,
    approvedOvertimeMinutes: 120,
  });
  assert.equal(result.approvedOvertimeMinutes, 15);
  assert.equal(result.customerLabourMinor, 34825);
  assert.equal(result.workerLabourMinor, 24500);
});

test('admin time-based pricing includes the base period then rounds extras', () => {
  const configured = {
    ...helper,
    version: `${VERSION}-admin-household_help_session-r1`,
    customerBasePriceMinor: 9900,
    workerBasePayoutMinor: 7000,
    minimumCustomerLabourMinor: 9900,
    minimumWorkerLabourMinor: 7000,
    includedDurationMinutes: 30,
    billingIncrementMinutes: 15,
  };
  const estimate = calculateEstimate(configured, 70);
  assert.equal(estimate.labourAmountMinor, 24825);
  assert.equal(estimate.workerPayoutMinor, 17500);

  const final = calculateFinal(configured, {
    estimatedMinutes: 70,
    verifiedActualMinutes: 38,
  });
  assert.equal(final.customerLabourMinor, 14875);
  assert.equal(final.workerLabourMinor, 10500);
});

test('cancellation charges only an actual configured visit fee', () => {
  assert.deepEqual(calculateCancellation(helper, {
    workerArrivalVerified: true,
    cancelledByWorker: false,
  }), { customerChargeMinor: 0, workerPayoutMinor: 0, currency: 'INR' });
  const inspection = buildPricingConfig({
    serviceId: 'refrigerator_repair',
    serviceType: 'professional',
  });
  assert.deepEqual(calculateCancellation(inspection, {
    workerArrivalVerified: true,
    cancelledByWorker: false,
  }), { customerChargeMinor: 19900, workerPayoutMinor: 14000, currency: 'INR' });
});
