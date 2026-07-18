async function getPendingWorkerJob(pool, phone) {
  await pool.query(`
    UPDATE worker_job_dispatches
    SET status = 'expired'
    WHERE status = 'offered' AND expires_at <= NOW()
  `);
  await pool.query(`
    UPDATE worker_job_offers o
    SET status = 'expired', responded_at = COALESCE(responded_at, NOW())
    FROM worker_job_dispatches d
    WHERE o.job_id = d.id AND o.status = 'offered' AND d.status = 'expired'
  `);
  const result = await pool.query(`
    SELECT
      d.id,
      d.category AS "workType",
      d.address_text AS "customerArea",
      CASE
        WHEN wp.latitude IS NULL OR wp.longitude IS NULL THEN 0
        ELSE ROUND((6371 * 2 * ASIN(SQRT(
          POWER(SIN(RADIANS(wp.latitude - d.latitude) / 2), 2) +
          COS(RADIANS(d.latitude)) * COS(RADIANS(wp.latitude)) *
          POWER(SIN(RADIANS(wp.longitude - d.longitude) / 2), 2)
        )))::numeric, 1)::double precision
      END AS "distanceKm",
      'New request' AS "durationLabel",
      d.budget AS "payMin",
      d.budget AS "payMax",
      COALESCE(d.notes, '') AS notes,
      d.status,
      CASE WHEN d.status = 'offered' THEN d.expires_at ELSE NULL END
        AS "expiresAt"
    FROM worker_enrollments we
    JOIN worker_job_offers o ON o.worker_enrollment_id = we.id
    JOIN worker_job_dispatches d ON d.id = o.job_id
    LEFT JOIN worker_presence wp ON wp.worker_enrollment_id = we.id
    WHERE we.phone = $1
      AND (
        (d.status = 'offered' AND o.status = 'offered' AND d.expires_at > NOW())
        OR (
          d.status IN ('accepted', 'arrived', 'started')
          AND d.accepted_worker_id = we.id
        )
      )
    ORDER BY
      CASE WHEN d.status = 'offered' THEN 1 ELSE 0 END,
      d.created_at DESC
    LIMIT 1
  `, [phone]);
  return result.rows[0] || null;
}

module.exports = { getPendingWorkerJob };
