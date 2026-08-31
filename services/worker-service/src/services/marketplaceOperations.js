const {
  MarketplaceError,
  appendEvent,
  customerJob,
  requireStatus,
  workerJob,
} = require('./marketplaceTransaction');
const { calculateFinal } = require('../../../../shared/pricing/workidaPricing');

async function inTransaction(pool, operation) {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const result = await operation(client);
    await client.query('COMMIT');
    return result;
  } catch (error) {
    await client.query('ROLLBACK');
    throw error;
  } finally {
    client.release();
  }
}

async function replaceOpenSegment(client, jobId, segmentType, reason, actorType, actorId, idempotencyKey) {
  const existing = await client.query(
    'SELECT * FROM marketplace_time_segments WHERE job_id=$1 AND idempotency_key=$2',
    [jobId, idempotencyKey]
  );
  if (existing.rowCount) return existing.rows[0];
  await client.query(
    'UPDATE marketplace_time_segments SET ended_at=COALESCE(ended_at,NOW()) WHERE job_id=$1 AND ended_at IS NULL',
    [jobId]
  );
  const result = await client.query(`
    INSERT INTO marketplace_time_segments(
      job_id,segment_type,reason,created_by_type,created_by_id,idempotency_key
    ) VALUES($1,$2,$3,$4,$5,$6)
    ON CONFLICT(job_id,idempotency_key) DO UPDATE
      SET idempotency_key=EXCLUDED.idempotency_key
    RETURNING *
  `, [jobId, segmentType, reason, actorType, actorId, idempotencyKey]);
  return result.rows[0];
}

async function createRequirement(pool, value) {
  return inTransaction(pool, async (client) => {
    const job = await workerJob(client, value.jobId, value.phone, { lock: true });
    if (!job) throw new MarketplaceError('Accepted job not found.', 404, 'JOB_NOT_FOUND');
    requireStatus(job, ['started']);
    if (value.kind === 'special_tool' && value.standardTool) {
      throw new MarketplaceError(
        'Standard professional tools remain the worker responsibility.',
        409,
        'STANDARD_TOOL_WORKER_RESPONSIBILITY'
      );
    }
    const inserted = await client.query(`
      INSERT INTO marketplace_requirements(
        job_id,kind,description,quantity,reason,image_uri,standard_tool,
        requested_by_worker_id,idempotency_key
      ) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9)
      ON CONFLICT(job_id,idempotency_key) DO UPDATE
        SET idempotency_key=EXCLUDED.idempotency_key
      RETURNING *
    `, [job.id, value.kind, value.description, value.quantity, value.reason,
      value.imageUri, value.standardTool, job.accepted_worker_id, value.idempotencyKey]);
    const waitType = value.kind === 'material' ? 'material_wait' : 'special_tool_wait';
    await replaceOpenSegment(
      client, job.id, waitType, value.reason, 'worker', job.accepted_worker_id,
      value.segmentIdempotencyKey
    );
    await appendEvent(client, {
      jobId: job.id,
      eventType: value.kind === 'material' ? 'material_required' : 'special_tool_required',
      actorType: 'worker',
      actorId: job.accepted_worker_id,
      metadata: { requirementId: inserted.rows[0].id },
      idempotencyKey: value.idempotencyKey,
    });
    return inserted.rows[0];
  });
}

