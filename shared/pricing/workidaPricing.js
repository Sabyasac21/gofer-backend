'use strict';

const fs = require('fs');
const path = require('path');

const PRICE_BOOK_PATH = path.resolve(__dirname, '../../flutter_app/assets/config/workida-price-book.json');

const PRICING_MODEL_ALIASES = Object.freeze({
  per_unit: 'perUnit',
  time_based: 'hourly',
});

function canonicalPricingModel(value) {
  return PRICING_MODEL_ALIASES[value] || value;
}

class PricingError extends Error {
  constructor(message, code = 'PRICING_ERROR') {
    super(message);
    this.name = 'PricingError';
    this.code = code;
  }
}

function readPriceBook() {
  let parsed;
  try {
    parsed = JSON.parse(fs.readFileSync(PRICE_BOOK_PATH, 'utf8'));
  } catch (error) {
    throw new PricingError(`Unable to load the Workida price book: ${error.message}`, 'PRICE_BOOK_LOAD_FAILED');
  }
  validatePriceBook(parsed);
  return deepFreeze(parsed);
}

function validatePriceBook(book) {
  if (!book || book.schemaVersion !== 2 || book.currency !== 'INR') {
    throw new PricingError('Unsupported price-book schema or currency.', 'PRICE_BOOK_INVALID');
  }
  if (!book.version || !Array.isArray(book.services) || book.services.length === 0) {
    throw new PricingError('Price-book version and services are required.', 'PRICE_BOOK_INVALID');
  }
  const ids = new Set();
  for (const service of book.services) {
    if (!service.serviceId || ids.has(service.serviceId)) {
      throw new PricingError(`Duplicate or missing service ID: ${service.serviceId || 'unknown'}`, 'PRICE_BOOK_INVALID');
    }
    ids.add(service.serviceId);
    for (const field of ['customerPriceMinor', 'visitFeeMinor', 'workerBasePayoutMinor', 'workerVisitPayoutMinor', 'minimumOrderMinor']) {
      assertNonNegativeInteger(service[field] || 0, `${service.serviceId}.${field}`);
    }
    if (service.estimatedDurationMinMinutes <= 0 || service.estimatedDurationMaxMinutes < service.estimatedDurationMinMinutes) {
      throw new PricingError(`Invalid duration for ${service.serviceId}.`, 'PRICE_BOOK_INVALID');
    }
    const pricingModel = canonicalPricingModel(service.pricingModel);
    const inspection = ['inspection', 'quote'].includes(pricingModel);
    if (inspection && (service.customerPriceMinor !== 0 || service.visitFeeMinor <= 0)) {
      throw new PricingError(`${service.serviceId} must store an inspection charge only as visitFeeMinor.`, 'PRICE_BOOK_DOUBLE_CHARGE');
    }
    if (!inspection && service.customerPriceMinor <= 0) {
      throw new PricingError(`Missing customer price for ${service.serviceId}.`, 'PRICE_BOOK_INVALID');
    }
    if (!service.cityAdjustments?.[book.defaultCity]) {
      throw new PricingError(`Missing default-city adjustment for ${service.serviceId}.`, 'PRICE_BOOK_INVALID');
    }
    const variants = new Set();
    for (const variant of service.variants || []) {
      if (!variant.variantId || variants.has(variant.variantId)) {
        throw new PricingError(`Invalid variant in ${service.serviceId}.`, 'PRICE_BOOK_INVALID');
      }
      variants.add(variant.variantId);
      assertNonNegativeInteger(variant.customerPriceMinor, `${service.serviceId}.${variant.variantId}.customerPriceMinor`);
      assertNonNegativeInteger(variant.workerPayoutMinor, `${service.serviceId}.${variant.variantId}.workerPayoutMinor`);
    }
  }
  return true;
}

const PRICE_BOOK = readPriceBook();
const VERSION = PRICE_BOOK.version;
const SERVICE_INDEX = new Map(PRICE_BOOK.services.map((service) => [
  service.serviceId,
  { ...service, pricingModel: canonicalPricingModel(service.pricingModel) },
]));

function money(minorUnits, currency = 'INR') {
  assertInteger(minorUnits, 'minorUnits');
  return { minorUnits, currency };
}

