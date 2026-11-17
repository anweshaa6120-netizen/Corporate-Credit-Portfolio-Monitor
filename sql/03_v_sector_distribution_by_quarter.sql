-- =============================================================================
-- v_sector_distribution_by_quarter
-- -----------------------------------------------------------------------------
-- Purpose     : Obligor-count, EAD, and risk profile by industry sector per quarter.
-- Inputs      : facility_snapshot, obligor, rating_obs, ref_pd, ref_sector,
--               ref_quarter, config (keys: ccf_undrawn, pd_floor)
-- Output grain: one row per (quarter, sector) -- full 20 x 10 grid, zero-filled.
-- Assumptions : * Performing book only (defaulted names have no snapshot rows).
--               * A single sector per obligor (no multi-sector conglomerate split).
--               * ead_weighted_pd uses long-run rating PDs, so it reflects rating
--                 mix, not current-cycle default conditions.
-- =============================================================================
CREATE OR REPLACE VIEW v_sector_distribution_by_quarter AS
WITH cfg AS (
    SELECT CAST(MAX(value_num) FILTER (WHERE key = 'ccf_undrawn') AS DECIMAL(9,4)) AS ccf,
           MAX(value_num) FILTER (WHERE key = 'pd_floor')    AS pd_floor
    FROM config
),
obligor_q AS (
    SELECT s.quarter, s.obligor_id,
           SUM(s.drawn + cfg.ccf * (s.committed - s.drawn)) AS ead
    FROM facility_snapshot s CROSS JOIN cfg
    GROUP BY s.quarter, s.obligor_id
),
by_sector AS (
    SELECT o.quarter, b.sector,
           COUNT(*)                                              AS n_obligors,
           SUM(o.ead)                                            AS ead,
           SUM(CAST(o.ead * GREATEST(p.pd_nr_adjusted, cfg.pd_floor) AS DECIMAL(24,12))) AS ead_x_pd
    FROM obligor_q o
    CROSS JOIN cfg
    JOIN obligor b    ON b.obligor_id = o.obligor_id
    JOIN rating_obs r ON r.obligor_id = o.obligor_id AND r.quarter = o.quarter
    JOIN ref_pd p     ON p.rating = r.rating
    GROUP BY o.quarter, b.sector
),
grid AS (
    SELECT q.quarter, q.q_index, s.sector
    FROM ref_quarter q CROSS JOIN ref_sector s
)
SELECT g.quarter,
       g.sector,
       COALESCE(b.n_obligors, 0)                                      AS n_obligors,
       ROUND(COALESCE(b.ead, 0), 2)                                   AS ead_usd_mn,
       COALESCE(b.n_obligors, 0) * 1.0 / SUM(COALESCE(b.n_obligors, 0)) OVER (PARTITION BY g.quarter) AS share_obligors,
       COALESCE(b.ead, 0)             / SUM(COALESCE(b.ead, 0))         OVER (PARTITION BY g.quarter) AS share_ead,
       b.ead_x_pd / NULLIF(b.ead, 0)                                  AS ead_weighted_pd
FROM grid g
LEFT JOIN by_sector b ON b.quarter = g.quarter AND b.sector = g.sector
ORDER BY g.q_index, g.sector;
