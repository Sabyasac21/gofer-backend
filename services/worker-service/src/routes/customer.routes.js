const crypto = require('crypto');
const express = require('express');
const Joi = require('joi');

const {
  PricingError,
  calculateEstimate,
} = require('../../../../shared/pricing/workidaPricing');
const {
  buildEffectivePricingConfig,
} = require('../../../../shared/pricing/pricingRepository');
const {
  SchedulingError,
  validateScheduledAt,
} = require('../../../../shared/scheduling/workidaScheduling');
const { getFirebaseAuth } = require('../services/firebaseAdmin');
const {
  HouseholdPricingError,
  quoteHouseholdSession,
} = require('../services/householdPricing');
const {
  authenticateCustomer,
  hashToken,
} = require('../services/marketplaceTransaction');

class CustomerRouteError extends Error {
  constructor(message, statusCode = 400, code = 'CUSTOMER_REQUEST_ERROR') {
    super(message);
    this.name = 'CustomerRouteError';
    this.statusCode = statusCode;
    this.code = code;
  }
}

const taskSchema = Joi.object({
  customerId: Joi.string().uuid().required(),
  category: Joi.string().trim().max(80).required(),
  title: Joi.string().trim().min(2).max(160).required(),
  description: Joi.string().trim().min(2).max(2000).required(),
  address: Joi.string().trim().min(2).max(500).required(),
  latitude: Joi.number().min(-90).max(90).required(),
  longitude: Joi.number().min(-180).max(180).required(),
  urgency: Joi.string().valid('now', 'today', 'scheduled').required(),
  scheduledAt: Joi.string().isoDate().allow(null),
  budget: Joi.number().integer().min(1).max(1000000).required(),
  serviceType: Joi.string().valid('helper', 'professional').allow(null),
  helperCategory: Joi.string().trim().max(120).allow('', null),
  professionalCategory: Joi.string().trim().max(120).allow('', null),
  serviceId: Joi.string().trim().max(120).allow('', null),
  variantId: Joi.string().trim().max(120).allow('', null),
  pricingCity: Joi.string().trim().max(80).default('bengaluru'),
  pricingQuantity: Joi.number().integer().min(1).max(100).default(1),
  pricingSnapshot: Joi.object().unknown(true).allow(null),
  capabilityKey: Joi.string().trim().max(120).allow('', null),
  eligibleWorkerCategories: Joi.array()
    .items(Joi.string().trim().max(120)).max(20).default([]),
  estimatedMinPrice: Joi.number().integer().min(0).allow(null),
  estimatedMaxPrice: Joi.number().integer().min(0).allow(null),
  expectedDuration: Joi.string().trim().max(80).allow('', null),
  estimatedDurationMinutes: Joi.number().integer().min(10).max(24 * 60).allow(null),
  notes: Joi.string().trim().max(1000).allow('', null),
  workCondition: Joi.string().trim().max(500).allow('', null),
  quoteId: Joi.string().uuid().allow(null),
  idempotencyKey: Joi.string().uuid().allow(null),
});

function validate(schema, input) {
  const { error, value } = schema.validate(input || {}, {
    abortEarly: false,
    stripUnknown: true,
  });
  if (error) {
    throw new CustomerRouteError(error.message, 400, 'VALIDATION_ERROR');
  }
  return value;
}

function bearerToken(req) {
  const authorization = req.get('authorization') || '';
  return authorization.startsWith('Bearer ')
    ? authorization.slice('Bearer '.length).trim()
    : '';
}

async function requireCustomer(pool, req, customerId) {
  if (!await authenticateCustomer(pool, customerId, bearerToken(req))) {
    throw new CustomerRouteError('Invalid customer session', 401, 'INVALID_CUSTOMER_SESSION');
  }
}