async function updateRequirementByCustomer(pool, value) {
  return inTransaction(pool, async (client) => {
    const job = await customerJob(client, value.customerTaskId, value.customerId, { lock: true });
    if (!job) throw new MarketplaceError('Job not found.', 404, 'JOB_NOT_FOUND');
    const allowed = value.status === 'acknowledged' ? ['requested', 'acknowledged']
      : ['requested', 'acknowledged', 'arranged'];
    const result = await client.query(`
      UPDATE marketplace_requirements
      SET status=$1,
          customer_acknowledged_at=CASE WHEN $1 IN ('acknowledged','arranged')
            THEN COALESCE(customer_acknowledged_at,NOW()) ELSE customer_acknowledged_at END,
          customer_arranged_at=CASE WHEN $1='arranged'
            THEN COALESCE(customer_arranged_at,NOW()) ELSE customer_arranged_at END,
          updated_at=NOW()
      WHERE id=$2 AND job_id=$3 AND status=ANY($4::varchar[])
      RETURNING *
    `, [value.status, value.requirementId, job.id, allowed]);
    if (!result.rowCount) {
      throw new MarketplaceError('This requirement is no longer available.', 409, 'REQUIREMENT_CONFLICT');
    }
    await appendEvent(client, {
      jobId: job.id,
      eventType: value.status === 'arranged' ? 'requirement_arranged' : 'requirement_acknowledged',
      actorType: 'customer', actorId: value.customerId,
      metadata: { requirementId: value.requirementId },
      idempotencyKey: value.idempotencyKey,
    });
    return result.rows[0];
  });
}

async function confirmRequirementByWorker(pool, value) {
  return inTransaction(pool, async (client) => {
    const job = await workerJob(client, value.jobId, value.phone, { lock: true });
    if (!job) throw new MarketplaceError('Accepted job not found.', 404, 'JOB_NOT_FOUND');
    const result = await client.query(`
      UPDATE marketplace_requirements
      SET status='confirmed',worker_confirmed_at=COALESCE(worker_confirmed_at,NOW()),updated_at=NOW()
      WHERE id=$1 AND job_id=$2 AND status IN ('arranged','confirmed') RETURNING *
    `, [value.requirementId, job.id]);
    if (!result.rowCount) {
      throw new MarketplaceError('Customer has not marked this requirement arranged.', 409, 'REQUIREMENT_CONFLICT');
    }
    await replaceOpenSegment(
      client, job.id, 'working', 'Requirement confirmed; work resumed',
      'worker', job.accepted_worker_id, value.segmentIdempotencyKey
    );
    await appendEvent(client, {
      jobId: job.id, eventType: 'requirement_confirmed', actorType: 'worker',
      actorId: job.accepted_worker_id, metadata: { requirementId: value.requirementId },
      idempotencyKey: value.idempotencyKey,
    });
    return result.rows[0];
  });
}

async function startTimeSegment(pool, value) {
  return inTransaction(pool, async (client) => {
    const job = await workerJob(client, value.jobId, value.phone, { lock: true });
    if (!job) throw new MarketplaceError('Accepted job not found.', 404, 'JOB_NOT_FOUND');
    requireStatus(job, ['started']);
    const segment = await replaceOpenSegment(
      client, job.id, value.segmentType, value.reason,
      'worker', job.accepted_worker_id, value.idempotencyKey
    );
    await appendEvent(client, {
      jobId: job.id,
      eventType: value.segmentType === 'working' ? 'waiting_ended' : `${value.segmentType}_started`,
      actorType: 'worker', actorId: job.accepted_worker_id,
      metadata: { segmentId: segment.id, reason: value.reason || null },
      idempotencyKey: value.eventIdempotencyKey,
    });
    return segment;
  });
}

async function requestAdditionalWork(pool, value) {
  return inTransaction(pool, async (client) => {
    const job = await workerJob(client, value.jobId, value.phone, { lock: true });
    if (!job) throw new MarketplaceError('Accepted job not found.', 404, 'JOB_NOT_FOUND');
    requireStatus(job, ['started']);
    const result = await client.query(`
      INSERT INTO marketplace_additional_work(
        job_id,description,additional_labour,estimated_minutes,reason,evidence,
        worker_id,expires_at,request_idempotency_key
      ) VALUES($1,$2,$3,$4,$5,$6::jsonb,$7,NOW()+($8::int*INTERVAL '1 minute'),$9)
      ON CONFLICT(job_id,request_idempotency_key) DO UPDATE
        SET request_idempotency_key=EXCLUDED.request_idempotency_key
      RETURNING *
    `, [job.id, value.description, value.additionalLabour, value.estimatedMinutes,
      value.reason, JSON.stringify(value.evidence || []), job.accepted_worker_id,
      value.expiresInMinutes, value.idempotencyKey]);
    await appendEvent(client, {
      jobId: job.id, eventType: 'additional_work_requested', actorType: 'worker',
      actorId: job.accepted_worker_id,
      metadata: { requestId: result.rows[0].id, additionalLabour: value.additionalLabour },
      idempotencyKey: value.idempotencyKey,
    });
    return result.rows[0];
  });
}

