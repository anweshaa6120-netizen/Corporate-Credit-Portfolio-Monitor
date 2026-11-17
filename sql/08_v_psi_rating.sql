-- =============================================================================
-- v_psi_rating
-- -----------------------------------------------------------------------------
-- Purpose     : Population Stability Index of the rating distribution versus a
--               baseline quarter -- how far has the book's credit-quality mix
--               drifted from where it was when the PD/rating framework was last
--               reviewed?
-- Inputs      : facility_snapshot, rating_obs, ref_rating_scale, ref_quarter, config
--               (config keys: baseline_quarter, psi_amber, psi_red, psi_epsilon, ccf_undrawn)
-- Output grain: one row per (basis, quarter, rating): 2 bases x 20 quarters x 17 notches.
--               psi_total and psi_band repeat on every row of a (basis, quarter)
--               so a consumer can read the total without re-aggregating.
-- Formula     : PSI = SUM_i (a_i - e_i) * LN(a_i / e_i)
--               a_i = share in the current quarter, e_i = share in the baseline.
--               Each term is >= 0, so the sum is >= 0, and 0 only if a = e.
-- Assumptions : * basis OBLIGOR_COUNT weights every name equally (classic PSI);
--                 basis EAD weights by exposure, so a few large names moving
--                 matters more. Both are shown because they can disagree.
--               * Empty bins are floored at psi_epsilon (and shares are not
--                 re-normalised afterwards; the effect is < epsilon * bins).
--               * Bands: green < psi_amber, amber psi_amber..psi_red, red > psi_red
--                 (the conventional 0.10 / 0.25 rule of thumb).
--               * PSI is not a significance test. Sampling noise alone puts a floor
--                 under it of about (K - 1) * (1/n_baseline + 1/n_current) for K
--                 bins: ~0.07 for 17 notches at ~450 names, i.e. most of the way
--                 to the amber threshold. Read amber on this view with that in
--                 mind (the sector PSI, with 10 bins, has a floor of ~0.04).
-- =============================================================================
CREATE OR REPLACE VIEW v_psi_rating AS
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
rated AS (
    SELECT o.quarter, r.rating, COUNT(*) AS n, SUM(o.ead) AS ead
    FROM obligor_q o
    JOIN rating_obs r ON r.obligor_id = o.obligor_id AND r.quarter = o.quarter
    WHERE r.rating <> 'D'
    GROUP BY o.quarter, r.rating
),
shares AS (                                   -- zero-filled grid, then shares per quarter and basis
    SELECT q.quarter, q.q_index, s.rating, s.notch,
           COALESCE(r.n, 0)   * 1.0 / SUM(COALESCE(r.n, 0))   OVER (PARTITION BY q.quarter) AS share_obligors,
           COALESCE(r.ead, 0)       / SUM(COALESCE(r.ead, 0)) OVER (PARTITION BY q.quarter) AS share_ead
    FROM ref_quarter q
    CROSS JOIN ref_rating_scale s
    LEFT JOIN rated r ON r.quarter = q.quarter AND r.rating = s.rating
    WHERE s.rating <> 'D'
),
long AS (
    SELECT 'OBLIGOR_COUNT' AS basis, quarter, q_index, rating, notch, share_obligors AS share FROM shares
    UNION ALL
    SELECT 'EAD',                    quarter, q_index, rating, notch, share_ead       FROM shares
),
paired AS (
    SELECT c.basis, c.quarter, c.q_index, c.rating, c.notch,
           GREATEST(b.share, cfg.eps) AS expected_share,
           GREATEST(c.share, cfg.eps) AS actual_share
    FROM long c
    CROSS JOIN cfg
    JOIN long b ON b.basis = c.basis AND b.rating = c.rating AND b.quarter = cfg.baseline_quarter
),
scored AS (
    SELECT p.*, CAST((actual_share - expected_share) * ln(actual_share / expected_share) AS DECIMAL(24,18)) AS psi_component  -- DECIMAL: order-independent SUM
    FROM paired p
)
SELECT basis,
       quarter,
       (SELECT baseline_quarter FROM cfg)                                AS baseline_quarter,
       rating,
       notch,
       expected_share,
       actual_share,
       psi_component,
       SUM(psi_component) OVER (PARTITION BY basis, quarter)             AS psi_total,
       CASE WHEN SUM(psi_component) OVER (PARTITION BY basis, quarter) <  (SELECT psi_amber FROM cfg) THEN 'GREEN'
            WHEN SUM(psi_component) OVER (PARTITION BY basis, quarter) <= (SELECT psi_red   FROM cfg) THEN 'AMBER'
            ELSE 'RED' END                                               AS psi_band
FROM scored
ORDER BY basis, q_index, notch;