function customerJson(row) {
  return {
    id: row.id,
    name: row.name,
    phone: row.phone,
    phoneVerified: Boolean(row.phone_verified_at),
    phoneVerifiedAt: row.phone_verified_at,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

function taskJson(row) {
  return {
    id: row.id,
    customerId: row.customer_id,
    category: row.category,
    title: row.title,
    description: row.description,
    location: row.address_text,
    latitude: Number(row.latitude),
    longitude: Number(row.longitude),
    urgency: row.urgency,
    scheduledAt: row.scheduled_at,
    budget: row.budget,
    status: row.status,
    serviceType: row.service_type,
    helperCategory: row.helper_category,
    professionalCategory: row.professional_category,
    serviceId: row.service_id,
    capabilityKey: row.capability_key,
    eligibleWorkerCategories: row.eligible_worker_categories || [],
    estimatedMinPrice: row.estimated_min_price,
    estimatedMaxPrice: row.estimated_max_price,
    expectedDuration: row.expected_duration,
    estimatedDurationMinutes: row.estimated_duration_minutes,
    pricingSnapshot: row.pricing_snapshot,
    notes: row.notes,
    workCondition: row.work_condition,
    quoteId: row.household_quote_id,
    selectedWorkerId: row.selected_worker_enrollment_id,
    createdAt: row.created_at,
    completedAt: row.completed_at,
  };
}

function normalizeIndianPhone(phone) {
  const normalized = String(phone || '').replace(/^\+91/, '').replace(/\s|-/g, '');
  return /^[6-9]\d{9}$/.test(normalized) ? normalized : null;
}

async function ensureCustomerSchema(pool) {
  await pool.query(`
    CREATE TABLE IF NOT EXISTS gofer_customers (
      id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
      name VARCHAR(120) NOT NULL DEFAULT 'Workida customer',
      phone VARCHAR(15),
      session_token_hash VARCHAR(64),
      firebase_uid VARCHAR(128),
      phone_verified_at TIMESTAMPTZ,
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    );
    ALTER TABLE gofer_customers ADD COLUMN IF NOT EXISTS session_token_hash VARCHAR(64);
    ALTER TABLE gofer_customers ADD COLUMN IF NOT EXISTS firebase_uid VARCHAR(128);
    ALTER TABLE gofer_customers ADD COLUMN IF NOT EXISTS phone_verified_at TIMESTAMPTZ;
    CREATE UNIQUE INDEX IF NOT EXISTS gofer_customers_firebase_uid_unique
      ON gofer_customers(firebase_uid) WHERE firebase_uid IS NOT NULL;
    CREATE UNIQUE INDEX IF NOT EXISTS gofer_customers_phone_verified_unique
      ON gofer_customers(phone) WHERE phone_verified_at IS NOT NULL;

    CREATE TABLE IF NOT EXISTS gofer_customer_tasks (
      id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
      customer_id UUID NOT NULL REFERENCES gofer_customers(id) ON DELETE CASCADE,
      category VARCHAR(80) NOT NULL,
      title VARCHAR(160) NOT NULL,
      description TEXT NOT NULL,
      address_text VARCHAR(500) NOT NULL,
      latitude DOUBLE PRECISION NOT NULL,
      longitude DOUBLE PRECISION NOT NULL,
      urgency VARCHAR(20) NOT NULL,
      scheduled_at TIMESTAMPTZ,
      budget INTEGER NOT NULL CHECK (budget > 0),
      status VARCHAR(40) NOT NULL DEFAULT 'broadcasting',
      service_type VARCHAR(40), helper_category VARCHAR(120),
      professional_category VARCHAR(120), service_id VARCHAR(120),
      capability_key VARCHAR(120),
      eligible_worker_categories TEXT[] NOT NULL DEFAULT '{}',
      estimated_min_price INTEGER, estimated_max_price INTEGER,
      expected_duration VARCHAR(80), estimated_duration_minutes INTEGER,
      pricing_snapshot JSONB, notes TEXT, work_condition VARCHAR(500),
      household_quote_id UUID, idempotency_key UUID,
      selected_worker_enrollment_id UUID,
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(), completed_at TIMESTAMPTZ
    );
    ALTER TABLE gofer_customer_tasks ADD COLUMN IF NOT EXISTS idempotency_key UUID;
    ALTER TABLE gofer_customer_tasks ADD COLUMN IF NOT EXISTS household_quote_id UUID;
    ALTER TABLE gofer_customer_tasks ADD COLUMN IF NOT EXISTS service_id VARCHAR(120);
    ALTER TABLE gofer_customer_tasks ADD COLUMN IF NOT EXISTS capability_key VARCHAR(120);
    ALTER TABLE gofer_customer_tasks
      ADD COLUMN IF NOT EXISTS eligible_worker_categories TEXT[] NOT NULL DEFAULT '{}';
    ALTER TABLE gofer_customer_tasks ADD COLUMN IF NOT EXISTS estimated_duration_minutes INTEGER;
    ALTER TABLE gofer_customer_tasks ADD COLUMN IF NOT EXISTS pricing_snapshot JSONB;
    ALTER TABLE gofer_customer_tasks ADD COLUMN IF NOT EXISTS scheduled_at TIMESTAMPTZ;
    CREATE INDEX IF NOT EXISTS gofer_tasks_customer_created_idx
      ON gofer_customer_tasks(customer_id, created_at DESC);
    CREATE UNIQUE INDEX IF NOT EXISTS gofer_tasks_customer_idempotency_idx
      ON gofer_customer_tasks(customer_id, idempotency_key)
      WHERE idempotency_key IS NOT NULL;

    CREATE TABLE IF NOT EXISTS gofer_household_quotes (
      id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
      customer_id UUID NOT NULL REFERENCES gofer_customers(id) ON DELETE CASCADE,
      rate_card_version VARCHAR(80) NOT NULL, scope JSONB NOT NULL,
      workload_minutes INTEGER NOT NULL CHECK (workload_minutes > 0),
      recommended_hours INTEGER NOT NULL CHECK (recommended_hours BETWEEN 1 AND 3),
      duration_hours INTEGER NOT NULL CHECK (duration_hours BETWEEN 1 AND 3),
      amount INTEGER NOT NULL CHECK (amount > 0), expires_at TIMESTAMPTZ NOT NULL,
      consumed_task_id UUID, created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    );
    CREATE INDEX IF NOT EXISTS gofer_household_quotes_customer_idx
      ON gofer_household_quotes(customer_id, created_at DESC);
  `);
}

function createCustomerRouter(pool) {
  const router = express.Router();
  const asyncRoute = (handler) => (req, res, next) =>
    Promise.resolve(handler(req, res, next)).catch(next);

  router.post('/customers/session', asyncRoute(async (req, res) => {
    const value = validate(Joi.object({
      customerId: Joi.string().uuid().allow(null, ''),
      sessionToken: Joi.string().min(32).max(256).allow(null, ''),
      name: Joi.string().trim().min(2).max(120).default('Workida customer'),
    }), req.body);

    let result;
    if (value.customerId && value.sessionToken) {
      result = await pool.query(
        'SELECT * FROM gofer_customers WHERE id=$1 AND session_token_hash=$2',
        [value.customerId, hashToken(value.sessionToken)],
      );
    }
    let sessionToken = value.sessionToken || null;
    if (!result || result.rowCount === 0) {
      sessionToken = crypto.randomBytes(32).toString('base64url');
      result = await pool.query(
        'INSERT INTO gofer_customers(name,session_token_hash) VALUES($1,$2) RETURNING *',
        [value.name, hashToken(sessionToken)],
      );
    }
    res.json({ success: true, customer: customerJson(result.rows[0]), sessionToken });
  }));

  router.post('/customers/verify-phone', asyncRoute(async (req, res) => {
    const value = validate(Joi.object({
      customerId: Joi.string().uuid().allow(null, ''),
      sessionToken: Joi.string().min(32).max(256).allow(null, ''),
      idToken: Joi.string().trim().min(100).required(),
      name: Joi.string().trim().min(2).max(120).default('Workida customer'),
    }), req.body);
    const decodedToken = await getFirebaseAuth().verifyIdToken(value.idToken, true);
    const phone = normalizeIndianPhone(decodedToken.phone_number);
    if (!phone) {
      throw new CustomerRouteError(
        'Firebase did not provide a valid Indian mobile number.', 401, 'INVALID_PHONE',
      );
    }

    const client = await pool.connect();
    try {
      await client.query('BEGIN');
      let customer;
      let sessionToken = null;
      const existing = await client.query(
        `SELECT * FROM gofer_customers
         WHERE firebase_uid=$1 OR (phone=$2 AND phone_verified_at IS NOT NULL)
         LIMIT 1 FOR UPDATE`,
        [decodedToken.uid, phone],
      );
      if (existing.rowCount) {
        customer = (await client.query(`
          UPDATE gofer_customers SET firebase_uid=$1,phone=$2,
            phone_verified_at=COALESCE(phone_verified_at,NOW()),name=$3,updated_at=NOW()
          WHERE id=$4 RETURNING *`,
        [decodedToken.uid, phone, value.name, existing.rows[0].id])).rows[0];
      } else if (value.customerId && value.sessionToken) {
        const anonymous = await client.query(
          'SELECT * FROM gofer_customers WHERE id=$1 AND session_token_hash=$2 FOR UPDATE',
          [value.customerId, hashToken(value.sessionToken)],
        );
        if (anonymous.rowCount) {
          customer = (await client.query(`
            UPDATE gofer_customers SET firebase_uid=$1,phone=$2,
              phone_verified_at=NOW(),name=$3,updated_at=NOW()
            WHERE id=$4 RETURNING *`,
          [decodedToken.uid, phone, value.name, anonymous.rows[0].id])).rows[0];
          sessionToken = value.sessionToken;
        }
      }
      if (!customer) {
        customer = (await client.query(`
          INSERT INTO gofer_customers(name,phone,firebase_uid,phone_verified_at)
          VALUES($1,$2,$3,NOW()) RETURNING *`,
        [value.name, phone, decodedToken.uid])).rows[0];
      }
      if (!sessionToken) {
        sessionToken = crypto.randomBytes(32).toString('base64url');
        customer = (await client.query(
          'UPDATE gofer_customers SET session_token_hash=$1,updated_at=NOW() WHERE id=$2 RETURNING *',
          [hashToken(sessionToken), customer.id],
        )).rows[0];
      }
      await client.query('COMMIT');
      res.json({ success: true, customer: customerJson(customer), sessionToken });
    } catch (error) {
      await client.query('ROLLBACK');
      throw error;
    } finally {
      client.release();
    }
  }));

  router.post('/household-help/quotes', asyncRoute(async (req, res) => {
    const value = validate(Joi.object({
      customerId: Joi.string().uuid().required(),
      durationHours: Joi.number().integer().min(1).max(3).required(),
      chores: Joi.array().items(Joi.object({
        id: Joi.string().trim().max(80).required(),
        workloadId: Joi.string().trim().max(80).required(),
      })).min(1).max(7).required(),
    }), req.body);
    await requireCustomer(pool, req, value.customerId);
    const quote = quoteHouseholdSession(value);
    const expiresAt = new Date(Date.now() + (15 * 60 * 1000));
    const inserted = await pool.query(`
      INSERT INTO gofer_household_quotes(
        customer_id,rate_card_version,scope,workload_minutes,
        recommended_hours,duration_hours,amount,expires_at
      ) VALUES($1,$2,$3::jsonb,$4,$5,$6,$7,$8) RETURNING id`,
    [value.customerId, quote.rateCardVersion, JSON.stringify(quote.chores),
      quote.workloadMinutes, quote.recommendedHours, quote.durationHours,
      quote.amount, expiresAt]);
    res.status(201).json({
      success: true,
      quote: { ...quote, id: inserted.rows[0].id, expiresAt: expiresAt.toISOString() },
    });
  }));

  router.post('/tasks', asyncRoute(async (req, res) => {
    const value = validate(taskSchema, req.body);
    const customer = await pool.query(
      'SELECT id,phone_verified_at FROM gofer_customers WHERE id=$1',
      [value.customerId],
    );
    if (!customer.rowCount) {
      throw new CustomerRouteError('Customer session not found', 404, 'CUSTOMER_NOT_FOUND');
    }
    await requireCustomer(pool, req, value.customerId);
    if (!customer.rows[0].phone_verified_at) {
      throw new CustomerRouteError(
        'Verify your phone number before posting a booking.',
        403,
        'PHONE_VERIFICATION_REQUIRED',
      );
    }

    let effectiveValue = value;
    if (value.helperCategory === 'Household help' && !value.quoteId) {
      throw new CustomerRouteError('A household quote is required.');
    }
    if (value.quoteId) {
      const quoteResult = await pool.query(`
        SELECT * FROM gofer_household_quotes
        WHERE id=$1 AND customer_id=$2 AND expires_at>NOW()`,
      [value.quoteId, value.customerId]);
      if (!quoteResult.rowCount) {
        throw new CustomerRouteError(
          'Household quote expired. Request a new quote.', 409, 'QUOTE_EXPIRED',
        );
      }
      const quote = quoteResult.rows[0];
      if (quote.consumed_task_id) {
        const existing = await pool.query(
          'SELECT * FROM gofer_customer_tasks WHERE id=$1 AND customer_id=$2',
          [quote.consumed_task_id, value.customerId],
        );
        if (existing.rowCount) {
          return res.json({ success: true, task: taskJson(existing.rows[0]) });
        }
      }
      effectiveValue = {
        ...value,
        budget: quote.amount,
        estimatedMinPrice: quote.amount,
        estimatedMaxPrice: quote.amount,
        expectedDuration: `${quote.duration_hours} hours`,
      };
    }
    if (effectiveValue.estimatedDurationMinutes && effectiveValue.serviceId) {
      const pricingConfig = await buildEffectivePricingConfig(pool, {
        serviceId: effectiveValue.serviceId,
        serviceType: effectiveValue.serviceType,
        capabilityKey: effectiveValue.capabilityKey,
        category: effectiveValue.category,
        variantId: effectiveValue.pricingSnapshot?.variantId || effectiveValue.variantId,
        city: effectiveValue.pricingSnapshot?.city || effectiveValue.pricingCity,
        quantity: effectiveValue.pricingSnapshot?.quantity || effectiveValue.pricingQuantity,
      });
      const estimate = calculateEstimate(pricingConfig, effectiveValue.estimatedDurationMinutes);
      effectiveValue = {
        ...effectiveValue,
        budget: Math.floor(estimate.estimatedTotalMinor / 100),
        estimatedMinPrice: Math.floor(estimate.estimatedTotalMinor / 100),
        estimatedMaxPrice: Math.floor(estimate.estimatedTotalMinor / 100),
        pricingSnapshot: pricingConfig,
      };
    }
    effectiveValue = {
      ...effectiveValue,
      scheduledAt: validateScheduledAt({
        urgency: effectiveValue.urgency,
        scheduledAt: effectiveValue.scheduledAt,
      }),
    };
    const result = await pool.query(`
      INSERT INTO gofer_customer_tasks(
        customer_id,category,title,description,address_text,latitude,longitude,
        urgency,budget,service_type,helper_category,professional_category,
        service_id,capability_key,eligible_worker_categories,estimated_min_price,
        estimated_max_price,expected_duration,estimated_duration_minutes,
        pricing_snapshot,notes,work_condition,household_quote_id,idempotency_key,scheduled_at
      ) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20::jsonb,$21,$22,$23,$24,$25)
      ON CONFLICT (customer_id,idempotency_key) WHERE idempotency_key IS NOT NULL
      DO UPDATE SET idempotency_key=EXCLUDED.idempotency_key RETURNING *`,
    [effectiveValue.customerId, effectiveValue.category, effectiveValue.title,
      effectiveValue.description, effectiveValue.address, effectiveValue.latitude,
      effectiveValue.longitude, effectiveValue.urgency, effectiveValue.budget,
      effectiveValue.serviceType, effectiveValue.helperCategory,
      effectiveValue.professionalCategory, effectiveValue.serviceId,
      effectiveValue.capabilityKey, effectiveValue.eligibleWorkerCategories,
      effectiveValue.estimatedMinPrice, effectiveValue.estimatedMaxPrice,
      effectiveValue.expectedDuration, effectiveValue.estimatedDurationMinutes,
      effectiveValue.pricingSnapshot ? JSON.stringify(effectiveValue.pricingSnapshot) : null,
      effectiveValue.notes, effectiveValue.workCondition, effectiveValue.quoteId,
      effectiveValue.idempotencyKey, effectiveValue.scheduledAt]);
    if (effectiveValue.quoteId) {
      await pool.query(`UPDATE gofer_household_quotes
        SET consumed_task_id=COALESCE(consumed_task_id,$1)
        WHERE id=$2 AND customer_id=$3`,
      [result.rows[0].id, effectiveValue.quoteId, effectiveValue.customerId]);
    }
    res.status(201).json({ success: true, task: taskJson(result.rows[0]) });
  }));

  router.get('/tasks', asyncRoute(async (req, res) => {
    const value = validate(
      Joi.object({ customerId: Joi.string().uuid().required() }), req.query,
    );
    await requireCustomer(pool, req, value.customerId);
    const result = await pool.query(
      'SELECT * FROM gofer_customer_tasks WHERE customer_id=$1 ORDER BY created_at DESC LIMIT 100',
      [value.customerId],
    );
    res.json({ success: true, tasks: result.rows.map(taskJson), total: result.rowCount });
  }));

  router.patch('/tasks/:id/status', asyncRoute(async (req, res) => {
    const value = validate(Joi.object({
      customerId: Joi.string().uuid().required(),
      status: Joi.string().valid(
        'broadcasting', 'collectingOffers', 'noWorkersFound', 'workerSelected',
        'enRoute', 'completed', 'cancelled',
      ).required(),
      workerId: Joi.string().uuid().allow(null),
    }), req.body);
    await requireCustomer(pool, req, value.customerId);
    const result = await pool.query(`
      UPDATE gofer_customer_tasks SET status=$1,
        selected_worker_enrollment_id=COALESCE($2,selected_worker_enrollment_id),
        completed_at=CASE WHEN $1::varchar='completed' THEN NOW() ELSE completed_at END,
        updated_at=NOW() WHERE id=$3 AND customer_id=$4 RETURNING *`,
    [value.status, value.workerId, req.params.id, value.customerId]);
    if (!result.rowCount) {
      throw new CustomerRouteError('Task not found', 404, 'TASK_NOT_FOUND');
    }
    res.json({ success: true, task: taskJson(result.rows[0]) });
  }));

  router.use((error, _req, res, next) => {
    if (error instanceof CustomerRouteError || error instanceof HouseholdPricingError
        || error instanceof PricingError || error instanceof SchedulingError) {
      const statusCode = error.statusCode
        || (error instanceof HouseholdPricingError
          || error instanceof PricingError
          || error instanceof SchedulingError ? 422 : 400);
      return res.status(statusCode).json({
        success: false,
        code: error.code,
        message: error.message,
      });
    }
    return next(error);
  });

  return router;
}

module.exports = {
  CustomerRouteError,
  createCustomerRouter,
  ensureCustomerSchema,
  normalizeIndianPhone,
  taskJson,
};