async function decideAdditionalWork(pool, value) {
  return inTransaction(pool, async (client) => {
    const job = await customerJob(client, value.customerTaskId, value.customerId, { lock: true });
    if (!job) throw new MarketplaceError('Job not found.', 404, 'JOB_NOT_FOUND');
    const request = await client.query(`
      SELECT * FROM marketplace_additional_work
      WHERE id=$1 AND job_id=$2 FOR UPDATE
    `, [value.requestId, job.id]);
    if (!request.rowCount) throw new MarketplaceError('Additional work request not found.', 404, 'REQUEST_NOT_FOUND');
    const item = request.rows[0];
    if (item.decision_idempotency_key === value.idempotencyKey) return item;
    if (item.status !== 'pending' || new Date(item.expires_at) <= new Date()) {
      if (item.status === 'pending') {
        await client.query("UPDATE marketplace_additional_work SET status='expired',resolved_at=NOW() WHERE id=$1", [item.id]);
      }
      throw new MarketplaceError('This request is no longer available.', 409, 'REQUEST_CONFLICT');
    }
    const status = value.decision;
    const updated = await client.query(`
      UPDATE marketplace_additional_work
      SET status=$1,resolved_at=NOW(),resolved_by_customer_id=$2,
          decision_idempotency_key=$3 WHERE id=$4 RETURNING *
    `, [status, value.customerId, value.idempotencyKey, item.id]);
    if (status === 'approved') {
      const versionResult = await client.query(
        'SELECT COALESCE(MAX(version),0)+1 AS next FROM marketplace_scope_versions WHERE job_id=$1',
        [job.id]
      );
      const currentScope = await client.query(`
        SELECT COALESCE(
          (SELECT scope FROM marketplace_scope_versions WHERE job_id=$1 ORDER BY version DESC LIMIT 1),
          original_scope
        ) AS scope FROM worker_job_dispatches WHERE id=$1
      `, [job.id]);
      const scope = Array.isArray(currentScope.rows[0].scope) ? [...currentScope.rows[0].scope] : [];
      scope.push({ id: item.id, label: item.description, additional: true });
      await client.query(`
        INSERT INTO marketplace_scope_versions(
          job_id,version,scope,initiated_by_type,initiated_by_id,
          approved_by_type,approved_by_id,price_difference,source_request_id
        ) VALUES($1,$2,$3::jsonb,'worker',$4,'customer',$5,$6,$7)
      `, [job.id, versionResult.rows[0].next, JSON.stringify(scope), item.worker_id,
        value.customerId, item.additional_labour, item.id]);
      await client.query(
        'UPDATE worker_job_dispatches SET current_labour=COALESCE(current_labour,budget)+$1,updated_at=NOW() WHERE id=$2',
        [item.additional_labour, job.id]
      );
      await appendEvent(client, {
        jobId: job.id, eventType: 'scope_changed', actorType: 'system', actorId: null,
        metadata: { requestId: item.id, priceDifference: item.additional_labour },
      });
    }
    await appendEvent(client, {
      jobId: job.id, eventType: `additional_work_${status}`, actorType: 'customer',
      actorId: value.customerId, metadata: { requestId: item.id },
      idempotencyKey: value.idempotencyKey,
    });
    return updated.rows[0];
  });
}

