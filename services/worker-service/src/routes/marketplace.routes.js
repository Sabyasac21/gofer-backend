const express = require('express');
const Joi = require('joi');

const {
  MarketplaceError,
  authenticateCustomer,
  customerJob,
  transactionSnapshot,
  workerJob,
} = require('../services/marketplaceTransaction');
const operations = require('../services/marketplaceOperations');

const uuid = Joi.string().uuid().required();
const idempotencyKey = Joi.string().uuid().required();
const phone = Joi.string().pattern(/^[6-9]\d{9}$/).required();

function customerCredentials(req) {
  const authorization = req.get('authorization') || '';
  return {
    customerId: req.get('x-customer-id') || '',
    token: authorization.startsWith('Bearer ')
      ? authorization.slice('Bearer '.length).trim()
      : '',
  };
}

async function requireCustomer(pool, req) {
  const credentials = customerCredentials(req);
  const valid = await authenticateCustomer(
    pool, credentials.customerId, credentials.token
  );
  if (!valid) {
    throw new MarketplaceError('Invalid customer session.', 401, 'UNAUTHORIZED');
  }
  return credentials.customerId;
}

function validate(schema, input) {
  const { error, value } = schema.validate(input, {
    stripUnknown: true,
    abortEarly: false,
  });
  if (error) throw new MarketplaceError(error.message, 400, 'VALIDATION_ERROR');
  return value;
}