function publicService(service) {
  const pricingModel = canonicalPricingModel(service.pricingModel);
  return {
    serviceId: service.serviceId,
    serviceName: service.serviceName,
    pricingModel,
    unit: service.unit,
    basePriceMinor: service.basePriceMinor ?? service.customerPriceMinor,
    includedDurationMinutes: service.includedDurationMinutes
      ?? (pricingModel === 'hourly' ? 30 : 0),
    hourlyRateMinor: service.hourlyRateMinor
      ?? (pricingModel === 'hourly' ? service.customerPriceMinor : 0),
    billingIncrementMinutes: service.billingIncrementMinutes ?? 15,
    displayPriceMinor: service.displayPriceMinor,
    visitFeeMinor: service.visitFeeMinor,
    minimumOrderMinor: service.minimumOrderMinor,
    estimatedDurationMinMinutes: service.estimatedDurationMinMinutes,
    estimatedDurationMaxMinutes: service.estimatedDurationMaxMinutes,
    inspectionFeeAbsorbed: service.inspectionFeeAbsorbed,
    absorptionThresholdMinor: service.absorptionThresholdMinor,
    includedScope: service.includedScope,
    exclusions: service.exclusions,
    customerProvidedMaterials: service.customerProvidedMaterials,
    variants: service.variants,
    addOns: service.addOns,
    catalog: service.catalog,
    active: service.active !== false,
  };
}

function getPublicPriceBook() {
  return {
    schemaVersion: PRICE_BOOK.schemaVersion,
    version: PRICE_BOOK.version,
    currency: PRICE_BOOK.currency,
    effectiveFrom: PRICE_BOOK.effectiveFrom,
    taxInclusive: PRICE_BOOK.taxInclusive,
    defaultCity: PRICE_BOOK.defaultCity,
    supportedCities: PRICE_BOOK.supportedCities,
    services: PRICE_BOOK.services.map(publicService),
  };
}

function getBaseServices() {
  return PRICE_BOOK.services.map((service) => ({
    ...service,
    pricingModel: canonicalPricingModel(service.pricingModel),
  }));
}