async function addCompletionEvidence(pool, value) {
  return inTransaction(pool, async (client) => {
    const job = await workerJob(client, value.jobId, value.phone, { lock: true });
    if (!job) throw new MarketplaceError('Accepted job not found.', 404, 'JOB_NOT_FOUND');
    requireStatus(job, ['started', 'completion_requested']);
    const result = await client.query(`
      INSERT INTO marketplace_completion_evidence(
        job_id,kind,uri,note,created_by_type,created_by_id,idempotency_key
      ) VALUES($1,$2,$3,$4,'worker',$5,$6)
      ON CONFLICT(job_id,idempotency_key) DO UPDATE SET idempotency_key=EXCLUDED.idempotency_key
      RETURNING *
    `, [job.id, value.kind, value.uri, value.note, job.accepted_worker_id, value.idempotencyKey]);
    return result.rows[0];
  });
}

async function reportRemainingWork(pool, value) {
  return inTransaction(pool, async (client) => {
    const job = await customerJob(client, value.customerTaskId, value.customerId, { lock: true });
    if (!job) throw new MarketplaceError('Job not found.', 404, 'JOB_NOT_FOUND');
    requireStatus(job, ['completion_requested']);
    const result = await client.query(`
      INSERT INTO marketplace_remaining_work(job_id,customer_id,description,evidence,idempotency_key)
      VALUES($1,$2,$3,$4::jsonb,$5)
      ON CONFLICT(job_id,idempotency_key) DO UPDATE SET idempotency_key=EXCLUDED.idempotency_key
      RETURNING *
    `, [job.id, value.customerId, value.description,
      JSON.stringify(value.evidence || []), value.idempotencyKey]);
    await client.query(
      "UPDATE worker_job_dispatches SET status='started',completion_requested_at=NULL,updated_at=NOW() WHERE id=$1",
      [job.id]
    );
    await appendEvent(client, {
      jobId: job.id, eventType: 'remaining_work_reported', actorType: 'customer',
      actorId: value.customerId, metadata: { reportId: result.rows[0].id },
      idempotencyKey: value.idempotencyKey,
    });
    return result.rows[0];
  });
}

async function createCase(pool, value) {
  return inTransaction(pool, async (client) => {
    const job = await customerJob(client, value.customerTaskId, value.customerId, { lock: true });
    if (!job) throw new MarketplaceError('Job not found.', 404, 'JOB_NOT_FOUND');
    const table = value.caseType === 'dispute'
      ? 'marketplace_disputes' : 'marketplace_safety_events';
    let result;
    if (value.caseType === 'dispute') {
      const version = await client.query(
        'SELECT MAX(version) AS version FROM marketplace_scope_versions WHERE job_id=$1', [job.id]
      );
      result = await client.query(`
        INSERT INTO marketplace_disputes(
          job_id,customer_id,category,description,evidence,scope_version,idempotency_key
        ) VALUES($1,$2,$3,$4,$5::jsonb,$6,$7)
        ON CONFLICT(job_id,idempotency_key) DO UPDATE SET idempotency_key=EXCLUDED.idempotency_key
        RETURNING *
      `, [job.id, value.customerId, value.category, value.description,
        JSON.stringify(value.evidence || []), version.rows[0].version, value.idempotencyKey]);
    } else {
      result = await client.query(`
        INSERT INTO marketplace_safety_events(
          job_id,actor_type,actor_id,category,description,idempotency_key
        ) VALUES($1,'customer',$2,$3,$4,$5)
        ON CONFLICT(job_id,idempotency_key) DO UPDATE SET idempotency_key=EXCLUDED.idempotency_key
        RETURNING *
      `, [job.id, value.customerId, value.category, value.description, value.idempotencyKey]);
    }
    await client.query(
      'UPDATE worker_job_dispatches SET financial_hold=TRUE,updated_at=NOW() WHERE id=$1', [job.id]
    );
    await client.query(
      'UPDATE marketplace_payments SET financial_hold=TRUE,updated_at=NOW() WHERE job_id=$1', [job.id]
    );
    await appendEvent(client, {
      jobId: job.id,
      eventType: value.caseType === 'dispute' ? 'dispute_created' : 'safety_issue_created',
      actorType: 'customer', actorId: value.customerId,
      metadata: { caseId: result.rows[0].id, category: value.category },
      idempotencyKey: value.idempotencyKey,
    });
    return { table, case: result.rows[0] };
  });
}

