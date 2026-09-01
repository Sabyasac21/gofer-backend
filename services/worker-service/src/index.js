// services/worker-service/src/index.js

const express = require('express');
const helmet = require('helmet');
const cors = require('cors');
const morgan = require('morgan');
const Joi = require('joi');
const { v4: uuidv4 } = require('uuid');

const logger = require('../../../shared/utils/logger');
const { errorHandler } = require('../../../shared/utils/errorHandler');
const pool = require('./config/db');
const {
  deleteWorkerDocumentsForEnrollment,
  DocumentNotFoundError,
  readWorkerDocument,
  saveWorkerDocument,
  validateDocumentStorageConfiguration,
} = require('./services/documentStorage');
const {
  ensureWorkerDeletionSchema,
  permanentlyDeleteWorker,
  phoneResetHash,
  WorkerDeletionError,
} = require('./services/workerDeletion');
const {
  documentBytes,
  documentMetadata,
  legacyDocumentBytes,
} = require('./services/legacyDocumentPayload');
const {
  decryptDocumentField,
  documentFieldEncryptionStatus,
  ensureDocumentSensitiveFieldsSchema,
  protectExtractedFields,
} = require('./services/documentFieldEncryption');
const { buildMockHyperVergeResult } = require('./services/kycProvider');
const {
  validateAadhaarEnrollment,
} = require('./services/aadhaarEnrollmentValidation');
const { getFirebaseAuth } = require('./services/firebaseAdmin');
const {
  initializeMessaging,
  getMessagingStatus,
  ensureDispatchSchema,
  updatePresence,
  dispatchJob,
  respondToJob,
  getDispatchStatus,
  updateJobStatusByCustomerTask,
  updateJobStatusByWorker,
  getWorkerJobStatus,
  getWorkerDashboard,
  getPendingWorkerJob,
} = require('./services/jobDispatch');
const {
  PRESENCE_FRESH_HOURS,
  getWorkerAvailability,
  summarizeAvailability,
} = require('./services/workerAvailability');
const {
  authenticateCustomer,
  customerJob,
  ensureMarketplaceSchema,
} = require('./services/marketplaceTransaction');
const { createMarketplaceRouter } = require('./routes/marketplace.routes');
const {
  createCustomerRouter,
  ensureCustomerSchema,
} = require('./routes/customer.routes');
const {
  buildEffectivePricingConfig,
  ensurePricingAdminSchema,
  createCatalogService,
  getEffectivePublicPriceBook,
  listAdminPricingServices,
  savePricingVersion,
} = require('../../../shared/pricing/pricingRepository');
const {
  calculateEstimate,
  PricingError,
} = require('../../../shared/pricing/workidaPricing');
const {
  eventId,
  enqueueNotificationEvent,
  ensureNotificationOutbox,
  startNotificationOutboxPublisher,
} = require('../../../shared/notifications/outbox');

const app = express();
app.use(helmet());
app.use(cors());
app.use(express.json({ limit: '10mb' }));
app.use((req, res, next) => {
  const incomingId = req.get('x-request-id');
  req.requestId = incomingId && /^[a-zA-Z0-9._:-]{8,128}$/.test(incomingId)
    ? incomingId
    : uuidv4();
  res.set('x-request-id', req.requestId);
  next();
});
app.use(morgan('combined'));

// ─────────────────────────────────────────────────────────
// MONITORING
// ─────────────────────────────────────────────────────────

const prometheus = require('prom-client');

const httpRequestDuration = new prometheus.Histogram({
  name: 'http_request_duration_seconds',
  help: 'Duration of HTTP requests in seconds',
  labelNames: ['method', 'route', 'status_code']
});

app.use((req, res, next) => {
  const start = Date.now();
  res.on('finish', () => {
    const duration = (Date.now() - start) / 1000;
    httpRequestDuration.labels(req.method, req.route?.path || req.path, res.statusCode).observe(duration);
  });
  next();
});

app.get('/metrics', async (req, res) => {
  res.set('Content-Type', prometheus.register.contentType);
  res.end(await prometheus.register.metrics());
});

// ─────────────────────────────────────────────────────────
// HEALTH CHECK
// ─────────────────────────────────────────────────────────

app.get('/health', (req, res) => {
  let documentStorage;
  try {
    documentStorage = validateDocumentStorageConfiguration();
  } catch (error) {
    documentStorage = { configured: false, message: error.message };
  }
  res.json({
    status: 'healthy',
    service: 'worker-service',
    release: process.env.RENDER_GIT_COMMIT || null,
    push: getMessagingStatus(),
    documentStorage,
    documentFieldEncryption: documentFieldEncryptionStatus(),
    timestamp: new Date().toISOString()
  });
});

// ─────────────────────────────────────────────────────────
// ROUTES
// ─────────────────────────────────────────────────────────

app.get('/api/workers/me', (req, res) => {
  res.json({
    success: true,
    worker: {
      id: uuidv4(),
      avgRating: 4.5,
      totalTasksCompleted: 0
    }
  });
});

// Public customer-safe worker directory. This intentionally excludes phone,
// documents, KYC provider details, and other enrollment PII.
app.get('/api/workers/verified', async (req, res, next) => {
  try {
    const result = await pool.query(
      `
        SELECT
          we.id,
          we.full_name AS "fullName",
          we.enrollment_types AS "enrollmentTypes",
          we.professional_categories AS "professionalCategories",
          we.travel_radius_km AS "travelRadiusKm",
          (
            wp.online = TRUE
            AND wp.last_seen_at > NOW() - INTERVAL '12 hours'
            AND wp.fcm_token IS NOT NULL
            AND wp.fcm_token <> ''
          ) AS "availability",
          (wp.latitude IS NOT NULL AND wp.longitude IS NOT NULL)
            AS "locationVerified",
          wp.last_seen_at AS "lastSeenAt"
        FROM worker_enrollments we
        LEFT JOIN worker_presence wp ON wp.worker_enrollment_id = we.id
        WHERE we.worker_status = 'verified'
        ORDER BY we.updated_at DESC
        LIMIT 200
      `
    );

    res.json({
      success: true,
      workers: result.rows.map((worker) => ({
        id: worker.id,
        name: worker.fullName,
        workerType: worker.enrollmentTypes?.includes('professional')
          ? 'professional'
          : 'helper',
        enrollmentTypes: worker.enrollmentTypes || [],
        professionalCategories: worker.professionalCategories || [],
        skill: worker.professionalCategories?.[0] || 'General helper',
        travelRadiusKm: worker.travelRadiusKm,
        verified: true,
        availability: worker.availability === true,
        locationVerified: worker.locationVerified === true,
        lastSeenAt: worker.lastSeenAt,
        rating: 0,
        jobsCompleted: 0,
        distanceKm: 0,
        etaMinutes: 0,
        hourlyRate: 0
      }))
    });
  } catch (error) {
    next(error);
  }
});

