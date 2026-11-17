-- =============================================================================
-- 99_checks_views  (sanity checks, not a view)
-- -----------------------------------------------------------------------------
-- Purpose     : Row-count and value-range checks on the views, run last.
-- Inputs      : every v_* view and the transition_matrix macro
-- Output grain: one row per check: (check_name, 'ok'). A failed check raises
--               an error() and aborts the run.
-- Assumptions : Checks are identities and ranges (shares sum to 1, PSI of the
--               baseline against itself is 0), not expected business outcomes.
-- =============================================================================
SELECT check_name, status FROM (
    SELECT 'exposure: 20 quarters, positive EAD' AS check_name,
           CASE WHEN (SELECT COUNT(*) FROM v_exposure_by_quarter) = 20
                 AND (SELECT MIN(ead_usd_mn) FROM v_exposure_by_quarter) > 0 THEN 'ok' ELSE error('exposure view') END AS status
    UNION ALL
    SELECT 'exposure: utilisation within [0, 1]',
           CASE WHEN (SELECT COUNT(*) FROM v_exposure_by_quarter WHERE utilisation < 0 OR utilisation > 1) = 0
                THEN 'ok' ELSE error('utilisation out of range') END
    UNION ALL
    SELECT 'exposure: EAD between drawn and committed',
           CASE WHEN (SELECT COUNT(*) FROM v_exposure_by_quarter WHERE ead_usd_mn < drawn_usd_mn - 0.01 OR ead_usd_mn > committed_usd_mn + 0.01) = 0
                THEN 'ok' ELSE error('EAD outside [drawn, committed]') END
    UNION ALL
    SELECT 'rating dist: 340 rows (20 x 17), shares sum to 1',
           CASE WHEN (SELECT COUNT(*) FROM v_rating_distribution_by_quarter) = 340
                 AND (SELECT COUNT(*) FROM (SELECT quarter, SUM(share_obligors) a, SUM(share_ead) b
                        FROM v_rating_distribution_by_quarter GROUP BY 1) WHERE ABS(a - 1) > 1e-9 OR ABS(b - 1) > 1e-9) = 0
                THEN 'ok' ELSE error('rating distribution') END
    UNION ALL
    SELECT 'sector dist: 200 rows (20 x 10), shares sum to 1',
           CASE WHEN (SELECT COUNT(*) FROM v_sector_distribution_by_quarter) = 200
                 AND (SELECT COUNT(*) FROM (SELECT quarter, SUM(share_obligors) a, SUM(share_ead) b
                        FROM v_sector_distribution_by_quarter GROUP BY 1) WHERE ABS(a - 1) > 1e-9 OR ABS(b - 1) > 1e-9) = 0
                THEN 'ok' ELSE error('sector distribution') END
    UNION ALL
    SELECT 'top-N: 10 ranks per quarter, cumulative share <= 1',
           CASE WHEN (SELECT COUNT(*) FROM v_top10_concentration) = 200
                 AND (SELECT MAX(cumulative_share_ead) FROM v_top10_concentration) <= 1 THEN 'ok' ELSE error('top-N view') END
    UNION ALL
    SELECT 'HHI: within [0.10, 1] (10 sectors)',
           CASE WHEN (SELECT COUNT(*) FROM v_hhi_by_quarter) = 20
                 AND (SELECT MIN(hhi) FROM v_hhi_by_quarter) >= 0.1 - 1e-9
                 AND (SELECT MAX(hhi) FROM v_hhi_by_quarter) <= 1 THEN 'ok' ELSE error('HHI out of range') END
    UNION ALL
    SELECT 'transition: 17 x 18 cells, populated rows sum to 1',
           CASE WHEN (SELECT COUNT(*) FROM v_transition_matrix) = 306
                 AND (SELECT COUNT(*) FROM (SELECT from_rating, SUM(prob) s FROM v_transition_matrix GROUP BY 1)
                        WHERE s IS NOT NULL AND ABS(s - 1) > 1e-9) = 0 THEN 'ok' ELSE error('transition matrix') END
    UNION ALL
    SELECT 'transition: macro window is parameterised',
           CASE WHEN (SELECT COUNT(DISTINCT from_quarter || to_quarter) FROM transition_matrix('2021Q1', '2021Q2')) = 1
                 AND (SELECT SUM(n_obligors) FROM transition_matrix('2021Q1', '2021Q2')) > 0 THEN 'ok' ELSE error('macro') END
    UNION ALL
    SELECT 'backtest: 112 rows (16 cohorts x 7 buckets), p in [0,1]',
           CASE WHEN (SELECT COUNT(*) FROM v_pd_backtest) = 112
                 AND (SELECT COUNT(*) FROM v_pd_backtest WHERE p_value_one_sided < 0 OR p_value_one_sided > 1) = 0 THEN 'ok' ELSE error('backtest') END
    UNION ALL
    SELECT 'backtest: defaults reconcile to default_event',
           CASE WHEN (SELECT SUM(realised_defaults) FROM v_pd_backtest WHERE cohort_quarter = '2021Q1')
                   = (SELECT COUNT(*) FROM default_event d JOIN rating_obs r ON r.obligor_id = d.obligor_id AND r.quarter = '2021Q1'
                        WHERE d.default_quarter IN ('2021Q2','2021Q3','2021Q4','2022Q1'))
                THEN 'ok' ELSE error('backtest defaults do not reconcile') END
    UNION ALL
    SELECT 'PSI: baseline vs itself is 0, all PSI >= 0',
           CASE WHEN (SELECT MAX(ABS(psi_total)) FROM v_psi_rating WHERE quarter = baseline_quarter) < 1e-9
                 AND (SELECT MAX(ABS(psi_total)) FROM v_psi_sector WHERE quarter = baseline_quarter) < 1e-9
                 AND (SELECT MIN(psi_total) FROM v_psi_rating) >= 0
                 AND (SELECT MIN(psi_total) FROM v_psi_sector) >= 0
                 AND (SELECT COUNT(*) FROM v_psi_rating) = 680 AND (SELECT COUNT(*) FROM v_psi_sector) = 400
                THEN 'ok' ELSE error('PSI sanity') END
    UNION ALL
    SELECT 'watchlist: unique obligors, >= 1 flag each',
           CASE WHEN (SELECT COUNT(*) FROM v_watchlist) = (SELECT COUNT(DISTINCT obligor_id) FROM v_watchlist)
                 AND (SELECT COUNT(*) FROM v_watchlist WHERE n_flags < 1) = 0 THEN 'ok' ELSE error('watchlist') END
);