async function createWorkerSafetyCase(pool, value) {
  return inTransaction(pool, async (client) => {
    const job = await workerJob(client, value.jobId, value.phone, { lock: true });
    if (!job) throw new MarketplaceError('Accepted job not found.', 404, 'JOB_NOT_FOUND');
    requireStatus(job, ['accepted', 'arrived', 'started', 'completion_requested']);
    const result = await client.query(`
      INSERT INTO marketplace_safety_events(
        job_id,actor_type,actor_id,category,description,idempotency_key
      ) VALUES($1,'worker',$2,$3,$4,$5)
      ON CONFLICT(job_id,idempotency_key) DO UPDATE
        SET idempotency_key=EXCLUDED.idempotency_key
      RETURNING *
    `, [job.id, job.accepted_worker_id, value.category, value.description,
      value.idempotencyKey]);
    await client.query(
      'UPDATE worker_job_dispatches SET financial_hold=TRUE,updated_at=NOW() WHERE id=$1',
      [job.id]
    );
    await client.query(
      'UPDATE marketplace_payments SET financial_hold=TRUE,updated_at=NOW() WHERE job_id=$1',
      [job.id]
    );
    await replaceOpenSegment(
      client, job.id, 'system_pause', `Safety stop: ${value.category}`,
      'worker', job.accepted_worker_id, value.segmentIdempotencyKey
    );
    await appendEvent(client, {
      jobId: job.id, eventType: 'safety_issue_created', actorType: 'worker',
      actorId: job.accepted_worker_id,
      metadata: { caseId: result.rows[0].id, category: value.category },
      idempotencyKey: value.idempotencyKey,
    });
    return result.rows[0];
  });
}

