// Request validation for the admin pricing editor (PUT /api/admin/pricing/services/:serviceId).
//
// The admin only ever publishes two billing shapes - "Time based" (hourly) and
// "Fixed price" (fixed / inspection / quote / perUnit / tiered). Older catalogue
// data and cached admin clients can still send the snake_case aliases
// `per_unit` and `time_based`; those are accepted here and canonicalised
// downstream by shared/pricing before validation and storage.

const Joi = require('joi');

const PRICING_MODELS = Object.freeze([
  'hourly',
  'fixed',
  'inspection',
  'quote',
  'perUnit',
  'tiered',
  'per_unit',
  'time_based',
]);

const adminPricingSchema = Joi.object({
  pricingModel: Joi.string()
    .valid(...PRICING_MODELS)
    .required(),
  basePriceMinor: Joi.number().integer().min(0).max(100000000).required(),
  includedDurationMinutes: Joi.number().integer().min(0).max(240).required(),
  hourlyRateMinor: Joi.number().integer().min(0).max(100000000).required(),
  billingIncrementMinutes: Joi.number()
    .integer()
    .valid(1, 5, 10, 15, 30, 60)
    .required(),
  visitFeeMinor: Joi.number().integer().min(0).max(100000000).required(),
  estimatedDurationMinMinutes: Joi.number().integer().min(10).max(1440).required(),
  estimatedDurationMaxMinutes: Joi.number().integer().min(10).max(1440).required(),
  active: Joi.boolean().required(),
  includedScope: Joi.array()
    .items(Joi.string().trim().min(1).max(240))
    .max(20)
    .unique((left, right) => left.toLowerCase() === right.toLowerCase())
    .required(),
  exclusions: Joi.array()
    .items(Joi.string().trim().min(1).max(240))
    .max(20)
    .unique((left, right) => left.toLowerCase() === right.toLowerCase())
    .required(),
  variants: Joi.array().items(Joi.object({
    variantId: Joi.string().trim().max(120).required(),
    name: Joi.string().trim().min(2).max(160).required(),
    customerPriceMinor: Joi.number().integer().min(1).max(100000000).required(),
    durationMinMinutes: Joi.number().integer().min(10).max(1440).required(),
    durationMaxMinutes: Joi.number().integer().min(10).max(1440).required(),
  })).max(50).required(),
});

module.exports = { adminPricingSchema, PRICING_MODELS };
