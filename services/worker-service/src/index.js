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
const { saveWorkerDocument } = require('./services/documentStorage');
const { buildMockHyperVergeResult } = require('./services/kycProvider');
const {
  initializeMessaging,
  ensureDispatchSchema,
  updatePresence,
  dispatchJob,
  respondToJob,
} = require('./services/jobDispatch');

const app = express();

app.use(helmet());
app.use(cors());
app.use(express.json({ limit: '10mb' }));
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
  res.json({
    status: 'healthy',
    service: 'worker-service',
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
          id,
          full_name AS "fullName",
          enrollment_types AS "enrollmentTypes",
          professional_categories AS "professionalCategories",
          travel_radius_km AS "travelRadiusKm"
        FROM worker_enrollments
        WHERE worker_status = 'verified'
        ORDER BY updated_at DESC
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
        availability: false,
        locationVerified: false,
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
  } catch (error) { next(error); }
});

app.post('/api/jobs/dispatch', async (req, res, next) => {
  try {
    const { error, value } = Joi.object({
      customerTaskId: Joi.string().max(120).required(),
      serviceType: Joi.string().valid('helper', 'professional').required(),
      category: Joi.string().trim().max(120).required(),
      title: Joi.string().trim().max(160).required(),
      notes: Joi.string().allow('', null).max(1000),
      address: Joi.string().trim().max(500).required(),
      latitude: Joi.number().min(-90).max(90).required(),
      longitude: Joi.number().min(-180).max(180).required(),
      budget: Joi.number().integer().min(1).max(1000000).required(),
    }).validate(req.body, { stripUnknown: true });
    if (error) return res.status(400).json({ success: false, message: error.message });
    const dispatch = await dispatchJob(pool, value);
    res.status(201).json({ success: true, dispatch });
  } catch (error) { next(error); }
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
      return res.json({
        success: true,
        exists: false
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

const documentSchema = Joi.object({
  type: Joi.string().required(),
  path: Joi.string().allow('').default(''),
  fileName: Joi.string().allow('', null),
  contentType: Joi.string().allow('', null).default('image/jpeg'),
  contentBase64: Joi.string().allow('', null),
  validationChecks: Joi.array().items(
    Joi.object({
      label: Joi.string().required(),
      passed: Joi.boolean().required(),
      message: Joi.string().allow('').required()
    })
  ).default([])
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
  idType: Joi.string().max(80).allow('', null),
  documents: Joi.array().items(documentSchema).default([]),
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

function consentTextForVersion(version) {
  return `Gofer worker verification consent ${version}: I allow Gofer to verify my identity, documents, selfie, background, and eligibility through internal review and third-party verification providers for customer safety.`;
}

function documentBytes(document) {
  if (!document.contentBase64) return null;
  const cleaned = document.contentBase64.includes(',')
    ? document.contentBase64.split(',').pop()
    : document.contentBase64;
  return Buffer.from(cleaned, 'base64');
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
        JSON.stringify(value.documents),
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
            uploaded_at,
            updated_at
          )
          VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10::jsonb, NOW(), NOW())
          ON CONFLICT (worker_enrollment_id, document_type) DO UPDATE SET
            id_type = EXCLUDED.id_type,
            storage_provider = EXCLUDED.storage_provider,
            storage_key = EXCLUDED.storage_key,
            file_name = EXCLUDED.file_name,
            content_type = EXCLUDED.content_type,
            file_size_bytes = EXCLUDED.file_size_bytes,
            validation_checks = EXCLUDED.validation_checks,
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

app.use(errorHandler);

// ─────────────────────────────────────────────────────────
// SERVER STARTUP
// ─────────────────────────────────────────────────────────

const PORT = process.env.PORT || 3003;

const startServer = async () => {
  try {
    await ensureDispatchSchema(pool);
    initializeMessaging(logger);
    app.listen(PORT, () => {
      logger.info(`Worker Service running on port ${PORT}`);
      logger.info(`Service ID: ${uuidv4()}`);
    });
  } catch (error) {
    logger.error('Failed to start Worker Service:', error);
    process.exit(1);
  }
};

startServer();

module.exports = app;