async function confirmCompletion(pool, value) {
  return inTransaction(pool, async (client) => {
    const job = await customerJob(client, value.customerTaskId, value.customerId, { lock: true });
    if (!job) throw new MarketplaceError('Job not found.', 404, 'JOB_NOT_FOUND');
    if (job.status === 'completed') {
      const existing = await client.query('SELECT * FROM marketplace_payments WHERE job_id=$1', [job.id]);
      return { job, payment: existing.rows[0] || null, existing: true };
    }
    requireStatus(job, ['completion_requested']);
    if (job.financial_hold) {
      throw new MarketplaceError('This job is under review and cannot be completed yet.', 409, 'FINANCIAL_HOLD');
    }
    const amounts = await client.query(`
      SELECT
        COALESCE($2::int,budget) AS original,
        COALESCE((SELECT SUM(additional_labour) FROM marketplace_additional_work
          WHERE job_id=$1 AND status='approved'),0)::int AS additional,
        COALESCE((SELECT SUM(waiting_compensation) FROM marketplace_time_segments
          WHERE job_id=$1),0)::int AS waiting
      FROM worker_job_dispatches WHERE id=$1
    `, [job.id, job.original_labour]);
    const { original, additional, waiting } = amounts.rows[0];
    let finalLabour = Number(original) + Number(additional) + Number(waiting);
    let modernPricing = null;
    if (job.pricing_snapshot && job.estimated_duration_minutes) {
      const duration = await client.query(`
        SELECT
          CEIL(COALESCE(SUM(EXTRACT(EPOCH FROM
            (COALESCE(ended_at,NOW()) - started_at)
          )) FILTER (WHERE segment_type='working'),0) / 60)::int AS verified_minutes,
          COALESCE((SELECT SUM(estimated_minutes) FROM marketplace_additional_work
            WHERE job_id=$1 AND status='approved'),0)::int AS approved_overtime_minutes
        FROM marketplace_time_segments WHERE job_id=$1
      `, [job.id]);
      modernPricing = calculateFinal(job.pricing_snapshot, {
        estimatedMinutes: Number(job.estimated_duration_minutes),
        verifiedActualMinutes: Number(duration.rows[0].verified_minutes),
        approvedOvertimeMinutes: Number(duration.rows[0].approved_overtime_minutes),
        visitFeePaid: false,
      });
      finalLabour = Math.floor(modernPricing.totalCustomerAmountMinor / 100);
    }
    const payment = await client.query(`
      INSERT INTO marketplace_payments(
        job_id,customer_id,worker_id,original_labour,approved_additional_labour,
        waiting_compensation,final_labour,status,visit_fee_minor,
        customer_labour_minor,final_customer_amount_minor,customer_amount_due_minor,
        worker_payout_minor,worker_visit_payout_minor,worker_labour_minor,
        platform_margin_minor,verified_minutes,
        approved_overtime_minutes,visit_fee_paid,pricing_version
      ) VALUES($1,$2,$3,$4,$5,$6,$7,'pending',$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19)
      ON CONFLICT(job_id) DO UPDATE SET job_id=EXCLUDED.job_id RETURNING *
    `, [job.id, value.customerId, job.accepted_worker_id, original,
      additional, waiting, finalLabour,
      modernPricing?.visitFeeMinor ?? null,
      modernPricing?.customerLabourMinor ?? null,
      modernPricing?.totalCustomerAmountMinor ?? null,
      modernPricing?.customerAmountDueMinor ?? null,
      modernPricing?.workerPayoutMinor ?? null,
      modernPricing?.workerVisitPayoutMinor ?? null,
      modernPricing?.workerLabourMinor ?? null,
      modernPricing?.platformGrossMarginMinor ?? null,
      modernPricing?.verifiedActualMinutes ?? null,
      modernPricing?.approvedOvertimeMinutes ?? null,
      false,
      job.pricing_snapshot?.version ?? null]);
    const updated = await client.query(`
      UPDATE worker_job_dispatches
      SET status='completed',completed_at=COALESCE(completed_at,NOW()),
          current_labour=$2,updated_at=NOW()
      WHERE id=$1 RETURNING *
    `, [job.id, finalLabour]);
    await client.query(
      'UPDATE marketplace_time_segments SET ended_at=COALESCE(ended_at,NOW()) WHERE job_id=$1 AND ended_at IS NULL',
      [job.id]
    );
    await appendEvent(client, {
      jobId: job.id, eventType: 'completion_confirmed', actorType: 'customer',
      actorId: value.customerId, metadata: { finalLabour },
      idempotencyKey: value.idempotencyKey,
    });
    return { job: updated.rows[0], payment: payment.rows[0], existing: false };
  });
}

