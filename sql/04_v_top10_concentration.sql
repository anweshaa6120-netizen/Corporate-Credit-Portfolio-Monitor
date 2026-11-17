-- =============================================================================
-- v_top10_concentration
-- -----------------------------------------------------------------------------
-- Purpose     : Largest single-name exposures by EAD per quarter, with each
--               name's share and the cumulative share of the top-N.
-- Inputs      : facility_snapshot, obligor, rating_obs, config
--               (config keys: ccf_undrawn, top_n)
-- Output grain: one row per (quarter, rank) for rank 1..top_n.
-- Assumptions : * Single name = obligor_id; there is no parent/group hierarchy,
--                 so connected-counterparty aggregation is out of scope.
--               * Ties on EAD break on obligor_id so output is deterministic.
--               * top10_share (cumulative share at rank = top_n) is the KPI used
--                 in the report; the view name keeps "top10" though N is config.
-- =============================================================================
CREATE OR REPLACE VIEW v_top10_concentration AS
WITH cfg AS (
    SELECT CAST(MAX(value_num) FILTER (WHERE key = 'ccf_undrawn') AS DECIMAL(9,4)) AS ccf,
           MAX(value_num) FILTER (WHERE key = 'top_n')       AS top_n
    FROM config
),
obligor_q AS (
    SELECT s.quarter, s.obligor_id,
           SUM(s.drawn + cfg.ccf * (s.committed - s.drawn)) AS ead
    FROM facility_snapshot s CROSS JOIN cfg
    GROUP BY s.quarter, s.obligor_id
),
ranked AS (
    SELECT quarter, obligor_id, ead,
           ROW_NUMBER() OVER (PARTITION BY quarter ORDER BY ead DESC, obligor_id) AS rnk,
           ead / SUM(ead) OVER (PARTITION BY quarter)                              AS share_ead
    FROM obligor_q
)
SELECT r.quarter,
       q.q_index,
       r.rnk                                                       AS rank,
       r.obligor_id,
       b.obligor_name,
       b.sector,
       o.rating,
       ROUND(r.ead, 2)                                             AS ead_usd_mn,
       r.share_ead,
       SUM(r.share_ead) OVER (PARTITION BY r.quarter ORDER BY r.rnk) AS cumulative_share_ead
FROM ranked r
CROSS JOIN cfg
JOIN ref_quarter q ON q.quarter = r.quarter
JOIN obligor b     ON b.obligor_id = r.obligor_id
JOIN rating_obs o  ON o.obligor_id = r.obligor_id AND o.quarter = r.quarter
WHERE r.rnk <= cfg.top_n
ORDER BY q.q_index, r.rnk;