function buildPricingConfig({ serviceId, serviceType, capabilityKey, category, variantId, city = PRICE_BOOK.defaultCity, quantity = 1 }, serviceOverride = null) {
  if (!serviceId) throw new PricingError('A service ID is required for pricing.', 'PRICING_CONFIG_MISSING');
  const storedService = SERVICE_INDEX.get(serviceId) || serviceOverride;
  if (!storedService) throw new PricingError(`No active price exists for ${serviceId}.`, 'PRICING_CONFIG_MISSING');
  const service = {
    ...(serviceOverride
      ? { ...storedService, ...serviceOverride, serviceId }
      : storedService),
    pricingModel: canonicalPricingModel(
      serviceOverride?.pricingModel ?? storedService.pricingModel,
    ),
  };
  if (service.active === false) {
    throw new PricingError(`Pricing is disabled for ${serviceId}.`, 'PRICING_CONFIG_INACTIVE');
  }
  if (!Number.isInteger(quantity) || quantity < 1 || quantity > 100) {
    throw new PricingError('Quantity must be between 1 and 100.', 'INVALID_QUANTITY');
  }
  const adjustment = service.cityAdjustments[city];
  if (!adjustment) throw new PricingError(`Pricing is not available in ${city}.`, 'CITY_NOT_SUPPORTED');
  const variant = serviceOverride?.disableVariants
    ? null
    : selectVariant(service, variantId);
  const customerBase = variant?.customerPriceMinor ?? service.customerPriceMinor;
  const workerBase = variant?.workerPayoutMinor ?? service.workerBasePayoutMinor;
  const inspection = ['inspection', 'quote'].includes(service.pricingModel);
  const hourly = service.pricingModel === 'hourly';
  const multiplierQuantity = hourly || inspection || service.pricingModel === 'tiered' ? 1 : quantity;
  const durationQuantity = service.pricingModel === 'perUnit' ? quantity : 1;
  const durationMin = (variant?.durationMinMinutes
    ?? service.estimatedDurationMinMinutes) * durationQuantity;
  const durationMax = (variant?.durationMaxMinutes
    ?? service.estimatedDurationMaxMinutes) * durationQuantity;
  const configuredBase = hourly
    ? (service.basePriceMinor ?? customerBase)
    : customerBase * multiplierQuantity;
  const configuredWorkerBase = hourly
    ? (service.workerBasePayoutMinor ?? workerBase)
    : workerBase * multiplierQuantity;
  const customerLabour = applyAdjustment(configuredBase, adjustment.customerMultiplier);
  const customerVisit = applyAdjustment(service.visitFeeMinor, adjustment.customerMultiplier);
  const minimumOrder = applyAdjustment(service.minimumOrderMinor, adjustment.customerMultiplier);
  const workerLabour = applyAdjustment(configuredWorkerBase, adjustment.workerMultiplier);
  const workerVisit = applyAdjustment(service.workerVisitPayoutMinor, adjustment.workerMultiplier);
  const overtimeCustomer = hourly
    ? applyAdjustment(service.hourlyRateMinor ?? customerBase, adjustment.customerMultiplier)
    : 0;
  const overtimeWorker = hourly
    ? applyAdjustment(service.workerHourlyRateMinor
      ?? service.workerOvertimeRateMinor
      ?? workerBase, adjustment.workerMultiplier)
    : 0;
  const includedDurationMinutes = hourly
    ? (service.includedDurationMinutes ?? 60)
    : 0;
  const billingIncrementMinutes = hourly
    ? (service.billingIncrementMinutes ?? 15)
    : 1;
  const profession = professionFor({ serviceType, capabilityKey, category, serviceId });

  return Object.freeze({
    version: service.pricingVersion || VERSION,
    schemaVersion: PRICE_BOOK.schemaVersion,
    serviceId,
    variantId: variant?.variantId || service.variantId,
    pricingModel: service.pricingModel,
    unit: service.unit,
    quantity,
    city,
    workerType: serviceType || (profession === 'General Helper' ? 'helper' : 'professional'),
    profession,
    skillLevel: 'standard',
    customerHourlyRateMinor: hourly ? overtimeCustomer : 0,
    workerHourlyRateMinor: hourly ? overtimeWorker : 0,
    customerBasePriceMinor: hourly ? customerLabour : 0,
    workerBasePayoutMinor: hourly ? workerLabour : 0,
    includedDurationMinutes,
    billingIncrementMinutes,
    customerVisitFeeMinor: customerVisit,
    workerVisitPayoutMinor: workerVisit,
    minimumCustomerLabourMinor: inspection ? 0 : Math.max(customerLabour, minimumOrder),
    minimumWorkerLabourMinor: inspection ? 0 : workerLabour,
    estimatedDurationMinMinutes: durationMin,
    estimatedDurationMaxMinutes: durationMax,
    overtimeEnabled: hourly,
    overtimeCustomerRateMinor: overtimeCustomer,
    overtimeWorkerRateMinor: overtimeWorker,
    inspectionFeeAbsorbed: service.inspectionFeeAbsorbed,
    absorptionThresholdMinor: service.absorptionThresholdMinor,
    includedScope: service.includedScope,
    exclusions: service.exclusions,
    customerProvidedMaterials: service.customerProvidedMaterials,
    currency: PRICE_BOOK.currency,
    taxInclusive: PRICE_BOOK.taxInclusive,
    active: true,
  });
}

function calculateEstimate(config, estimatedMinutes) {
  validateConfig(config);
  validateEstimatedMinutes(config, estimatedMinutes);
  const pricingModel = config.pricingModel || 'hourly';
  const labour = pricingModel === 'hourly'
    ? hourlyAmount(config, estimatedMinutes, 'customer')
    : config.minimumCustomerLabourMinor;
  const workerLabour = pricingModel === 'hourly'
    ? hourlyAmount(config, estimatedMinutes, 'worker')
    : config.minimumWorkerLabourMinor;
  return {
    estimatedMinutes,
    visitFeeMinor: config.customerVisitFeeMinor,
    labourRateMinor: config.customerHourlyRateMinor,
    basePriceMinor: config.customerBasePriceMinor ?? config.minimumCustomerLabourMinor,
    includedDurationMinutes: config.includedDurationMinutes ?? 0,
    billingIncrementMinutes: config.billingIncrementMinutes ?? 1,
    labourAmountMinor: labour,
    estimatedTotalMinor: config.customerVisitFeeMinor + labour,
    workerPayoutMinor: config.workerVisitPayoutMinor + workerLabour,
    pricingModel,
    version: config.version,
    currency: config.currency,
  };
}