async function createPaymentAttempt(pool, value) {
  return inTransaction(pool, async (client) => {
    const job = await customerJob(client, value.customerTaskId, value.customerId, { lock: true });
    if (!job) throw new MarketplaceError('Job not found.', 404, 'JOB_NOT_FOUND');
    const payment = await client.query(
      'SELECT * FROM marketplace_payments WHERE job_id=$1 FOR UPDATE', [job.id]
    );
    if (!payment.rowCount) throw new MarketplaceError('Payment is not available.', 409, 'PAYMENT_NOT_AVAILABLE');
    const item = payment.rows[0];
    if (item.financial_hold || job.financial_hold) {
      throw new MarketplaceError('Payment is on hold while Workida reviews this job.', 409, 'FINANCIAL_HOLD');
    }
    if (item.status === 'success') return { payment: item, attempt: null, existing: true };
    const provider = process.env.PAYMENT_PROVIDER || 'unconfigured';
    const attempt = await client.query(`
      INSERT INTO marketplace_payment_attempts(payment_id,idempotency_key,provider,status)
      VALUES($1,$2,$3,'pending')
      ON CONFLICT(payment_id,idempotency_key) DO UPDATE
        SET idempotency_key=EXCLUDED.idempotency_key
      RETURNING *
    `, [item.id, value.idempotencyKey, provider]);
    await appendEvent(client, {
      jobId: job.id, eventType: 'payment_started', actorType: 'customer',
      actorId: value.customerId, metadata: { attemptId: attempt.rows[0].id, provider },
      idempotencyKey: value.idempotencyKey,
    });
    return {
      payment: item,
      attempt: attempt.rows[0],
      existing: false,
      integrationRequired: provider === 'unconfigured',
    };
  });
}

function platformFeeFor(labour) {
  const basisPoints = Number.parseInt(process.env.WORKIDA_PLATFORM_FEE_BPS || '0', 10);
  if (!Number.isInteger(basisPoints) || basisPoints < 0 || basisPoints > 10000) {
    throw new MarketplaceError('Invalid platform fee configuration.', 500, 'FINANCIAL_CONFIGURATION');
  }
  return Math.round((labour * basisPoints) / 10000);
}

async function reconcilePayment(pool, value) {
  return inTransaction(pool, async (client) => {
    const attempt = await client.query(`
      SELECT a.*,p.job_id,p.worker_id,p.final_labour,
        p.final_customer_amount_minor,p.worker_payout_minor,
        p.worker_visit_payout_minor,p.worker_labour_minor,p.platform_margin_minor,
        p.visit_fee_minor,p.customer_labour_minor,p.status AS payment_status
      FROM marketplace_payment_attempts a
      JOIN marketplace_payments p ON p.id=a.payment_id
      WHERE a.id=$1 FOR UPDATE
    `, [value.attemptId]);
    if (!attempt.rowCount) throw new MarketplaceError('Payment attempt not found.', 404, 'PAYMENT_NOT_FOUND');
    const item = attempt.rows[0];
    if (item.status === value.status) return item;
    if (!['pending', 'processing'].includes(item.status)) {
      throw new MarketplaceError('Payment attempt is already final.', 409, 'PAYMENT_CONFLICT');
    }
    await client.query(`
      UPDATE marketplace_payment_attempts
      SET status=$1,provider_reference=$2,failure_code=$3,failure_message=$4,updated_at=NOW()
      WHERE id=$5
    `, [value.status, value.providerReference, value.failureCode, value.failureMessage, item.id]);
    const paymentStatus = value.status === 'success' ? 'success' : 'failed';
    const payment = await client.query(`
      UPDATE marketplace_payments
      SET status=$1,paid_at=CASE WHEN $1='success' THEN COALESCE(paid_at,NOW()) ELSE paid_at END,
          updated_at=NOW() WHERE id=$2 RETURNING *
    `, [paymentStatus, item.payment_id]);
    if (value.status === 'success') {
      const modern = item.final_customer_amount_minor != null
        && item.worker_payout_minor != null;
      const customerMinor = modern
        ? Number(item.final_customer_amount_minor)
        : Number(item.final_labour) * 100;
      const payableMinor = modern
        ? Number(item.worker_payout_minor)
        : (Number(item.final_labour) - platformFeeFor(Number(item.final_labour))) * 100;
      const feeMinor = modern
        ? Number(item.platform_margin_minor)
        : customerMinor - payableMinor;
      const fee = Math.floor(feeMinor / 100);
      const payable = Math.floor(payableMinor / 100);
      await client.query(`
        INSERT INTO marketplace_ledger_entries(
          job_id,payment_id,entry_type,account,amount,amount_minor
        ) VALUES($1,$2,'customer_charge','customer_receivable',$3,$4),
              ($1,$2,'worker_earning','worker_payable',$5 * -1,$6 * -1),
              ($1,$2,'platform_fee','platform_revenue',$7 * -1,$8 * -1)
      `, [item.job_id, item.payment_id, Math.floor(customerMinor / 100), customerMinor,
        payable, payableMinor, fee, feeMinor]);
      await client.query(`
        INSERT INTO marketplace_worker_earnings(
          job_id,worker_id,labour,platform_fee,adjustments,payable,status,
          visit_payout_minor,labour_payout_minor,payable_minor
        ) VALUES($1,$2,$3,$4,0,$5,'pending',$6,$7,$8)
        ON CONFLICT(job_id) DO NOTHING
      `, [item.job_id, item.worker_id, payable, fee, payable,
        modern ? Number(item.worker_visit_payout_minor) : null,
        modern ? Number(item.worker_labour_minor) : null,
        payableMinor]);
    }
    await appendEvent(client, {
      jobId: item.job_id,
      eventType: value.status === 'success' ? 'payment_success' : 'payment_failed',
      actorType: 'system', actorId: 'payment_provider',
      metadata: { attemptId: item.id, providerReference: value.providerReference || null },
    });
    return payment.rows[0];
  });
}