app.post('/api/workers/presence', async (req, res, next) => {
  try {
    const { error, value } = Joi.object({
      phone: Joi.string().pattern(/^[6-9]\d{9}$/).required(),
      online: Joi.boolean().required(),
      fcmToken: Joi.string().max(4096).allow('', null),
      platform: Joi.string().valid('android', 'ios').default('android'),
      latitude: Joi.number().min(-90).max(90).allow(null),
      longitude: Joi.number().min(-180).max(180).allow(null),
    }).validate(req.body, { stripUnknown: true });
    if (error) return res.status(400).json({ success: false, message: error.message });
    const presence = await updatePresence(pool, value);
    if (!presence) return res.status(404).json({ success: false, message: 'Verified worker not found' });
    res.json({ success: true, presence });
  } catch (error) {
    error.operation = 'worker_presence_update';
    next(error);
  }
});

app.post('/api/jobs/dispatch', async (req, res, next) => {
  try {
    const { error, value } = Joi.object({
      customerTaskId: Joi.string().max(120).required(),
      customerId: Joi.string().uuid().required(),
      serviceType: Joi.string().valid('helper', 'professional').required(),
      category: Joi.string().trim().max(120).required(),
      serviceId: Joi.string().trim().max(120).allow('', null),
      capabilityKey: Joi.string().trim().max(120).allow('', null),
      eligibleWorkerCategories: Joi.array().items(Joi.string().trim().max(120)).max(20).default([]),
      title: Joi.string().trim().max(160).required(),
      notes: Joi.string().allow('', null).max(1000),
      address: Joi.string().trim().max(500).required(),
      latitude: Joi.number().min(-90).max(90).required(),
      longitude: Joi.number().min(-180).max(180).required(),
      budget: Joi.number().integer().min(1).max(1000000).required(),
      durationLabel: Joi.string().trim().max(80).allow('', null),
      estimatedDurationMinutes: Joi.number().integer().min(10).max(24 * 60).allow(null),
      scope: Joi.array()
        .items(Joi.string().trim().min(1).max(1000))
        .max(50),
    }).validate(req.body, { stripUnknown: true });
    if (error) return res.status(400).json({ success: false, message: error.message });
    const token = (req.get('authorization') || '').replace(/^Bearer\s+/, '');
    if (!await authenticateCustomer(pool, value.customerId, token)) {
      return res.status(401).json({ success: false, message: 'Invalid customer session' });
    }
    const task = await pool.query(
      `SELECT budget,service_type,service_id,capability_key,
              eligible_worker_categories,estimated_duration_minutes,
              pricing_snapshot,scheduled_at
       FROM gofer_customer_tasks WHERE id=$1 AND customer_id=$2`,
      [value.customerTaskId, value.customerId]
    );
    if (!task.rowCount) {
      return res.status(404).json({ success: false, message: 'Customer task not found' });
    }
    const authoritativeTask = task.rows[0];
    const dispatch = await dispatchJob(pool, {
      ...value,
      budget: authoritativeTask.budget,
      serviceType: authoritativeTask.service_type || value.serviceType,
      serviceId: authoritativeTask.service_id || value.serviceId,
      capabilityKey: authoritativeTask.capability_key || value.capabilityKey,
      eligibleWorkerCategories: authoritativeTask.eligible_worker_categories
        || value.eligibleWorkerCategories,
      estimatedDurationMinutes: authoritativeTask.estimated_duration_minutes
        || value.estimatedDurationMinutes,
      pricingSnapshot: authoritativeTask.pricing_snapshot,
      scheduledAt: authoritativeTask.scheduled_at,
    });
    res.status(201).json({ success: true, dispatch });
  } catch (error) { next(error); }
});

app.get('/api/jobs/pending', async (req, res, next) => {
  try {
    const { error, value } = Joi.object({
      phone: Joi.string().pattern(/^[6-9]\d{9}$/).required(),
    }).validate(req.query, { stripUnknown: true });
    if (error) {
      return res.status(400).json({ success: false, message: error.message });
    }
    const job = await getPendingWorkerJob(pool, value.phone);
    res.json({ success: true, job });
  } catch (error) {
    next(error);
  }
});

app.get('/api/workers/dashboard', async (req, res, next) => {
  try {
    const { error, value } = Joi.object({
      phone: Joi.string().pattern(/^[6-9]\d{9}$/).required(),
      limit: Joi.number().integer().min(1).max(100).default(50),
    }).validate(req.query, { stripUnknown: true });
    if (error) {
      return res.status(400).json({ success: false, message: error.message });
    }
    const dashboard = await getWorkerDashboard(pool, value.phone, value.limit);
    if (!dashboard) {
      return res.status(404).json({
        success: false,
        message: 'Verified worker not found',
      });
    }
    res.json({ success: true, dashboard });
  } catch (error) {
    next(error);
  }
});

app.post('/api/jobs/:id/respond', async (req, res, next) => {
  try {
    const { error, value } = Joi.object({
      phone: Joi.string().pattern(/^[6-9]\d{9}$/).required(),
      decision: Joi.string().valid('accepted', 'rejected').required(),
    }).validate(req.body, { stripUnknown: true });
    if (error) return res.status(400).json({ success: false, message: error.message });
    const response = await respondToJob(pool, req.params.id, value.phone, value.decision);
    if (!response) return res.status(404).json({ success: false, message: 'Active job offer not found' });
    res.json({ success: true, response });
  } catch (error) { next(error); }
});

app.get('/api/jobs/customer-task/:customerTaskId', async (req, res, next) => {
  try {
    const { error, value } = Joi.object({
      customerTaskId: Joi.string().uuid().required(),
    }).validate(req.params, { stripUnknown: true });
    if (error) return res.status(400).json({ success: false, message: error.message });
    const customerId = req.get('x-customer-id');
    const token = (req.get('authorization') || '').replace(/^Bearer\s+/, '');
    if (!await authenticateCustomer(pool, customerId, token)) {
      return res.status(401).json({ success: false, message: 'Invalid customer session' });
    }
    if (!await customerJob(pool, value.customerTaskId, customerId)) {
      return res.status(404).json({ success: false, message: 'Dispatch not found' });
    }
    const dispatch = await getDispatchStatus(pool, value.customerTaskId);
    if (!dispatch) return res.status(404).json({ success: false, message: 'Dispatch not found' });
    res.json({ success: true, dispatch });
  } catch (error) { next(error); }
});

