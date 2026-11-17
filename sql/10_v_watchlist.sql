-- =============================================================================
-- v_watchlist
-- -----------------------------------------------------------------------------
-- Purpose     : Early-warning list of performing obligors at the as-of quarter
--               that trip at least one rule:
--                 R1  downgrade of >= wl_downgrade_notches within the last
--                     wl_downgrade_window_q quarters;
--                 R2  utilisation up by more than wl_util_increase (absolute,
--                     0.25 = 25pp) versus the previous quarter;
--                 R3  the obligor's sector has a realised default rate above
--                     wl_sector_ratio x its expected rate over the last
--                     wl_sector_lookback_q quarters.
-- Inputs      : obligor, rating_obs, ref_rating_scale, facility_snapshot,
--               default_event, ref_pd, ref_quarter, config
--               (config keys: asof_quarter, wl_*, ccf_undrawn, pd_floor)
-- Output grain: one row per flagged obligor at asof_quarter.
-- Assumptions : * R1 needs a rating at both ends of the window; an obligor
--                 originated inside the window cannot trip it.
--               * R2 uses obligor-level utilisation = sum(drawn) / sum(committed)
--                 across facilities, so term loans (always ~fully drawn) dilute
--                 revolver drawdowns. Needs a snapshot in both quarters.
--               * R3 is a sector-level signal applied to every name in the sector,
--                 so it is blunt: it says "look here", not "this name is weak".
--                 Expected rate = mean long-run PD of the sector's performing
--                 names at the start of the look-back. A guard
--                 (wl_sector_min_defaults) stops one default in a small sector
--                 from tripping the ratio; this guard is an addition to the
--                 stated rule and is configurable.
--               * n_flags orders the list: names tripping several rules first,
--                 then by EAD.
-- =============================================================================
CREATE OR REPLACE VIEW v_watchlist AS
WITH cfg AS (
    SELECT MAX(value_txt) FILTER (WHERE key = 'asof_quarter')                         AS asof_quarter,
           CAST(MAX(value_num) FILTER (WHERE key = 'wl_downgrade_notches')  AS INTEGER) AS dg_notches,
           CAST(MAX(value_num) FILTER (WHERE key = 'wl_downgrade_window_q') AS INTEGER) AS dg_window,
           MAX(value_num) FILTER (WHERE key = 'wl_util_increase')                     AS util_increase,
           MAX(value_num) FILTER (WHERE key = 'wl_sector_ratio')                      AS sector_ratio,
           CAST(MAX(value_num) FILTER (WHERE key = 'wl_sector_lookback_q')  AS INTEGER) AS lookback,
           MAX(value_num) FILTER (WHERE key = 'wl_sector_min_defaults')               AS min_defaults,
           CAST(MAX(value_num) FILTER (WHERE key = 'ccf_undrawn') AS DECIMAL(9,4))                          AS ccf,
           MAX(value_num) FILTER (WHERE key = 'pd_floor')                             AS pd_floor
    FROM config
),
ctx AS (
    SELECT c.*, q.q_index AS asof_idx FROM cfg c JOIN ref_quarter q ON q.quarter = c.asof_quarter
),
now_book AS (                                     -- performing obligors at as-of, with rating and EAD
    SELECT r.obligor_id, r.rating AS rating_now, sc.notch AS notch_now
    FROM rating_obs r
    JOIN ctx a            ON r.quarter = a.asof_quarter
    JOIN ref_rating_scale sc ON sc.rating = r.rating
    WHERE r.rating <> 'D'
),
ead_now AS (
    SELECT s.obligor_id, SUM(s.drawn + a.ccf * (s.committed - s.drawn)) AS ead
    FROM facility_snapshot s JOIN ctx a ON s.quarter = a.asof_quarter
    GROUP BY s.obligor_id
),
rating_then AS (
    SELECT r.obligor_id, r.rating AS rating_then, sc.notch AS notch_then
    FROM rating_obs r
    JOIN ref_quarter q       ON q.quarter = r.quarter
    JOIN ctx a              ON q.q_index = a.asof_idx - a.dg_window
    JOIN ref_rating_scale sc ON sc.rating = r.rating
),
util AS (                                         -- obligor utilisation now vs previous quarter
    SELECT s.obligor_id,
           SUM(s.drawn) FILTER (WHERE q.q_index = a.asof_idx)     / SUM(s.committed) FILTER (WHERE q.q_index = a.asof_idx)     AS util_now,
           SUM(s.drawn) FILTER (WHERE q.q_index = a.asof_idx - 1) / SUM(s.committed) FILTER (WHERE q.q_index = a.asof_idx - 1) AS util_prev
    FROM facility_snapshot s
    JOIN ref_quarter q ON q.quarter = s.quarter
    CROSS JOIN ctx a
    WHERE q.q_index IN (a.asof_idx, a.asof_idx - 1)
    GROUP BY s.obligor_id
),
sector_cohort AS (                                -- performing at look-back start, did they default since?
    SELECT b.sector,
           COUNT(*)                                                     AS n_start,
           SUM(CAST(GREATEST(p.pd_nr_adjusted, a.pd_floor) AS DECIMAL(18,12))) AS expected_defaults,
           SUM(CASE WHEN dq.q_index > a.asof_idx - a.lookback AND dq.q_index <= a.asof_idx
                    THEN 1 ELSE 0 END)                                  AS realised_defaults
    FROM rating_obs r
    CROSS JOIN ctx a
    JOIN ref_quarter q         ON q.quarter = r.quarter AND q.q_index = a.asof_idx - a.lookback
    JOIN obligor b             ON b.obligor_id = r.obligor_id
    JOIN ref_pd p              ON p.rating = r.rating
    LEFT JOIN default_event d  ON d.obligor_id = r.obligor_id
    LEFT JOIN ref_quarter dq   ON dq.quarter = d.default_quarter
    WHERE r.rating <> 'D'
    GROUP BY b.sector
),
sector_flag AS (
    SELECT sc.sector,
           sc.realised_defaults * 1.0 / sc.n_start   AS sector_realised_rate,
           sc.expected_defaults / sc.n_start         AS sector_expected_rate,
           (sc.realised_defaults * 1.0 / sc.n_start) / (sc.expected_defaults / sc.n_start) AS sector_ratio,
           sc.realised_defaults >= a.min_defaults
             AND (sc.realised_defaults * 1.0 / sc.n_start) / (sc.expected_defaults / sc.n_start) > a.sector_ratio AS flag_sector
    FROM sector_cohort sc CROSS JOIN ctx a
),
flagged AS (
    SELECT n.obligor_id, b.obligor_name, b.sector,
           n.rating_now, t.rating_then,
           n.notch_now - t.notch_then                      AS notches_downgraded,
           u.util_prev, u.util_now,
           u.util_now - u.util_prev                        AS util_change,
           sf.sector_realised_rate, sf.sector_expected_rate, sf.sector_ratio,
           COALESCE(n.notch_now - t.notch_then >= a.dg_notches, FALSE)  AS flag_downgrade,
           COALESCE(u.util_now - u.util_prev > a.util_increase, FALSE)  AS flag_utilisation,
           COALESCE(sf.flag_sector, FALSE)                              AS flag_sector,
           e.ead
    FROM now_book n
    CROSS JOIN ctx a
    JOIN obligor b            ON b.obligor_id = n.obligor_id
    LEFT JOIN rating_then t   ON t.obligor_id = n.obligor_id
    LEFT JOIN util u          ON u.obligor_id = n.obligor_id
    LEFT JOIN sector_flag sf  ON sf.sector = b.sector
    LEFT JOIN ead_now e       ON e.obligor_id = n.obligor_id
)
SELECT (SELECT asof_quarter FROM cfg)                             AS asof_quarter,
       obligor_id, obligor_name, sector,
       rating_then, rating_now, notches_downgraded,
       util_prev, util_now, util_change,
       sector_realised_rate, sector_expected_rate, sector_ratio,
       flag_downgrade, flag_utilisation, flag_sector,
       CAST(flag_downgrade AS INTEGER) + CAST(flag_utilisation AS INTEGER) + CAST(flag_sector AS INTEGER) AS n_flags,
       array_to_string(list_filter([
           CASE WHEN flag_downgrade   THEN 'R1 downgrade' END,
           CASE WHEN flag_utilisation THEN 'R2 utilisation' END,
           CASE WHEN flag_sector      THEN 'R3 sector' END], x -> x IS NOT NULL), ', ') AS reasons,
       ROUND(ead, 2)                                              AS ead_usd_mn
FROM flagged
WHERE flag_downgrade OR flag_utilisation OR flag_sector
ORDER BY n_flags DESC, ead DESC, obligor_id;