function createMarketplaceRouter(pool) {
  const router = express.Router();
  const asyncRoute = (handler) => (req, res, next) =>
    Promise.resolve(handler(req, res, next)).catch(next);
  const get = (path, handler) => router.get(path, asyncRoute(handler));
  const post = (path, handler) => router.post(path, asyncRoute(handler));
  const patch = (path, handler) => router.patch(path, asyncRoute(handler));

  get('/customer-tasks/:customerTaskId', async (req, res) => {
    const value = validate(Joi.object({ customerTaskId: uuid }), req.params);
    const customerId = await requireCustomer(pool, req);
    const job = await customerJob(pool, value.customerTaskId, customerId);
    if (!job) throw new MarketplaceError('Job not found.', 404, 'JOB_NOT_FOUND');
    res.json({ success: true, transaction: await transactionSnapshot(pool, job.id) });
  });

  get('/jobs/:jobId', async (req, res) => {
    const value = validate(
      Joi.object({ jobId: uuid, phone }), { ...req.params, ...req.query }
    );
    const job = await workerJob(pool, value.jobId, value.phone);
    if (!job) throw new MarketplaceError('Accepted job not found.', 404, 'JOB_NOT_FOUND');
    res.json({ success: true, transaction: await transactionSnapshot(pool, job.id) });
  });

  post('/jobs/:jobId/requirements', async (req, res) => {
    const value = validate(Joi.object({
      jobId: uuid,
      phone,
      kind: Joi.string().valid('material', 'special_tool').required(),
      description: Joi.string().trim().min(2).max(500).required(),
      quantity: Joi.string().trim().max(80).allow('', null),
      reason: Joi.string().trim().min(2).max(500).required(),
      imageUri: Joi.string().uri().max(2000).allow('', null),
      standardTool: Joi.boolean().default(false),
      idempotencyKey,
      segmentIdempotencyKey: idempotencyKey,
    }), { ...req.params, ...req.body });
    const requirement = await operations.createRequirement(pool, value);
    res.status(201).json({ success: true, requirement });
  });

  patch('/customer-tasks/:customerTaskId/requirements/:requirementId', async (req, res) => {
    const customerId = await requireCustomer(pool, req);
    const value = validate(Joi.object({
      customerTaskId: uuid,
      requirementId: uuid,
      status: Joi.string().valid('acknowledged', 'arranged').required(),
      idempotencyKey,
    }), { ...req.params, ...req.body, customerId });
    value.customerId = customerId;
    const requirement = await operations.updateRequirementByCustomer(pool, value);
    res.json({ success: true, requirement });
  });

  patch('/jobs/:jobId/requirements/:requirementId/confirm', async (req, res) => {
    const value = validate(Joi.object({
      jobId: uuid, requirementId: uuid, phone, idempotencyKey,
      segmentIdempotencyKey: idempotencyKey,
    }), { ...req.params, ...req.body });
    const requirement = await operations.confirmRequirementByWorker(pool, value);
    res.json({ success: true, requirement });
  });

  post('/jobs/:jobId/time-segments', async (req, res) => {
    const value = validate(Joi.object({
      jobId: uuid,
      phone,
      segmentType: Joi.string().valid(
        'working', 'customer_waiting', 'worker_break', 'worker_delay',
        'system_pause', 'material_wait', 'special_tool_wait'
      ).required(),
      reason: Joi.string().trim().max(500).allow('', null),
      idempotencyKey,
      eventIdempotencyKey: idempotencyKey,
    }), { ...req.params, ...req.body });
    const segment = await operations.startTimeSegment(pool, value);
    res.status(201).json({ success: true, segment });
  });

  post('/jobs/:jobId/additional-work', async (req, res) => {
    const value = validate(Joi.object({
      jobId: uuid,
      phone,
      description: Joi.string().trim().min(2).max(1000).required(),
      additionalLabour: Joi.number().integer().min(1).max(1000000).required(),
      estimatedMinutes: Joi.number().integer().min(1).max(10080).required(),
      reason: Joi.string().trim().min(2).max(500).required(),
      evidence: Joi.array().items(Joi.string().uri().max(2000)).max(10).default([]),
      expiresInMinutes: Joi.number().integer().min(5).max(1440).default(30),
      idempotencyKey,
    }), { ...req.params, ...req.body });
    const request = await operations.requestAdditionalWork(pool, value);
    res.status(201).json({ success: true, request });
  });

  post('/customer-tasks/:customerTaskId/additional-work/:requestId/decision', async (req, res) => {
    const customerId = await requireCustomer(pool, req);
    const value = validate(Joi.object({
      customerTaskId: uuid,
      requestId: uuid,
      decision: Joi.string().valid('approved', 'declined').required(),
      idempotencyKey,
    }), { ...req.params, ...req.body });
    value.customerId = customerId;
    const request = await operations.decideAdditionalWork(pool, value);
    res.json({ success: true, request });
  });

  post('/jobs/:jobId/completion-evidence', async (req, res) => {
    const value = validate(Joi.object({
      jobId: uuid,
      phone,
      kind: Joi.string().valid('before_photo', 'after_photo', 'worker_note').required(),
      uri: Joi.string().uri().max(2000).allow('', null),
      note: Joi.string().trim().max(1000).allow('', null),
      idempotencyKey,
    }), { ...req.params, ...req.body });
    if (!value.uri && !value.note) {
      throw new MarketplaceError('Evidence requires a file or note.', 400, 'VALIDATION_ERROR');
    }
    const evidence = await operations.addCompletionEvidence(pool, value);
    res.status(201).json({ success: true, evidence });
  });

  post('/jobs/:jobId/safety', async (req, res) => {
    const value = validate(Joi.object({
      jobId: uuid,
      phone,
      category: Joi.string().trim().min(2).max(80).required(),
      description: Joi.string().trim().min(2).max(2000).required(),
      idempotencyKey,
      segmentIdempotencyKey: idempotencyKey,
    }), { ...req.params, ...req.body });
    const safetyCase = await operations.createWorkerSafetyCase(pool, value);
    res.status(201).json({ success: true, case: safetyCase });
  });

  post('/customer-tasks/:customerTaskId/remaining-work', async (req, res) => {
    const customerId = await requireCustomer(pool, req);
    const value = validate(Joi.object({
      customerTaskId: uuid,
      description: Joi.string().trim().min(2).max(1500).required(),
      evidence: Joi.array().items(Joi.string().uri().max(2000)).max(10).default([]),
      idempotencyKey,
    }), { ...req.params, ...req.body });
    value.customerId = customerId;
    const report = await operations.reportRemainingWork(pool, value);
    res.status(201).json({ success: true, report });
  });

  for (const caseType of ['dispute', 'safety']) {
    post(`/customer-tasks/:customerTaskId/${caseType}`, async (req, res) => {
      const customerId = await requireCustomer(pool, req);
      const value = validate(Joi.object({
        customerTaskId: uuid,
        category: Joi.string().trim().min(2).max(80).required(),
        description: Joi.string().trim().min(2).max(2000).required(),
        evidence: Joi.array().items(Joi.string().uri().max(2000)).max(10).default([]),
        idempotencyKey,
      }), { ...req.params, ...req.body });
      Object.assign(value, { customerId, caseType });
      const created = await operations.createCase(pool, value);
      res.status(201).json({ success: true, case: created.case });
    });
  }

  post('/customer-tasks/:customerTaskId/complete', async (req, res) => {
    const customerId = await requireCustomer(pool, req);
    const value = validate(Joi.object({
      customerTaskId: uuid, idempotencyKey,
    }), { ...req.params, ...req.body });
    value.customerId = customerId;
    res.json({ success: true, ...(await operations.confirmCompletion(pool, value)) });
  });

  post('/customer-tasks/:customerTaskId/payment-attempts', async (req, res) => {
    const customerId = await requireCustomer(pool, req);
    const value = validate(Joi.object({
      customerTaskId: uuid, idempotencyKey,
    }), { ...req.params, ...req.body });
    value.customerId = customerId;
    const payment = await operations.createPaymentAttempt(pool, value);
    res.status(201).json({ success: true, ...payment });
  });

  post('/payment-attempts/:attemptId/reconcile', async (req, res) => {
    if (!process.env.PAYMENT_WEBHOOK_SECRET ||
        req.get('x-payment-webhook-secret') !== process.env.PAYMENT_WEBHOOK_SECRET) {
      throw new MarketplaceError('Invalid payment webhook credentials.', 401, 'UNAUTHORIZED');
    }
    const value = validate(Joi.object({
      attemptId: uuid,
      status: Joi.string().valid('success', 'failed').required(),
      providerReference: Joi.string().max(200).allow('', null),
      failureCode: Joi.string().max(100).allow('', null),
      failureMessage: Joi.string().max(500).allow('', null),
    }), { ...req.params, ...req.body });
    res.json({ success: true, payment: await operations.reconcilePayment(pool, value) });
  });

  post('/customer-tasks/:customerTaskId/rating', async (req, res) => {
    const customerId = await requireCustomer(pool, req);
    const value = validate(Joi.object({
      customerTaskId: uuid,
      quality: Joi.number().integer().min(1).max(5).required(),
      professionalism: Joi.number().integer().min(1).max(5).required(),
      punctuality: Joi.number().integer().min(1).max(5).required(),
      communication: Joi.number().integer().min(1).max(5).required(),
      comment: Joi.string().trim().max(1000).allow('', null),
      idempotencyKey,
    }), { ...req.params, ...req.body });
    value.customerId = customerId;
    res.status(201).json({ success: true, rating: await operations.submitRating(pool, value) });
  });

  router.use((error, _req, res, next) => {
    if (!(error instanceof MarketplaceError)) return next(error);
    res.status(error.statusCode).json({
      success: false,
      code: error.code,
      message: error.message,
    });
  });

  return router;
}

module.exports = { createMarketplaceRouter, customerCredentials, validate };