app.patch('/api/jobs/customer-task/:customerTaskId/status', async (req, res, next) => {
  try {
    const params = Joi.object({ customerTaskId: Joi.string().uuid().required() })
      .validate(req.params, { stripUnknown: true });
    const body = Joi.object({
      status: Joi.string().valid('started', 'cancelled').required(),
    })
      .validate(req.body, { stripUnknown: true });
    if (params.error || body.error) {
      return res.status(400).json({ success: false, message: (params.error || body.error).message });
    }
    const customerId = req.get('x-customer-id');
    const token = (req.get('authorization') || '').replace(/^Bearer\s+/, '');
    if (!await authenticateCustomer(pool, customerId, token)) {
      return res.status(401).json({ success: false, message: 'Invalid customer session' });
    }
    if (!await customerJob(pool, params.value.customerTaskId, customerId)) {
      return res.status(404).json({ success: false, message: 'Active dispatch not found' });
    }
    const job = await updateJobStatusByCustomerTask(
      pool, params.value.customerTaskId, body.value.status
    );
    if (!job) return res.status(404).json({ success: false, message: 'Active dispatch not found' });
    res.json({ success: true, job });
  } catch (error) { next(error); }
});

app.get('/api/jobs/:id/status', async (req, res, next) => {
  try {
    const { error, value } = Joi.object({
      id: Joi.string().uuid().required(),
      phone: Joi.string().pattern(/^[6-9]\d{9}$/).required(),
    }).validate({ ...req.params, ...req.query }, { stripUnknown: true });
    if (error) return res.status(400).json({ success: false, message: error.message });
    const job = await getWorkerJobStatus(pool, value.id, value.phone);
    if (!job) return res.status(404).json({ success: false, message: 'Accepted job not found' });
    res.json({ success: true, job });
  } catch (error) { next(error); }
});

app.patch('/api/jobs/:id/status', async (req, res, next) => {
  try {
    const { error, value } = Joi.object({
      id: Joi.string().uuid().required(),
      phone: Joi.string().pattern(/^[6-9]\d{9}$/).required(),
      status: Joi.string()
        .valid('arrived', 'started', 'completion_requested', 'completed', 'cancelled')
        .required(),
    }).validate({ ...req.params, ...req.body }, { stripUnknown: true });
    if (error) return res.status(400).json({ success: false, message: error.message });
    const job = await updateJobStatusByWorker(pool, value.id, value.phone, value.status);
    if (!job) {
      return res.status(409).json({
        success: false,
        message: 'Invalid job transition or this job is no longer active',
      });
    }
    res.json({ success: true, job });
  } catch (error) { next(error); }
});

app.get('/api/workers/enrollments/status', async (req, res, next) => {
  try {
    const { error, value } = Joi.object({
      phone: Joi.string().pattern(/^[6-9]\d{9}$/).required()
    }).validate(req.query, { stripUnknown: true });

    if (error) {
      return res.status(400).json({
        success: false,
        message: 'Enter a valid 10 digit mobile number'
      });
    }

    const result = await pool.query(
      `
        SELECT
          id,
          phone,
          full_name AS "fullName",
          review_status AS "reviewStatus",
          worker_status AS "workerStatus",
          kyc_status AS "kycStatus",
          submitted_at AS "submittedAt",
          updated_at AS "updatedAt"
        FROM worker_enrollments
        WHERE phone = $1
        LIMIT 1
      `,
      [value.phone]
    );

    if (result.rowCount === 0) {
      const reset = await pool.query(
        'SELECT 1 FROM worker_enrollment_resets WHERE phone_hash = $1',
        [phoneResetHash(value.phone)],
      );
      return res.json({
        success: true,
        exists: false,
        resetRequired: reset.rowCount > 0,
      });
    }

    res.json({
      success: true,
      exists: true,
      enrollment: result.rows[0]
    });
  } catch (error) {
    next(error);
  }
});

app.post('/api/workers/verification/verify-otp', async (req, res, next) => {
  try {
    const { error, value } = Joi.object({
      phone: Joi.string().pattern(/^[6-9]\d{9}$/).required(),
      idToken: Joi.string().trim().min(100).required(),
    }).validate(req.body, { stripUnknown: true });

    if (error) {
      return res.status(400).json({
        success: false,
        message: 'A valid mobile number and Firebase ID token are required',
      });
    }

    const decodedToken = await getFirebaseAuth().verifyIdToken(value.idToken);
    const verifiedPhone = decodedToken.phone_number || '';
    const normalizedPhone = verifiedPhone.replace(/^\+91/, '');
    if (normalizedPhone !== value.phone) {
      return res.status(401).json({
        success: false,
        message: 'The verified phone number does not match the requested number',
      });
    }

    await pool.query(
      'DELETE FROM worker_enrollment_resets WHERE phone_hash = $1',
      [phoneResetHash(normalizedPhone)],
    );

    const enrollmentResult = await pool.query(
      `
        SELECT
          id,
          phone,
          full_name AS "fullName",
          review_status AS "reviewStatus",
          worker_status AS "workerStatus",
          kyc_status AS "kycStatus",
          submitted_at AS "submittedAt",
          updated_at AS "updatedAt"
        FROM worker_enrollments
        WHERE phone = $1
        LIMIT 1
      `,
      [normalizedPhone]
    );

    res.json({
      success: true,
      message: 'Phone verified successfully',
      phone: normalizedPhone,
      firebaseUid: decodedToken.uid,
      verified: true,
      exists: enrollmentResult.rowCount > 0,
      enrollment: enrollmentResult.rows[0] || null,
    });
  } catch (error) {
    next(error);
  }
});

const documentSchema = Joi.object({
  type: Joi.string().required(),
  path: Joi.string().allow('').default(''),
  fileName: Joi.string().allow('', null),
  contentType: Joi.string()
    .valid('image/jpeg', 'image/png', 'image/heic', 'image/heif', '', null)
    .default('image/jpeg'),
  contentBase64: Joi.string().allow('', null),
  validationChecks: Joi.array().items(
    Joi.object({
      label: Joi.string().required(),
      passed: Joi.boolean().required(),
      message: Joi.string().allow('').required()
    })
  ).default([]),
  extractedFields: Joi.object()
    .pattern(Joi.string().max(80), Joi.string().max(200))
    .default({})
});

