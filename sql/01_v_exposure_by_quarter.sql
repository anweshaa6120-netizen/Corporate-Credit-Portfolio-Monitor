-- =============================================================================
-- v_exposure_by_quarter
-- -----------------------------------------------------------------------------
-- Purpose     : Headline portfolio exposure and expected-loss KPIs per quarter.
-- Inputs      : facility_snapshot, rating_obs, ref_pd, config
--               (config keys: ccf_undrawn, lgd, pd_floor)
-- Output grain: one row per quarter.
-- Assumptions : * Performing book only. facility_snapshot rows stop in the
--                 quarter an obligor defaults, so defaulted names drop out of
--                 exposure the quarter they default.
--               * EAD = drawn + CCF * (committed - drawn); one flat CCF from
--                 config (no product-specific CCFs).
--               * EL = EAD * PD * LGD with PD from the obligor's quarter-end
--                 rating (long-run average, floored) and a flat LGD. This is a
--                 through-the-cycle monitoring EL, not an IFRS 9 provision.
--               * All amounts USD mn; single currency, no FX.
--               * Sums are exact: money is DECIMAL and double-valued row products are
--                 cast to DECIMAL before SUM, so results do not depend on parallel
--                 summation order (same seed -> bit-identical output).
-- =============================================================================
CREATE OR REPLACE VIEW v_exposure_by_quarter AS
WITH cfg AS (
    SELECT CAST(MAX(value_num) FILTER (WHERE key = 'ccf_undrawn') AS DECIMAL(9,4)) AS ccf,
           MAX(value_num) FILTER (WHERE key = 'lgd')         AS lgd,
           MAX(value_num) FILTER (WHERE key = 'pd_floor')    AS pd_floor
    FROM config
),
obligor_q AS (                       -- EAD is summed to obligor first so PD/EL are applied once per name
    SELECT s.quarter,
           s.obligor_id,
           COUNT(*)                                          AS n_facilities,
           SUM(s.committed)                                  AS committed,
           SUM(s.drawn)                                      AS drawn,
           SUM(s.drawn + cfg.ccf * (s.committed - s.drawn))  AS ead
    FROM facility_snapshot s
    CROSS JOIN cfg
    GROUP BY s.quarter, s.obligor_id
),
scored AS (
    SELECT o.*,
           CAST(o.ead * GREATEST(p.pd_nr_adjusted, cfg.pd_floor) AS DECIMAL(24,12))            AS ead_x_pd,
           CAST(o.ead * GREATEST(p.pd_nr_adjusted, cfg.pd_floor) * cfg.lgd AS DECIMAL(24,12))  AS expected_loss
    FROM obligor_q o
    CROSS JOIN cfg
    JOIN rating_obs r ON r.obligor_id = o.obligor_id AND r.quarter = o.quarter
    JOIN ref_pd p     ON p.rating = r.rating       -- inner join also drops 'D', which has no PD
)
SELECT q.quarter,
       q.q_index,
       COUNT(*)                                   AS n_obligors,
       SUM(n_facilities)                          AS n_facilities,
       ROUND(SUM(committed), 2)                   AS committed_usd_mn,
       ROUND(SUM(drawn), 2)                       AS drawn_usd_mn,
       ROUND(SUM(committed) - SUM(drawn), 2)      AS undrawn_usd_mn,
       SUM(drawn) / SUM(committed)                AS utilisation,
       ROUND(SUM(ead), 2)                         AS ead_usd_mn,
       ROUND(SUM(ead) / LAG(SUM(ead)) OVER (ORDER BY q.q_index) - 1, 6) AS ead_qoq_growth,
       SUM(ead_x_pd) / SUM(ead)                   AS ead_weighted_pd,
       ROUND(SUM(expected_loss), 4)               AS expected_loss_usd_mn,
       SUM(expected_loss) / SUM(ead) * 10000      AS expected_loss_bps
FROM scored s
JOIN ref_quarter q ON q.quarter = s.quarter
GROUP BY q.quarter, q.q_index
ORDER BY q.q_index;