function calculateFinal(config, { estimatedMinutes, verifiedActualMinutes, approvedOvertimeMinutes = 0, visitFeePaid = false }) {
  validateConfig(config);
  validateEstimatedMinutes(config, estimatedMinutes);
  assertNonNegativeInteger(verifiedActualMinutes, 'verifiedActualMinutes');
  assertNonNegativeInteger(approvedOvertimeMinutes, 'approvedOvertimeMinutes');
  const hourly = (config.pricingModel || 'hourly') === 'hourly';
  const baseMinutes = hourly ? Math.min(verifiedActualMinutes, estimatedMinutes) : estimatedMinutes;
  const actualExtra = Math.max(verifiedActualMinutes - estimatedMinutes, 0);
  const overtimeMinutes = config.overtimeEnabled ? Math.min(actualExtra, approvedOvertimeMinutes) : 0;
  const totalApprovedMinutes = baseMinutes + overtimeMinutes;
  const customerLabour = hourly
    ? hourlyAmount(config, totalApprovedMinutes, 'customer')
    : config.minimumCustomerLabourMinor;
  const workerLabour = hourly
    ? hourlyAmount(config, totalApprovedMinutes, 'worker')
    : config.minimumWorkerLabourMinor;
  const totalCustomerAmountMinor = config.customerVisitFeeMinor + customerLabour;
  const workerPayoutMinor = config.workerVisitPayoutMinor + workerLabour;
  return {
    verifiedActualMinutes,
    baseBillableMinutes: baseMinutes,
    approvedOvertimeMinutes: overtimeMinutes,
    visitFeeMinor: config.customerVisitFeeMinor,
    customerLabourMinor: customerLabour,
    totalCustomerAmountMinor,
    customerAmountDueMinor: totalCustomerAmountMinor - (visitFeePaid ? config.customerVisitFeeMinor : 0),
    workerVisitPayoutMinor: config.workerVisitPayoutMinor,
    workerLabourMinor: workerLabour,
    workerPayoutMinor,
    platformGrossMarginMinor: totalCustomerAmountMinor - workerPayoutMinor,
    currency: config.currency,
  };
}

function calculateCancellation(config, { workerArrivalVerified, cancelledByWorker }) {
  validateConfig(config);
  if (cancelledByWorker || !workerArrivalVerified) return { customerChargeMinor: 0, workerPayoutMinor: 0, currency: config.currency };
  return { customerChargeMinor: config.customerVisitFeeMinor, workerPayoutMinor: config.workerVisitPayoutMinor, currency: config.currency };
}

function selectVariant(service, variantId) {
  const variants = service.variants || [];
  if (variants.length === 0) {
    if (variantId && variantId !== service.variantId) throw new PricingError(`Unknown variant ${variantId} for ${service.serviceId}.`, 'VARIANT_NOT_FOUND');
    return null;
  }
  const selectedId = variantId || variants[0].variantId;
  const variant = variants.find((item) => item.variantId === selectedId);
  if (!variant) throw new PricingError(`Unknown variant ${selectedId} for ${service.serviceId}.`, 'VARIANT_NOT_FOUND');
  return variant;
}

function professionFor({ serviceType, capabilityKey = '', category = '', serviceId = '' }) {
  if (serviceType === 'helper') return 'General Helper';
  const capability = String(capabilityKey || '').toLowerCase();
  const categoryName = String(category || '').toLowerCase();
  if (PLUMBING_IDS.has(serviceId) || categoryName.includes('plumb')) return 'Plumber';
  if (CARPENTRY_IDS.has(serviceId) || categoryName.includes('carpent')) return 'Carpenter';
  if (PAINTING_IDS.has(serviceId) || categoryName.includes('paint')) return 'Painter';
  if (AC_IDS.has(serviceId) || capability.includes('ac_') || capability.includes('cooler')) return 'AC Technician';
  if (ELECTRICAL_IDS.has(serviceId)) return 'Electrician';
  if (HELPER_IDS.has(serviceId)) return 'General Helper';
  return 'Appliance Technician';
}

function validateConfig(config) {
  const supportedVersion = config?.version === VERSION
    || config?.version === 'workida-in-v1'
    || String(config?.version || '').startsWith(`${VERSION}-admin-`);
  if (!config || config.currency !== 'INR' || config.active === false || !supportedVersion) {
    throw new PricingError('Pricing configuration is invalid or stale.', 'PRICING_CONFIG_INVALID');
  }
}