const enrollmentSchema = Joi.object({
  phone: Joi.string().pattern(/^[6-9]\d{9}$/).required(),
  language: Joi.string().max(40).default('English'),
  fullName: Joi.string().trim().min(2).max(120).required(),
  age: Joi.number().integer().min(18).max(80).allow(null),
  city: Joi.string().trim().min(2).max(100).required(),
  workArea: Joi.string().trim().min(2).max(150).required(),
  emergencyContact: Joi.string().trim().max(20).allow('', null),
  experience: Joi.string().trim().max(80).default('Beginner'),
  travelRadiusKm: Joi.number().integer().min(1).max(50).default(3),
  enrollmentTypes: Joi.array().items(Joi.string().valid('helper', 'professional')).min(1).required(),
  professionalCategories: Joi.array().items(Joi.string().max(120)).default([]),
  idType: Joi.string().valid('aadhaar').required(),
  documents: Joi.array().items(documentSchema).min(3).max(3).required(),
  consentAccepted: Joi.boolean().valid(true).required(),
  consentVersion: Joi.string().max(40).default('worker-verification-v1'),
  consentAcceptedAt: Joi.date().iso().allow(null)
});

function requireAdmin(req, res) {
  const adminKey = process.env.WORKER_ADMIN_KEY;
  if (!adminKey || req.get('x-admin-key') !== adminKey) {
    res.status(403).json({
      success: false,
      message: 'Admin key required'
    });
    return null;
  }
  return req.get('x-admin-id') || 'local-admin';
}

