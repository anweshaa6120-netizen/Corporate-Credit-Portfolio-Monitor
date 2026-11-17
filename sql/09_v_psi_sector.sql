-- =============================================================================
-- v_psi_sector
-- -----------------------------------------------------------------------------
-- Purpose     : Population Stability Index of the sector mix versus a baseline
--               quarter -- detects drift in where the book is deployed.
-- Inputs      : facility_snapshot, obligor, ref_sector, ref_quarter, config
--               (config keys: baseline_quarter, psi_amber, psi_red, psi_epsilon, ccf_undrawn)
-- Output grain: one row per (basis, quarter, sector): 2 bases x 20 quarters x 10 sectors.
--               psi_total and psi_band repeat on every row of a (basis, quarter).
-- Formula     : PSI = SUM_i (a_i - e_i) * LN(a_i / e_i); see v_psi_rating.
-- Assumptions : * Same conventions as v_psi_rating (bases, epsilon floor, bands).
--               * Only 10 bins, so each bin carries more weight than in the
--                 rating PSI; a single large new origination can move EAD-basis
--                 PSI visibly. Sampling-noise floor is ~(K - 1) * (1/n_baseline +
--                 1/n_current), about 0.04 for 10 sectors at ~450 names.
--               * Sector PSI measures mix change, not credit deterioration; a
--                 sector can shrink because of defaults or because of new lending
--                 elsewhere, and PSI cannot tell which.
-- =============================================================================
CREATE OR REPLACE VIEW v_psi_sector AS
WITH cfg AS (
    SELECT MAX(value_txt) FILTER (WHERE key = 'baseline_quarter') AS baseline_quarter,
           MAX(value_num) FILTER (WHERE key = 'psi_amber')        AS psi_amber,
           MAX(value_num) FILTER (WHERE key = 'psi_red')          AS psi_red,
           MAX(value_num) FILTER (WHERE key = 'psi_epsilon')      AS eps,
           CAST(MAX(value_num) FILTER (WHERE key = 'ccf_undrawn') AS DECIMAL(9,4))      AS ccf
    FROM config
),
obligor_q AS (
    SELECT s.quarter, s.obligor_id,
           SUM(s.drawn + cfg.ccf * (s.committed - s.drawn)) AS ead
    FROM facility_snapshot s CROSS JOIN cfg
    GROUP BY s.quarter, s.obligor_id
),
by_sector AS (
    SELECT o.quarter, b.sector, COUNT(*) AS n, SUM(o.ead) AS ead
    FROM obligor_q o
    JOIN obligor b ON b.obligor_id = o.obligor_id
    GROUP BY o.quarter, b.sector
),
shares AS (
    SELECT q.quarter, q.q_index, s.sector,
           COALESCE(b.n, 0)   * 1.0 / SUM(COALESCE(b.n, 0))   OVER (PARTITION BY q.quarter) AS share_obligors,
           COALESCE(b.ead, 0)       / SUM(COALESCE(b.ead, 0)) OVER (PARTITION BY q.quarter) AS share_ead
    FROM ref_quarter q
    CROSS JOIN ref_sector s
    LEFT JOIN by_sector b ON b.quarter = q.quarter AND b.sector = s.sector
),
long AS (
    SELECT 'OBLIGOR_COUNT' AS basis, quarter, q_index, sector, share_obligors AS share FROM shares
    UNION ALL
    SELECT 'EAD',                    quarter, q_index, sector, share_ead       FROM shares
),
paired AS (
    SELECT c.basis, c.quarter, c.q_index, c.sector,
           GREATEST(b.share, cfg.eps) AS expected_share,
           GREATEST(c.share, cfg.eps) AS actual_share
    FROM long c
    CROSS JOIN cfg
    JOIN long b ON b.basis = c.basis AND b.sector = c.sector AND b.quarter = cfg.baseline_quarter
),
scored AS (
    SELECT p.*, CAST((actual_share - expected_share) * ln(actual_share / expected_share) AS DECIMAL(24,18)) AS psi_component  -- DECIMAL: order-independent SUM
    FROM paired p
)
SELECT basis,
       quarter,
       (SELECT baseline_quarter FROM cfg)                                AS baseline_quarter,
       sector,
       expected_share,
       actual_share,
       psi_component,
       SUM(psi_component) OVER (PARTITION BY basis, quarter)             AS psi_total,
       CASE WHEN SUM(psi_component) OVER (PARTITION BY basis, quarter) <  (SELECT psi_amber FROM cfg) THEN 'GREEN'
            WHEN SUM(psi_component) OVER (PARTITION BY basis, quarter) <= (SELECT psi_red   FROM cfg) THEN 'AMBER'
            ELSE 'RED' END                                               AS psi_band
FROM scored
ORDER BY basis, q_index, sector;
