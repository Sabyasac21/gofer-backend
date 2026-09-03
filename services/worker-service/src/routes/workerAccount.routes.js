// services/worker-service/src/routes/workerAccount.routes.js
//
// Google Play requires apps with accounts to offer account + data deletion both
// in-app and via a public URL. This router provides:
//   DELETE /api/workers/me            - authenticated self-service deletion
//   POST   /api/workers/deletion-requests - public "request deletion" (website form)

const express = require('express');
const Joi = require('joi');

const logger = require('../../../../shared/utils/logger');
const {
  permanentlyDeleteWorker,
  recordDeletionRequest,
  WorkerDeletionError,
} = require('../services/workerDeletion');
const {
  deleteWorkerDocumentsForEnrollment,
} = require('../services/documentStorage');
const { getFirebaseAuth } = require('../services/firebaseAdmin');
const { createWorkerAuth } = require('../middleware/workerAuth');

const ACTIVE_JOB_STATUSES = ['accepted', 'arrived', 'started', 'completion_requested'];

function createWorkerAccountRouter(pool, {
  workerAuth = createWorkerAuth(),
  deleteStoredDocuments = deleteWorkerDocumentsForEnrollment,
  deleteFirebaseUser = (uid) => getFirebaseAuth().deleteUser(uid),
  findFirebaseUserByPhone = (phone) => (
    getFirebaseAuth().getUserByPhoneNumber(`+91${phone}`)
  ),
  adminKey = process.env.WORKER_ADMIN_KEY,
} = {}) {
  const router = express.Router();

  function requireAdmin(req, res) {
    if (!adminKey || req.get('x-admin-key') !== adminKey) {
      res.status(403).json({ success: false, message: 'Admin key required' });
      return null;
    }
    return req.get('x-admin-id') || 'local-admin';
  }

  router.delete('/workers/me', workerAuth, async (req, res, next) => {
    const client = await pool.connect();
    try {
      const existing = await client.query(
        'SELECT id FROM worker_enrollments WHERE phone = $1 LIMIT 1',
        [req.workerPhone],
      );
      if (existing.rowCount === 0) {
        return res.status(404).json({
          success: false,
          code: 'WORKER_NOT_FOUND',
          message: 'No worker account is linked to this number.',
        });
      }
      const workerId = existing.rows[0].id;

      const activeJob = await client.query(
        `SELECT id FROM worker_job_dispatches
         WHERE accepted_worker_id = $1 AND status = ANY($2::varchar[])
         LIMIT 1`,
        [workerId, ACTIVE_JOB_STATUSES],
      );
      if (activeJob.rowCount > 0) {
        return res.status(409).json({
          success: false,
          code: 'ACTIVE_JOB',
          message: 'Finish or cancel your current job before deleting your account.',
        });
      }

      const summary = await permanentlyDeleteWorker({
        client,
        workerId,
        expectedPhone: req.workerPhone,
        adminId: `self-service:${req.firebaseUid}`,
        requestId: req.requestId,
        deleteStoredDocuments,
      });

      let authDeletionPending = false;
      try {
        await deleteFirebaseUser(req.firebaseUid);
      } catch (authError) {
        authDeletionPending = true;
        await recordDeletionRequest(pool, {
          phone: req.workerPhone,
          reason: 'Retry deletion of the Firebase Authentication user.',
          source: 'in_app_cleanup',
          status: 'pending_auth_cleanup',
        });
        logger.warn('Firebase user deletion failed after worker self-deletion', {
          requestId: req.requestId,
          error: authError.message,
        });
      }

      return res.status(authDeletionPending ? 202 : 200).json({
        success: true,
        deleted: true,
        authDeletionPending,
        summary,
      });
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

  router.post('/workers/deletion-requests', async (req, res, next) => {
    try {
      const { error, value } = Joi.object({
        phone: Joi.string().pattern(/^[6-9]\d{9}$/).required(),
        reason: Joi.string().trim().max(1000).allow('', null),
      }).validate(req.body, { stripUnknown: true });
      if (error) {
        return res.status(400).json({
          success: false,
          message: 'Enter the 10-digit mobile number registered with Workida.',
        });
      }
      const request = await recordDeletionRequest(pool, value);
      return res.status(202).json({
        success: true,
        message:
          'We received your deletion request. Workida will verify account ownership '
          + 'before processing it within 30 days.',
        requestId: request.id,
      });
    } catch (error) {
      return next(error);
    }
  });

  router.get('/admin/deletion-requests', async (req, res, next) => {
    if (!requireAdmin(req, res)) return;
    try {
      const { error, value } = Joi.object({
        status: Joi.string()
          .valid('pending', 'pending_auth_cleanup', 'resolved', 'all')
          .default('pending'),
      }).validate(req.query, { stripUnknown: true });
      if (error) {
        return res.status(400).json({ success: false, message: error.message });
      }
      const params = [];
      const where = value.status === 'all' ? '' : 'WHERE dr.status = $1';
      if (value.status !== 'all') params.push(value.status);
      const result = await pool.query(
        `SELECT
           dr.id,
           dr.phone,
           dr.reason,
           dr.status,
           dr.source,
           dr.requested_at AS "requestedAt",
           dr.resolved_at AS "resolvedAt",
           dr.resolved_by AS "resolvedBy",
           we.id AS "workerId",
           we.full_name AS "workerName"
         FROM worker_deletion_requests dr
         LEFT JOIN worker_enrollments we ON we.phone = dr.phone
         ${where}
         ORDER BY dr.requested_at ASC
         LIMIT 200`,
        params,
      );
      return res.json({ success: true, requests: result.rows });
    } catch (error) {
      return next(error);
    }
  });

  router.post('/admin/deletion-requests/:id/complete', async (req, res, next) => {
    const adminId = requireAdmin(req, res);
    if (!adminId) return;
    const idResult = Joi.string().uuid().required().validate(req.params.id);
    const bodyResult = Joi.object({
      confirmation: Joi.string().valid('DELETE').required(),
      ownershipVerified: Joi.boolean().valid(true).required(),
    }).validate(req.body || {}, { stripUnknown: true });
    if (idResult.error || bodyResult.error) {
      return res.status(400).json({
        success: false,
        message: (idResult.error || bodyResult.error).message,
      });
    }

    const client = await pool.connect();
    try {
      const requestResult = await client.query(
        `SELECT id, phone, status
         FROM worker_deletion_requests
         WHERE id = $1
         LIMIT 1`,
        [req.params.id],
      );
      if (requestResult.rowCount === 0) {
        return res.status(404).json({
          success: false,
          code: 'DELETION_REQUEST_NOT_FOUND',
          message: 'Deletion request not found.',
        });
      }
      const deletionRequest = requestResult.rows[0];
      const workerResult = await client.query(
        'SELECT id FROM worker_enrollments WHERE phone = $1 LIMIT 1',
        [deletionRequest.phone],
      );
      if (workerResult.rowCount > 0) {
        const workerId = workerResult.rows[0].id;
        const activeJob = await client.query(
          `SELECT id FROM worker_job_dispatches
           WHERE accepted_worker_id = $1 AND status = ANY($2::varchar[])
           LIMIT 1`,
          [workerId, ACTIVE_JOB_STATUSES],
        );
        if (activeJob.rowCount > 0) {
          return res.status(409).json({
            success: false,
            code: 'ACTIVE_JOB',
            message: 'Finish or cancel the active job before completing deletion.',
          });
        }
        await permanentlyDeleteWorker({
          client,
          workerId,
          expectedPhone: deletionRequest.phone,
          adminId,
          requestId: req.requestId,
          deleteStoredDocuments,
        });
      }

      let authDeletionPending = false;
      try {
        const firebaseUser = await findFirebaseUserByPhone(deletionRequest.phone);
        if (firebaseUser && firebaseUser.uid) {
          await deleteFirebaseUser(firebaseUser.uid);
        }
      } catch (authError) {
        if (authError.code !== 'auth/user-not-found') {
          authDeletionPending = true;
          logger.warn('Firebase user cleanup remains pending', {
            requestId: req.requestId,
            deletionRequestId: req.params.id,
            error: authError.message,
          });
        }
      }

      const status = authDeletionPending ? 'pending_auth_cleanup' : 'resolved';
      await pool.query(
        `UPDATE worker_deletion_requests
         SET status = $2,
             resolved_at = CASE WHEN $2 = 'resolved' THEN NOW() ELSE NULL END,
             resolved_by = $3
         WHERE id = $1`,
        [req.params.id, status, adminId],
      );
      return res.status(authDeletionPending ? 202 : 200).json({
        success: true,
        deleted: true,
        status,
      });
    } catch (error) {
      if (error instanceof WorkerDeletionError) {
        return res.status(error.statusCode).json({
          success: false,
          code: error.code,
          message: error.message,
        });
      }
      return next(error);
    } finally {
      client.release();
    }
  });

  return router;
}

module.exports = { createWorkerAccountRouter };