const adminPricingSchema = Joi.object({
  pricingModel: Joi.string()
    .valid('hourly', 'fixed', 'inspection', 'quote', 'perUnit', 'tiered')
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

app.get('/api/pricing/catalog', async (_req, res, next) => {
  try {
    return res.json({
      success: true,
      priceBook: await getEffectivePublicPriceBook(pool),
    });
  } catch (error) {
    return next(error);
  }
});

app.post('/api/pricing/quotes', async (req, res, next) => {
  try {
    const schema = Joi.object({
      serviceId: Joi.string().trim().max(120).required(),
      serviceType: Joi.string().valid('helper', 'professional').required(),
      capabilityKey: Joi.string().trim().max(120).allow('', null),
      category: Joi.string().trim().max(120).allow('', null),
      variantId: Joi.string().trim().max(120).allow('', null),
      city: Joi.string().trim().max(80).default('bengaluru'),
      quantity: Joi.number().integer().min(1).max(100).default(1),
      estimatedDurationMinutes: Joi.number().integer().min(10).max(24 * 60),
    });
    const { error, value } = schema.validate(req.body || {}, {
      stripUnknown: true,
    });
    if (error) {
      return res.status(400).json({ success: false, message: error.message });
    }
    const pricingConfig = await buildEffectivePricingConfig(pool, value);
    const estimate = calculateEstimate(
      pricingConfig,
      value.estimatedDurationMinutes
        ?? pricingConfig.estimatedDurationMinMinutes,
    );
    return res.json({ success: true, quote: { pricingConfig, estimate } });
  } catch (error) {
    if (error instanceof PricingError) {
      return res.status(422).json({
        success: false,
        code: error.code,
        message: error.message,
      });
    }
    return next(error);
  }
});

app.get('/api/admin/pricing/services', async (req, res, next) => {
  try {
    if (!requireAdmin(req, res)) return;
    const services = await listAdminPricingServices(pool);
    res.json({ success: true, services, total: services.length });
  } catch (error) {
    next(error);
  }
});

const createCatalogServiceSchema = Joi.object({
  sourceServiceId: Joi.string().trim().max(120).required(),
  serviceId: Joi.string().trim().lowercase()
    .pattern(/^[a-z][a-z0-9_]{2,119}$/)
    .required(),
  serviceName: Joi.string().trim().min(3).max(100).required(),
  shortDescription: Joi.string().trim().min(10).max(240).required(),
});

app.post('/api/admin/pricing/services', async (req, res, next) => {
  try {
    const adminId = requireAdmin(req, res);
    if (!adminId) return;
    const { error, value } = createCatalogServiceSchema.validate(req.body || {}, {
      abortEarly: false,
      stripUnknown: true,
    });
    if (error) {
      return res.status(400).json({
        success: false,
        message: 'Invalid service details.',
        errors: error.details.map((detail) => detail.message),
      });
    }
    const service = await createCatalogService(pool, { ...value, adminId });
    return res.status(201).json({ success: true, service });
  } catch (error) {
    if (error instanceof PricingError) {
      return res.status(422).json({ success: false, code: error.code, message: error.message });
    }
    return next(error);
  }
});

app.put('/api/admin/pricing/services/:serviceId', async (req, res, next) => {
  try {
    const adminId = requireAdmin(req, res);
    if (!adminId) return;
    const { error, value } = adminPricingSchema.validate(req.body || {}, {
      abortEarly: false,
      stripUnknown: true,
    });
    if (error) {
      return res.status(400).json({
        success: false,
        message: 'Invalid pricing configuration.',
        errors: error.details.map((detail) => detail.message),
      });
    }

    const service = await savePricingVersion(pool, {
      serviceId: req.params.serviceId,
      adminId,
      value,
    });
    return res.json({ success: true, service });
  } catch (error) {
    if (error instanceof PricingError) {
      return res.status(422).json({
        success: false,
        code: error.code,
        message: error.message,
      });
    }
    return next(error);
  }
});

function consentTextForVersion(version) {
  return `Workida worker verification consent ${version}: I allow Workida to verify my identity, documents, selfie, background, and eligibility through internal review and third-party verification providers for customer safety.`;
}

app.post('/api/workers/enrollments', async (req, res, next) => {
  const client = await pool.connect();
  try {
    const { error, value } = enrollmentSchema.validate(req.body, {
      abortEarly: false,
      stripUnknown: true
    });

    if (error) {
      return res.status(400).json({
        success: false,
        message: 'Invalid worker enrollment data',
        errors: error.details.map((detail) => detail.message)
      });
    }

    if (
      value.enrollmentTypes.includes('professional') &&
      value.professionalCategories.length === 0
    ) {
      return res.status(400).json({
        success: false,
        message: 'Professional workers must choose at least one category'
      });
    }

    const aadhaarValidationErrors = validateAadhaarEnrollment(value);
    if (aadhaarValidationErrors.length > 0) {
      return res.status(400).json({
        success: false,
        message: 'Aadhaar front, back and live selfie verification is required',
        errors: aadhaarValidationErrors,
      });
    }

    await client.query('BEGIN');

    const existingEnrollment = await client.query(
      `
        SELECT id, worker_status AS "workerStatus"
        FROM worker_enrollments
        WHERE phone = $1
        LIMIT 1
      `,
      [value.phone]
    );

    if (existingEnrollment.rowCount > 0) {
      await client.query('ROLLBACK');
      return res.status(409).json({
        success: false,
        message: 'This mobile number already has a worker enrollment.',
        enrollment: existingEnrollment.rows[0]
      });
    }

    const result = await client.query(
      `
        INSERT INTO worker_enrollments (
          phone,
          full_name,
          age,
          city,
          work_area,
          emergency_contact,
          language,
          experience,
          travel_radius_km,
          enrollment_types,
          professional_categories,
          id_type,
          documents,
          consent_accepted,
          consent_version,
          consent_accepted_at,
          review_status,
          worker_status,
          kyc_provider,
          kyc_status,
          submitted_at,
          updated_at
        )
        VALUES (
          $1, $2, $3, $4, $5, $6, $7, $8, $9, $10,
          $11, $12, $13::jsonb, $14, $15, COALESCE($16, NOW()),
          'under_review', 'kyc_pending', 'mock_hyperverge', 'not_started', NOW(), NOW()
        )
        RETURNING
          id,
          phone,
          full_name AS "fullName",
          review_status AS "reviewStatus",
          submitted_at AS "submittedAt"
      `,
      [
        value.phone,
        value.fullName,
        value.age,
        value.city,
        value.workArea,
        value.emergencyContact || null,
        value.language,
        value.experience,
        value.travelRadiusKm,
        value.enrollmentTypes,
        value.professionalCategories,
        value.idType || null,
        JSON.stringify(documentMetadata(value.documents)),
        value.consentAccepted,
        value.consentVersion,
        value.consentAcceptedAt || null
      ]
    );

    const enrollment = result.rows[0];
    await client.query(
      `
        INSERT INTO worker_consents (
          worker_enrollment_id,
          phone,
          consent_version,
          consent_text,
          accepted,
          accepted_at,
          ip_address,
          user_agent
        )
        VALUES ($1, $2, $3, $4, true, COALESCE($5, NOW()), $6, $7)
      `,
      [
        enrollment.id,
        value.phone,
        value.consentVersion,
        consentTextForVersion(value.consentVersion),
        value.consentAcceptedAt || null,
        req.ip,
        req.get('user-agent') || null
      ]
    );

    for (const document of value.documents) {
      const bytes = documentBytes(document);
      const protectedDocumentFields = protectExtractedFields(
        value.idType,
        document.extractedFields || {},
      );
      let stored = {
        storageProvider: 'metadata_only',
        storageKey: document.path || '',
      };

      if (bytes) {
        stored = await saveWorkerDocument({
          enrollmentId: enrollment.id,
          documentType: document.type,
          contentType: document.contentType || 'image/jpeg',
          bytes,
        });
      }

      await client.query(
        `
          INSERT INTO worker_documents (
            worker_enrollment_id,
            phone,
            document_type,
            id_type,
            storage_provider,
            storage_key,
            file_name,
            content_type,
            file_size_bytes,
            validation_checks,
            extracted_fields,
            document_number_encrypted,
            document_number_last4,
            uploaded_at,
            updated_at
          )
          VALUES (
            $1, $2, $3, $4, $5, $6, $7, $8, $9, $10::jsonb, $11::jsonb,
            $12, $13, NOW(), NOW()
          )
          ON CONFLICT (worker_enrollment_id, document_type) DO UPDATE SET
            id_type = EXCLUDED.id_type,
            storage_provider = EXCLUDED.storage_provider,
            storage_key = EXCLUDED.storage_key,
            file_name = EXCLUDED.file_name,
            content_type = EXCLUDED.content_type,
            file_size_bytes = EXCLUDED.file_size_bytes,
            validation_checks = EXCLUDED.validation_checks,
            extracted_fields = EXCLUDED.extracted_fields,
            document_number_encrypted = EXCLUDED.document_number_encrypted,
            document_number_last4 = EXCLUDED.document_number_last4,
            uploaded_at = NOW(),
            updated_at = NOW()
        `,
        [
          enrollment.id,
          value.phone,
          document.type,
          value.idType || null,
          stored.storageProvider,
          stored.storageKey,
          document.fileName || null,
          document.contentType || null,
          bytes ? bytes.length : null,
          JSON.stringify(document.validationChecks || []),
          JSON.stringify(protectedDocumentFields.safeFields),
          protectedDocumentFields.encryptedNumber,
          protectedDocumentFields.numberLast4,
        ]
      );
    }

    await client.query(
      `
        INSERT INTO kyc_verifications (
          worker_enrollment_id,
          provider,
          status,
          raw_result,
          updated_at
        )
        VALUES ($1, 'mock_hyperverge', 'not_started', '{}'::jsonb, NOW())
      `,
      [enrollment.id]
    );

    await client.query('COMMIT');

    res.status(201).json({
      success: true,
      message: 'Worker enrollment submitted for review',
      enrollment
    });
  } catch (error) {
    await client.query('ROLLBACK');
    next(error);
  } finally {
    client.release();
  }
});

app.get('/api/workers/enrollments', async (req, res, next) => {
  try {
    if (!requireAdmin(req, res)) return;

    const result = await pool.query(
      `
        SELECT
          id,
          phone,
          full_name AS "fullName",
          age,
          city,
          work_area AS "workArea",
          emergency_contact AS "emergencyContact",
          language,
          experience,
          travel_radius_km AS "travelRadiusKm",
          enrollment_types AS "enrollmentTypes",
          professional_categories AS "professionalCategories",
          id_type AS "idType",
          documents,
          consent_accepted AS "consentAccepted",
          consent_version AS "consentVersion",
          consent_accepted_at AS "consentAcceptedAt",
          review_status AS "reviewStatus",
          worker_status AS "workerStatus",
          kyc_provider AS "kycProvider",
          kyc_status AS "kycStatus",
          kyc_reference_id AS "kycReferenceId",
          kyc_completed_at AS "kycCompletedAt",
          submitted_at AS "submittedAt",
          updated_at AS "updatedAt"
        FROM worker_enrollments
        ORDER BY submitted_at DESC
        LIMIT 200
      `
    );

    res.json({
      success: true,
      enrollments: result.rows
    });
  } catch (error) {
    next(error);
  }
});

app.get('/api/admin/workers', async (req, res, next) => {
  try {
    if (!requireAdmin(req, res)) return;

    const result = await pool.query(
      `
        SELECT
          we.id,
          we.phone,
          we.full_name AS "fullName",
          we.age,
          we.city,
          we.work_area AS "workArea",
          we.enrollment_types AS "enrollmentTypes",
          we.professional_categories AS "professionalCategories",
          we.id_type AS "idType",
          we.review_status AS "reviewStatus",
          we.worker_status AS "workerStatus",
          we.kyc_provider AS "kycProvider",
          we.kyc_status AS "kycStatus",
          we.kyc_reference_id AS "kycReferenceId",
          we.submitted_at AS "submittedAt",
          COUNT(wd.id)::int AS "documentCount"
        FROM worker_enrollments we
        LEFT JOIN worker_documents wd ON wd.worker_enrollment_id = we.id
        GROUP BY we.id
        ORDER BY we.submitted_at DESC
        LIMIT 500
      `
    );

    res.json({
      success: true,
      workers: result.rows,
    });
  } catch (error) {
    next(error);
  }
});

app.get('/api/admin/worker-availability', async (req, res, next) => {
  try {
    if (!requireAdmin(req, res)) return;
    const { error, value } = Joi.object({
      region: Joi.string().trim().max(120).allow('', null),
      serviceType: Joi.string().valid('helper', 'professional').allow('', null),
      category: Joi.string().trim().max(120).allow('', null),
      latitude: Joi.number().min(-90).max(90),
      longitude: Joi.number().min(-180).max(180),
    }).and('latitude', 'longitude').validate(req.query, {
      stripUnknown: true,
      convert: true,
    });
    if (error) {
      return res.status(400).json({ success: false, message: error.message });
    }
    const workers = await getWorkerAvailability(pool, {
      region: value.region || null,
      serviceType: value.serviceType || null,
      category: value.category || null,
      latitude: value.latitude ?? null,
      longitude: value.longitude ?? null,
    });
    res.json({
      success: true,
      generatedAt: new Date().toISOString(),
      presenceFreshHours: PRESENCE_FRESH_HOURS,
      ...summarizeAvailability(workers),
      workers,
    });
  } catch (error) {
    next(error);
  }
});

app.post('/api/admin/matching-preview', async (req, res, next) => {
  try {
    if (!requireAdmin(req, res)) return;
    const { error, value } = Joi.object({
      region: Joi.string().trim().max(120).allow('', null),
      serviceType: Joi.string().valid('helper', 'professional').required(),
      category: Joi.string().trim().max(120).allow('', null),
      latitude: Joi.number().min(-90).max(90).required(),
      longitude: Joi.number().min(-180).max(180).required(),
    }).validate(req.body, { stripUnknown: true });
    if (error) {
      return res.status(400).json({ success: false, message: error.message });
    }
    const workers = await getWorkerAvailability(pool, value);
    const eligible = workers.filter((worker) => worker.taskEligible);
    res.json({
      success: true,
      generatedAt: new Date().toISOString(),
      criteria: value,
      counts: {
        evaluated: workers.length,
        eligible: eligible.length,
        excluded: workers.length - eligible.length,
      },
      eligible,
      excluded: workers.filter((worker) => !worker.taskEligible),
    });
  } catch (error) {
    next(error);
  }
});

app.get('/api/admin/workers/:id', async (req, res, next) => {
  try {
    if (!requireAdmin(req, res)) return;

    const workerResult = await pool.query(
      `
        SELECT
          id,
          phone,
          full_name AS "fullName",
          age,
          city,
          work_area AS "workArea",
          emergency_contact AS "emergencyContact",
          language,
          experience,
          travel_radius_km AS "travelRadiusKm",
          enrollment_types AS "enrollmentTypes",
          professional_categories AS "professionalCategories",
          id_type AS "idType",
          consent_accepted AS "consentAccepted",
          consent_version AS "consentVersion",
          consent_accepted_at AS "consentAcceptedAt",
          review_status AS "reviewStatus",
          worker_status AS "workerStatus",
          kyc_provider AS "kycProvider",
          kyc_status AS "kycStatus",
          kyc_reference_id AS "kycReferenceId",
          kyc_completed_at AS "kycCompletedAt",
          submitted_at AS "submittedAt",
          updated_at AS "updatedAt"
        FROM worker_enrollments
        WHERE id = $1
      `,
      [req.params.id]
    );

    if (workerResult.rowCount === 0) {
      return res.status(404).json({
        success: false,
        message: 'Worker not found',
      });
    }

    const documents = await pool.query(
      `
        SELECT
          id,
          document_type AS "documentType",
          id_type AS "idType",
          storage_provider AS "storageProvider",
          storage_key AS "storageKey",
          file_name AS "fileName",
          content_type AS "contentType",
          file_size_bytes AS "fileSizeBytes",
          validation_checks AS "validationChecks",
          extracted_fields AS "extractedFields",
          document_number_last4 AS "documentNumberLast4",
          (document_number_encrypted IS NOT NULL) AS "fullDocumentNumberAvailable",
          uploaded_at AS "uploadedAt"
        FROM worker_documents
        WHERE worker_enrollment_id = $1
        ORDER BY uploaded_at DESC
      `,
      [req.params.id]
    );

    const kyc = await pool.query(
      `
        SELECT
          id,
          provider,
          provider_reference_id AS "providerReferenceId",
          status,
          document_status AS "documentStatus",
          face_match_status AS "faceMatchStatus",
          liveness_status AS "livenessStatus",
          background_status AS "backgroundStatus",
          face_match_score AS "faceMatchScore",
          decision_reason AS "decisionReason",
          processed_by AS "processedBy",
          processed_at AS "processedAt",
          created_at AS "createdAt",
          updated_at AS "updatedAt"
        FROM kyc_verifications
        WHERE worker_enrollment_id = $1
        ORDER BY created_at DESC
      `,
      [req.params.id]
    );

    res.json({
      success: true,
      worker: {
        ...workerResult.rows[0],
        documents: documents.rows,
        kycVerifications: kyc.rows,
      },
    });
  } catch (error) {
    next(error);
  }
});

app.get('/api/admin/workers/:id/documents/:documentId', async (req, res, next) => {
  try {
    if (!requireAdmin(req, res)) return;

    const result = await pool.query(
      `
        SELECT wd.storage_provider AS "storageProvider",
               wd.storage_key AS "storageKey",
               wd.document_type AS "documentType",
               wd.file_name AS "fileName",
               wd.content_type AS "contentType",
               we.documents AS "legacyDocuments"
        FROM worker_documents wd
        JOIN worker_enrollments we ON we.id = wd.worker_enrollment_id
        WHERE wd.id = $1 AND wd.worker_enrollment_id = $2
      `,
      [req.params.documentId, req.params.id]
    );
    if (result.rowCount === 0) {
      return res.status(404).json({ success: false, message: 'Document not found' });
    }

    const document = result.rows[0];
    let bytes;
    let source = document.storageProvider;
    try {
      bytes = await readWorkerDocument(document);
    } catch (error) {
      if (!(error instanceof DocumentNotFoundError)) throw error;
      bytes = legacyDocumentBytes(document.legacyDocuments, document.documentType);
      source = 'legacy_database_fallback';
    }

    if (!bytes) {
      return res.status(404).json({
        success: false,
        code: 'DOCUMENT_BYTES_NOT_FOUND',
        message: 'The stored image file is missing and no legacy recovery payload is available.',
      });
    }

    const safeFileName = (document.fileName || `${document.documentType}.jpg`)
      .replace(/[^a-zA-Z0-9._-]/g, '_');
    res.set({
      'Cache-Control': 'private, no-store, max-age=0',
      'Content-Disposition': `inline; filename="${safeFileName}"`,
      'Content-Length': String(bytes.length),
      'X-Document-Source': source,
      'X-Content-Type-Options': 'nosniff',
    });
    return res.type(document.contentType || 'application/octet-stream').send(bytes);
  } catch (error) {
    if (error.code === 'INVALID_DOCUMENT_PATH') {
      return res.status(403).json({ success: false, message: 'Invalid document path' });
    }
    next(error);
  }
});

app.get('/api/admin/workers/:id/documents/:documentId/number', async (req, res, next) => {
  try {
    const adminId = requireAdmin(req, res);
    if (!adminId) return;

    const result = await pool.query(
      `
        SELECT document_number_encrypted AS "encryptedNumber",
               document_type AS "documentType"
        FROM worker_documents
        WHERE id = $1 AND worker_enrollment_id = $2
      `,
      [req.params.documentId, req.params.id],
    );
    if (result.rowCount === 0) {
      return res.status(404).json({ success: false, message: 'Document not found' });
    }
    if (!result.rows[0].encryptedNumber) {
      return res.status(404).json({
        success: false,
        code: 'FULL_DOCUMENT_NUMBER_NOT_AVAILABLE',
        message: 'The full ID number was not retained for this enrollment.',
      });
    }

    const documentNumber = decryptDocumentField(result.rows[0].encryptedNumber);
    await pool.query(
      `
        INSERT INTO admin_audit_logs (admin_id, action, worker_enrollment_id, details)
        VALUES ($1, 'reveal_document_number', $2, $3::jsonb)
      `,
      [
        adminId,
        req.params.id,
        JSON.stringify({
          documentId: req.params.documentId,
          documentType: result.rows[0].documentType,
        }),
      ],
    );

    res.set({
      'Cache-Control': 'private, no-store, max-age=0',
      Pragma: 'no-cache',
    });
    return res.json({ success: true, documentNumber });
  } catch (error) {
    next(error);
  }
});

const workerApprovalSchema = Joi.object({
  notes: Joi.string()
    .trim()
    .max(1000)
    .default('Worker documents and profile approved by administrator'),
});

const workerDeletionSchema = Joi.object({
  confirmation: Joi.string().valid('DELETE').required(),
  expectedPhone: Joi.string().pattern(/^[6-9]\d{9}$/).required(),
});

app.delete('/api/admin/workers/:id', async (req, res, next) => {
  const adminId = requireAdmin(req, res);
  if (!adminId) return;

  const { error: idError } = Joi.string().uuid().required().validate(req.params.id);
  if (idError) {
    return res.status(400).json({ success: false, message: 'Invalid worker id' });
  }

  const { error, value } = workerDeletionSchema.validate(req.body || {}, {
    stripUnknown: true,
  });
  if (error) {
    return res.status(400).json({
      success: false,
      message: error.details[0].message,
    });
  }

  const client = await pool.connect();
  try {
    const summary = await permanentlyDeleteWorker({
      client,
      workerId: req.params.id,
      expectedPhone: value.expectedPhone,
      adminId,
      requestId: req.requestId,
      deleteStoredDocuments: deleteWorkerDocumentsForEnrollment,
    });
    return res.json({ success: true, deleted: true, summary });
  } catch (deleteError) {
    if (deleteError instanceof WorkerDeletionError) {
      return res.status(deleteError.statusCode).json({
        success: false,
        code: deleteError.code,
        message: deleteError.message,
      });
    }
    return next(deleteError);
  } finally {
    client.release();
  }
});

app.post('/api/admin/workers/:id/approve', async (req, res, next) => {
  const client = await pool.connect();
  try {
    const adminId = requireAdmin(req, res);
    if (!adminId) return;

    const { error: idError } = Joi.string().uuid().required().validate(req.params.id);
    if (idError) {
      return res.status(400).json({ success: false, message: 'Invalid worker id' });
    }

    const { error, value } = workerApprovalSchema.validate(req.body || {}, {
      stripUnknown: true,
    });
    if (error) {
      return res.status(400).json({
        success: false,
        message: error.details[0].message,
      });
    }

    await client.query('BEGIN');
    const current = await client.query(
      `
        SELECT id, full_name AS "fullName", worker_status AS "workerStatus"
        FROM worker_enrollments
        WHERE id = $1
        FOR UPDATE
      `,
      [req.params.id]
    );

    if (current.rowCount === 0) {
      await client.query('ROLLBACK');
      return res.status(404).json({ success: false, message: 'Worker not found' });
    }

    if (current.rows[0].workerStatus === 'verified') {
      await client.query('COMMIT');
      return res.json({
        success: true,
        alreadyVerified: true,
        worker: current.rows[0],
      });
    }

    const providerReferenceId = `admin-${uuidv4()}`;
    const verification = await client.query(
      `
        INSERT INTO kyc_verifications (
          worker_enrollment_id,
          provider,
          provider_reference_id,
          status,
          document_status,
          face_match_status,
          liveness_status,
          background_status,
          decision_reason,
          raw_result,
          processed_by,
          processed_at,
          updated_at
        )
        VALUES (
          $1, 'admin_manual', $2, 'verified', 'passed', 'passed', 'passed',
          'clear', $3, $4::jsonb, $5, NOW(), NOW()
        )
        RETURNING id
      `,
      [
        req.params.id,
        providerReferenceId,
        value.notes,
        JSON.stringify({
          source: 'admin_manual_approval',
          approvedBy: adminId,
          checksConfirmed: ['profile', 'documents', 'identity', 'eligibility'],
        }),
        adminId,
      ]
    );

    const workerUpdate = await client.query(
      `
        UPDATE worker_enrollments
        SET
          worker_status = 'verified',
          review_status = 'approved',
          kyc_provider = 'admin_manual',
          kyc_status = 'verified',
          kyc_reference_id = $2,
          kyc_completed_at = NOW(),
          updated_at = NOW()
        WHERE id = $1
        RETURNING
          id,
          full_name AS "fullName",
          worker_status AS "workerStatus",
          review_status AS "reviewStatus",
          kyc_status AS "kycStatus",
          updated_at AS "updatedAt"
      `,
      [req.params.id, providerReferenceId]
    );

    await client.query(
      `
        INSERT INTO admin_audit_logs (admin_id, action, worker_enrollment_id, details)
        VALUES ($1, 'approve_worker', $2, $3::jsonb)
      `,
      [
        adminId,
        req.params.id,
        JSON.stringify({
          notes: value.notes,
          verificationId: verification.rows[0].id,
          previousWorkerStatus: current.rows[0].workerStatus,
        }),
      ]
    );
    await enqueueNotificationEvent(client, {
      eventId: eventId('worker.verification_updated', req.params.id, 'approved'),
      type: 'worker.verification_updated',
      recipients: [{ type: 'worker', id: req.params.id }],
      data: { approved: true },
    });

    await client.query('COMMIT');
    return res.json({ success: true, worker: workerUpdate.rows[0] });
  } catch (error) {
    await client.query('ROLLBACK');
    next(error);
  } finally {
    client.release();
  }
});

const kycSimulationSchema = Joi.object({
  decision: Joi.string().valid('verified', 'failed', 'manual_review').required(),
  faceMatchScore: Joi.number().min(0).max(100).default(92),
  reason: Joi.string().allow('').max(500).default('Admin simulated KYC result'),
});

app.post('/api/admin/workers/:id/kyc/simulate', async (req, res, next) => {
  const client = await pool.connect();
  try {
    const adminId = requireAdmin(req, res);
    if (!adminId) return;

    const { error, value } = kycSimulationSchema.validate(req.body, {
      stripUnknown: true,
    });
    if (error) {
      return res.status(400).json({
        success: false,
        message: error.details[0].message,
      });
    }

    const result = buildMockHyperVergeResult({
      decision: value.decision,
      faceMatchScore: value.faceMatchScore,
      reason: value.reason,
      adminId,
    });

    const workerStatus =
      value.decision === 'verified'
        ? 'verified'
        : value.decision === 'manual_review'
          ? 'manual_review'
          : 'rejected';
    const reviewStatus =
      value.decision === 'verified'
        ? 'approved'
        : value.decision === 'manual_review'
          ? 'underReview'
          : 'rejected';

    await client.query('BEGIN');

    const kycResult = await client.query(
      `
        INSERT INTO kyc_verifications (
          worker_enrollment_id,
          provider,
          provider_reference_id,
          status,
          document_status,
          face_match_status,
          liveness_status,
          background_status,
          face_match_score,
          decision_reason,
          raw_result,
          processed_by,
          processed_at,
          updated_at
        )
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11::jsonb, $12, NOW(), NOW())
        RETURNING id
      `,
      [
        req.params.id,
        result.provider,
        result.providerReferenceId,
        result.status,
        result.documentStatus,
        result.faceMatchStatus,
        result.livenessStatus,
        result.backgroundStatus,
        result.faceMatchScore,
        result.decisionReason,
        JSON.stringify(result.rawResult),
        result.processedBy,
      ]
    );

    const workerUpdate = await client.query(
      `
        UPDATE worker_enrollments
        SET
          worker_status = $2,
          review_status = $3,
          kyc_provider = $4,
          kyc_status = $5,
          kyc_reference_id = $6,
          kyc_completed_at = NOW(),
          updated_at = NOW()
        WHERE id = $1
        RETURNING id, full_name AS "fullName", worker_status AS "workerStatus", kyc_status AS "kycStatus"
      `,
      [
        req.params.id,
        workerStatus,
        reviewStatus,
        result.provider,
        result.status,
        result.providerReferenceId,
      ]
    );

    if (workerUpdate.rowCount === 0) {
      await client.query('ROLLBACK');
      return res.status(404).json({
        success: false,
        message: 'Worker not found',
      });
    }

    await client.query(
      `
        INSERT INTO admin_audit_logs (admin_id, action, worker_enrollment_id, details)
        VALUES ($1, 'simulate_kyc', $2, $3::jsonb)
      `,
      [
        adminId,
        req.params.id,
        JSON.stringify({
          decision: value.decision,
          faceMatchScore: value.faceMatchScore,
          reason: value.reason,
          kycVerificationId: kycResult.rows[0].id,
        }),
      ]
    );
    await enqueueNotificationEvent(client, {
      eventId: eventId('worker.verification_updated', req.params.id, value.decision),
      type: 'worker.verification_updated',
      recipients: [{ type: 'worker', id: req.params.id }],
      data: {
        approved: value.decision === 'verified',
        reason: value.reason,
      },
    });

    await client.query('COMMIT');

    res.json({
      success: true,
      worker: workerUpdate.rows[0],
      kyc: result,
    });
  } catch (error) {
    await client.query('ROLLBACK');
    next(error);
  } finally {
    client.release();
  }
});

// ─────────────────────────────────────────────────────────
// ERROR HANDLER
// ─────────────────────────────────────────────────────────

app.use('/api', createCustomerRouter(pool));
app.use('/api/marketplace', createMarketplaceRouter(pool));
app.use(errorHandler);

// ─────────────────────────────────────────────────────────
// SERVER STARTUP
// ─────────────────────────────────────────────────────────

const PORT = process.env.PORT || 3003;

const startServer = async () => {
  try {
    const documentStorage = validateDocumentStorageConfiguration();
    await ensureDocumentSensitiveFieldsSchema(pool);
    await ensureCustomerSchema(pool);
    await ensureDispatchSchema(pool);
    await ensureMarketplaceSchema(pool);
    await ensurePricingAdminSchema(pool);
    await ensureWorkerDeletionSchema(pool);
    await ensureNotificationOutbox(pool);
    initializeMessaging(logger);
    startNotificationOutboxPublisher(pool, { logger });
    app.listen(PORT, () => {
      logger.info(`Worker Service running on port ${PORT}`);
      logger.info(`Worker document storage: ${documentStorage.provider}`);
      logger.info(`Service ID: ${uuidv4()}`);
    });
  } catch (error) {
    logger.error('Failed to start Worker Service:', error);
    process.exit(1);
  }
};

startServer();

module.exports = app;
