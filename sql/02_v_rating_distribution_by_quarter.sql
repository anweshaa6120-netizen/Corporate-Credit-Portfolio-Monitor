-- =============================================================================
-- v_rating_distribution_by_quarter
-- -----------------------------------------------------------------------------
-- Purpose     : Obligor-count and EAD distribution across the 17 performing
--               rating notches, per quarter. Feeds the rating bar chart.
-- Inputs      : facility_snapshot, rating_obs, ref_rating_scale, ref_quarter, config
--               (config keys: ccf_undrawn)
-- Output grain: one row per (quarter, rating) -- the full 20 x 17 grid, with
--               zero-filled empty notches.
-- Assumptions : * Zero-filling is deliberate: PSI and charts need every notch
--                 present in every quarter, otherwise empty bins silently vanish.
--               * Rating 'D' is excluded; defaulted names are not part of the
--                 performing distribution.
--               * Shares are fractions of the quarter total (0-1).
-- =============================================================================
CREATE OR REPLACE VIEW v_rating_distribution_by_quarter AS
WITH cfg AS (
    SELECT CAST(MAX(value_num) FILTER (WHERE key = 'ccf_undrawn') AS DECIMAL(9,4)) AS ccf FROM config
),
obligor_q AS (
    SELECT s.quarter, s.obligor_id,
           SUM(s.drawn + cfg.ccf * (s.committed - s.drawn)) AS ead
    FROM facility_snapshot s CROSS JOIN cfg
    GROUP BY s.quarter, s.obligor_id
),
rated AS (
    SELECT o.quarter, r.rating, COUNT(*) AS n_obligors, SUM(o.ead) AS ead
    FROM obligor_q o
    JOIN rating_obs r ON r.obligor_id = o.obligor_id AND r.quarter = o.quarter
    WHERE r.rating <> 'D'
    GROUP BY o.quarter, r.rating
),
grid AS (
    SELECT q.quarter, q.q_index, s.rating, s.notch, s.bucket
    FROM ref_quarter q CROSS JOIN ref_rating_scale s
    WHERE s.rating <> 'D'
)
SELECT g.quarter,
       g.rating,
       g.notch,
       g.bucket,
       COALESCE(r.n_obligors, 0)                                      AS n_obligors,
       ROUND(COALESCE(r.ead, 0), 2)                                   AS ead_usd_mn,
       COALESCE(r.n_obligors, 0) * 1.0 / SUM(COALESCE(r.n_obligors, 0)) OVER (PARTITION BY g.quarter) AS share_obligors,
       COALESCE(r.ead, 0)             / SUM(COALESCE(r.ead, 0))         OVER (PARTITION BY g.quarter) AS share_ead
FROM grid g
LEFT JOIN rated r ON r.quarter = g.quarter AND r.rating = g.rating
ORDER BY g.q_index, g.notch;