async function submitRating(pool, value) {
  return inTransaction(pool, async (client) => {
    const job = await customerJob(client, value.customerTaskId, value.customerId, { lock: true });
    if (!job) throw new MarketplaceError('Job not found.', 404, 'JOB_NOT_FOUND');
    requireStatus(job, ['completed']);
    const payment = await client.query('SELECT status FROM marketplace_payments WHERE job_id=$1', [job.id]);
    if (!payment.rowCount || !['success', 'not_required'].includes(payment.rows[0].status)) {
      throw new MarketplaceError('Rating is available after payment is resolved.', 409, 'PAYMENT_NOT_RESOLVED');
    }
    const existing = await client.query(
      'SELECT * FROM marketplace_ratings WHERE job_id=$1', [job.id]
    );
    if (existing.rowCount) {
      if (existing.rows[0].idempotency_key === value.idempotencyKey) {
        return existing.rows[0];
      }
      throw new MarketplaceError(
        'A rating has already been submitted for this job.', 409, 'RATING_ALREADY_SUBMITTED'
      );
    }
    const result = await client.query(`
      INSERT INTO marketplace_ratings(
        job_id,customer_id,worker_id,quality,professionalism,punctuality,
        communication,comment,idempotency_key
      ) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9)
      ON CONFLICT(job_id) DO NOTHING RETURNING *
    `, [job.id, value.customerId, job.accepted_worker_id, value.quality,
      value.professionalism, value.punctuality, value.communication,
      value.comment, value.idempotencyKey]);
    await client.query(
      'UPDATE worker_job_dispatches SET closed_at=COALESCE(closed_at,NOW()),updated_at=NOW() WHERE id=$1',
      [job.id]
    );
    await appendEvent(client, {
      jobId: job.id, eventType: 'rating_submitted', actorType: 'customer',
      actorId: value.customerId, metadata: { ratingId: result.rows[0].id },
      idempotencyKey: value.idempotencyKey,
    });
    await appendEvent(client, {
      jobId: job.id, eventType: 'job_closed', actorType: 'system', actorId: null,
      metadata: { ratingId: result.rows[0].id },
    });
    return result.rows[0];
  });
}

module.exports = {
  addCompletionEvidence,
  confirmCompletion,
  confirmRequirementByWorker,
  createCase,
  createWorkerSafetyCase,
  createPaymentAttempt,
  createRequirement,
  decideAdditionalWork,
  platformFeeFor,
  reconcilePayment,
  reportRemainingWork,
  replaceOpenSegment,
  requestAdditionalWork,
  startTimeSegment,
  submitRating,
  updateRequirementByCustomer,
};
