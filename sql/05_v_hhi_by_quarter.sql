-- =============================================================================
-- v_hhi_by_quarter
-- -----------------------------------------------------------------------------
-- Purpose     : Sector concentration of the book measured by the
--               Herfindahl-Hirschman Index on EAD shares.
-- Inputs      : facility_snapshot, obligor, config
--               (config keys: ccf_undrawn, hhi_moderate, hhi_high)
-- Output grain: one row per quarter.
-- Assumptions : * HHI = sum over sectors of share_ead^2, on a 0-1 scale
--                 (multiply by 10,000 for the conventional scale; given as hhi_10k).
--                 Minimum possible with 10 sectors is 0.10.
--               * effective_n_sectors = 1 / HHI: the number of equal-sized
--                 sectors that would give the same concentration -- easier to
--                 communicate than the raw index.
--               * Band thresholds are set in config. They are adapted from the
--                 DoJ/FTC market-concentration convention (0.15 / 0.25); there
--                 is no regulatory sector-HHI limit, so treat bands as
--                 internal triggers.
-- =============================================================================
CREATE OR REPLACE VIEW v_hhi_by_quarter AS
WITH cfg AS (
    SELECT CAST(MAX(value_num) FILTER (WHERE key = 'ccf_undrawn') AS DECIMAL(9,4))   AS ccf,
           MAX(value_num) FILTER (WHERE key = 'hhi_moderate')  AS hhi_moderate,
           MAX(value_num) FILTER (WHERE key = 'hhi_high')      AS hhi_high
    FROM config
),
sector_ead AS (
    SELECT s.quarter, b.sector,
           SUM(s.drawn + cfg.ccf * (s.committed - s.drawn)) AS ead
    FROM facility_snapshot s
    CROSS JOIN cfg
    JOIN obligor b ON b.obligor_id = s.obligor_id
    GROUP BY s.quarter, b.sector
),
shares AS (
    SELECT quarter, sector, ead / SUM(ead) OVER (PARTITION BY quarter) AS share_ead
    FROM sector_ead
),
agg AS (
    SELECT quarter,
           SUM(CAST(share_ead * share_ead AS DECIMAL(24,18))) AS hhi,   -- DECIMAL: order-independent sum
           MAX(share_ead)                    AS largest_sector_share,
           arg_max(sector, share_ead)        AS largest_sector
    FROM shares
    GROUP BY quarter
)
SELECT q.quarter,
       q.q_index,
       a.hhi,
       a.hhi * 10000                         AS hhi_10k,
       1.0 / a.hhi                           AS effective_n_sectors,
       a.largest_sector,
       a.largest_sector_share,
       CASE WHEN a.hhi >  cfg.hhi_high     THEN 'HIGH'
            WHEN a.hhi >= cfg.hhi_moderate THEN 'MODERATE'
            ELSE 'LOW' END                   AS concentration_band
FROM agg a
CROSS JOIN cfg
JOIN ref_quarter q ON q.quarter = a.quarter
ORDER BY q.q_index;