function hourlyAmount(config, minutes, side) {
  const baseField = side === 'customer'
    ? 'customerBasePriceMinor'
    : 'workerBasePayoutMinor';
  const hourlyField = side === 'customer'
    ? 'customerHourlyRateMinor'
    : 'workerHourlyRateMinor';
  const minimumField = side === 'customer'
    ? 'minimumCustomerLabourMinor'
    : 'minimumWorkerLabourMinor';
  if (!Number.isInteger(config.includedDurationMinutes)) {
    return Math.max(
      prorated(config[hourlyField], minutes),
      config[minimumField],
    );
  }
  if (minutes <= 0) return 0;
  const included = Math.max(config.includedDurationMinutes, 0);
  const increment = Math.max(config.billingIncrementMinutes || 1, 1);
  const extraMinutes = Math.max(minutes - included, 0);
  const roundedExtraMinutes = Math.ceil(extraMinutes / increment) * increment;
  return Math.max(
    (config[baseField] || 0) + prorated(config[hourlyField], roundedExtraMinutes),
    config[minimumField] || 0,
  );
}

function validateEstimatedMinutes(config, minutes) {
  assertInteger(minutes, 'estimatedMinutes');
  if (minutes < config.estimatedDurationMinMinutes || minutes > config.estimatedDurationMaxMinutes) {
    throw new PricingError('Selected service duration is outside the configured range.', 'INVALID_DURATION');
  }
}

function applyAdjustment(amountMinor, multiplier) {
  assertNonNegativeInteger(amountMinor, 'amountMinor');
  if (typeof multiplier !== 'number' || !Number.isFinite(multiplier) || multiplier <= 0) throw new PricingError('Invalid city multiplier.', 'PRICE_BOOK_INVALID');
  return Math.round((amountMinor * multiplier) / 100) * 100;
}

function prorated(hourlyMinor, minutes) {
  assertNonNegativeInteger(hourlyMinor, 'hourlyMinor');
  assertNonNegativeInteger(minutes, 'minutes');
  return Math.floor(((hourlyMinor * minutes) + 30) / 60);
}

function assertInteger(value, name) {
  if (!Number.isSafeInteger(value)) throw new PricingError(`${name} must be a safe integer.`, 'INVALID_MONEY');
}

function assertNonNegativeInteger(value, name) {
  assertInteger(value, name);
  if (value < 0) throw new PricingError(`${name} cannot be negative.`, 'INVALID_MONEY');
}

function deepFreeze(value) {
  if (!value || typeof value !== 'object' || Object.isFrozen(value)) return value;
  Object.freeze(value);
  Object.values(value).forEach(deepFreeze);
  return value;
}

const HELPER_IDS = new Set(['whole_home_cleaning', 'kitchen_cleaning', 'bedroom_cleaning', 'sofa_cleaning', 'mattress_cleaning', 'carpet_cleaning', 'window_cleaning', 'floor_scrubbing', 'post_construction_cleaning', 'fan_cleaning', 'bathroom_cleaning', 'balcony_cleaning', 'household_help_session', 'packing_help', 'moving_assistance']);
const PLUMBING_IDS = new Set(['pipe_leakage', 'tap_mixer_replacement', 'toilet_flush_repair', 'drain_blockage', 'sink_basin_installation', 'bathroom_fittings', 'tank_pipeline_repair', 'water_pump_plumbing']);
const CARPENTRY_IDS = new Set(['furniture_repair', 'door_repair', 'wardrobe_cabinet_repair', 'bed_frame_repair', 'shelf_installation', 'furniture_assembly', 'modular_kitchen_carpentry', 'lock_handle_installation']);
const PAINTING_IDS = new Set(['room_painting', 'full_home_painting', 'ceiling_painting', 'exterior_wall_painting', 'wall_touch_up', 'surface_preparation', 'texture_accent_wall', 'doors_grills_painting']);
const AC_IDS = new Set(['ac_diagnosis', 'ac_service_cleaning', 'ac_installation', 'ac_gas_cooling_issue', 'cooler_repair']);
const ELECTRICAL_IDS = new Set(['switch_socket_wiring_repair', 'mcb_fuse_repair', 'doorbell_repair', 'voltage_power_issues', 'fan_installation_repair', 'lighting_installation', 'decorative_light_installation', 'fan_regulator_capacitor', 'outdoor_sensor_light']);

module.exports = { PRICE_BOOK_PATH, PricingError, VERSION, buildPricingConfig, calculateCancellation, calculateEstimate, calculateFinal, canonicalPricingModel, getBaseServices, getPublicPriceBook, money, prorated, publicService, validatePriceBook };
