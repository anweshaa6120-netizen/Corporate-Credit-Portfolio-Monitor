-- =============================================================================
-- 00_checks_base_tables  (sanity checks, not a view)
-- -----------------------------------------------------------------------------
-- Purpose     : Fail fast if the seeded data is structurally wrong, before any
--               view is built on top of it.
-- Inputs      : all base tables
-- Output grain: one row per check: (check_name, 'ok'). A failed check raises
--               an error() and aborts the run.
-- Assumptions : Bounds are deliberately loose -- they catch broken generation
--               (empty tables, impossible values), not statistical drift.
-- =============================================================================
SELECT check_name, status FROM (
    SELECT 'obligor count within 450-550' AS check_name,
           CASE WHEN (SELECT COUNT(*) FROM obligor) BETWEEN 450 AND 550 THEN 'ok' ELSE error('obligor count out of range') END AS status
    UNION ALL
    SELECT '10 sectors in use',
           CASE WHEN (SELECT COUNT(DISTINCT sector) FROM obligor) = 10 THEN 'ok' ELSE error('expected 10 sectors') END
    UNION ALL
    SELECT '20 quarters, 2021Q1..2025Q4',
           CASE WHEN (SELECT COUNT(*) FROM ref_quarter) = 20
                 AND (SELECT MIN(quarter) FROM ref_quarter) = '2021Q1'
                 AND (SELECT MAX(quarter) FROM ref_quarter) = '2025Q4' THEN 'ok' ELSE error('quarter calendar wrong') END
    UNION ALL
    SELECT '18-state rating scale (17 + D)',
           CASE WHEN (SELECT COUNT(*) FROM ref_rating_scale) = 18 THEN 'ok' ELSE error('rating scale size') END
    UNION ALL
    SELECT 'every obligor has a rating in its first quarter',
           CASE WHEN (SELECT COUNT(*) FROM obligor o WHERE NOT EXISTS
                        (SELECT 1 FROM rating_obs r WHERE r.obligor_id = o.obligor_id AND r.quarter = o.origination_quarter)) = 0
                THEN 'ok' ELSE error('obligor without origination rating') END
    UNION ALL
    SELECT 'drawn between 0 and committed',
           CASE WHEN (SELECT COUNT(*) FROM facility_snapshot WHERE drawn < 0 OR drawn > committed) = 0
                THEN 'ok' ELSE error('drawn outside [0, committed]') END
    UNION ALL
    SELECT 'published matrix rows sum to 100 +/- 0.1',
           CASE WHEN (SELECT COUNT(*) FROM (SELECT from_rating, SUM(pct) s FROM ref_transition_published GROUP BY 1) WHERE ABS(s - 100) > 0.1) = 0
                THEN 'ok' ELSE error('published matrix row does not sum to 100') END
    UNION ALL
    SELECT 'NR-adjusted matrix rows sum to 1',
           CASE WHEN (SELECT COUNT(*) FROM (SELECT from_rating, SUM(prob) s FROM ref_transition_matrix GROUP BY 1) WHERE ABS(s - 1) > 1e-9) = 0
                THEN 'ok' ELSE error('adjusted matrix row does not sum to 1') END
    UNION ALL
    SELECT 'PD non-decreasing from AA- down to CCC/C',
           CASE WHEN (SELECT COUNT(*) FROM ref_pd a JOIN ref_rating_scale sa ON sa.rating = a.rating
                        JOIN ref_pd b ON TRUE JOIN ref_rating_scale sb ON sb.rating = b.rating
                        WHERE sb.notch = sa.notch + 1 AND sa.notch >= 4 AND b.pd_nr_adjusted < a.pd_nr_adjusted) = 0
                THEN 'ok' ELSE error('PD not monotone in rating') END
    UNION ALL
    SELECT 'PDs within [0, 1]',
           CASE WHEN (SELECT COUNT(*) FROM ref_pd WHERE pd_nr_adjusted < 0 OR pd_nr_adjusted > 1) = 0
                THEN 'ok' ELSE error('PD outside [0,1]') END
    UNION ALL
    SELECT 'default_event matches rating_obs D rows 1:1',
           CASE WHEN (SELECT COUNT(*) FROM default_event) = (SELECT COUNT(*) FROM rating_obs WHERE rating = 'D')
                 AND (SELECT COUNT(*) FROM default_event d JOIN rating_obs r
                        ON r.obligor_id = d.obligor_id AND r.quarter = d.default_quarter AND r.rating = 'D') = (SELECT COUNT(*) FROM default_event)
                THEN 'ok' ELSE error('default_event and rating_obs disagree') END
    UNION ALL
    SELECT 'no snapshots after default',
           CASE WHEN (SELECT COUNT(*) FROM facility_snapshot s JOIN default_event d ON d.obligor_id = s.obligor_id
                        WHERE s.quarter >= d.default_quarter) = 0
                THEN 'ok' ELSE error('exposure reported after default') END
    UNION ALL
    SELECT 'all config values present',
           CASE WHEN (SELECT COUNT(*) FROM config WHERE value_num IS NULL AND value_txt IS NULL) = 0
                 AND (SELECT COUNT(*) FROM config) >= 20 THEN 'ok' ELSE error('config incomplete') END
);
