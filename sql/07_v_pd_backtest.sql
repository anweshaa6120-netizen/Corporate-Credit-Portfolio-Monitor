-- =============================================================================
-- v_pd_backtest
-- -----------------------------------------------------------------------------
-- Purpose     : Back-test rating-implied PDs: expected vs realised default rate
--               per rating bucket, per cohort quarter, with a one-sided
--               binomial test for under-prediction.
-- Inputs      : rating_obs, default_event, ref_pd, ref_rating_scale, ref_quarter, config
--               (config keys: backtest_horizon_q, backtest_alpha, pd_floor)
-- Output grain: one row per (cohort_quarter, bucket) for cohorts with a full
--               forward window: 16 cohorts x 7 buckets (AAA .. CCC/C).
-- Method      : Cohort = obligors performing (rated, not D) at cohort_quarter.
--               Realised = those that default in the next H quarters
--               (H = backtest_horizon_q = 4, so the window matches a one-year PD).
--               Expected = mean of the cohort's rating-implied PDs.
--               Test    : H0 realised defaults ~ Binomial(n, p_bar), p_bar = expected
--                         rate. p_value = P(X >= k) = sum_{i=k..n} C(n,i) p^i (1-p)^(n-i),
--                         evaluated exactly with lgamma (no normal approximation).
--                         Small p_value => PDs are too low (under-prediction).
-- Assumptions : * Using the bucket-mean PD for a binomial treats notches within
--                 a bucket as homogeneous; that slightly overstates variance
--                 relative to a Poisson-binomial, so the test is mildly conservative.
--               * Cohorts are overlapping (same obligor sits in up to 4 cohorts),
--                 so p-values across rows are NOT independent -- do not multiply
--                 or Bonferroni them as if they were.
--               * low_power = TRUE when expected defaults < 1: the test cannot
--                 reject even if every PD is wrong, so a pass is uninformative.
--               * Defaults are cohort-based on a rating at the start of the window;
--                 obligors that migrate before defaulting stay in their start bucket.
-- =============================================================================
CREATE OR REPLACE VIEW v_pd_backtest AS
WITH cfg AS (
    SELECT CAST(MAX(value_num) FILTER (WHERE key = 'backtest_horizon_q') AS INTEGER) AS horizon,
           MAX(value_num) FILTER (WHERE key = 'backtest_alpha')                       AS alpha,
           MAX(value_num) FILTER (WHERE key = 'pd_floor')                             AS pd_floor
    FROM config
),
cohort AS (
    SELECT q.quarter AS cohort_quarter, q.q_index, s.bucket, r.obligor_id,
           CAST(GREATEST(p.pd_nr_adjusted, cfg.pd_floor) AS DECIMAL(18,12)) AS pd,   -- DECIMAL: order-independent SUM/AVG
           CASE WHEN dq.q_index > q.q_index AND dq.q_index <= q.q_index + cfg.horizon
                THEN 1 ELSE 0 END                   AS defaulted
    FROM rating_obs r
    CROSS JOIN cfg
    JOIN ref_quarter q       ON q.quarter = r.quarter
    JOIN ref_rating_scale s  ON s.rating = r.rating
    JOIN ref_pd p            ON p.rating = r.rating
    LEFT JOIN default_event d ON d.obligor_id = r.obligor_id
    LEFT JOIN ref_quarter dq  ON dq.quarter = d.default_quarter
    WHERE r.rating <> 'D'
      AND q.q_index + cfg.horizon <= (SELECT MAX(q_index) FROM ref_quarter)   -- full forward window only
),
agg AS (
    SELECT cohort_quarter, q_index, bucket,
           COUNT(*)      AS n_obligors,
           AVG(pd)       AS expected_pd,
           SUM(pd)       AS expected_defaults,
           SUM(defaulted) AS realised_defaults
    FROM cohort
    GROUP BY cohort_quarter, q_index, bucket
),
grid AS (                                    -- every bucket in every cohort, even when empty
    SELECT DISTINCT c.cohort_quarter, c.q_index, s.bucket, s.notch_min
    FROM (SELECT DISTINCT cohort_quarter, q_index FROM agg) c
    CROSS JOIN (SELECT bucket, MIN(notch) AS notch_min FROM ref_rating_scale WHERE bucket <> 'D' GROUP BY bucket) s
),
joined AS (
    SELECT g.cohort_quarter, g.q_index, g.bucket, g.notch_min,
           COALESCE(a.n_obligors, 0)       AS n_obligors,
           a.expected_pd,
           COALESCE(a.expected_defaults, 0) AS expected_defaults,
           COALESCE(a.realised_defaults, 0) AS realised_defaults
    FROM grid g
    LEFT JOIN agg a ON a.cohort_quarter = g.cohort_quarter AND a.bucket = g.bucket
)
SELECT j.cohort_quarter,
       j.bucket,
       j.n_obligors,
       j.expected_pd,
       j.realised_defaults / NULLIF(j.n_obligors, 0)           AS realised_default_rate,
       ROUND(j.expected_defaults, 3)                           AS expected_defaults,
       CAST(j.realised_defaults AS INTEGER)                    AS realised_defaults,
       (j.realised_defaults / NULLIF(j.n_obligors, 0)) / j.expected_pd AS realised_to_expected,
       CASE WHEN j.n_obligors = 0 THEN NULL
            WHEN j.realised_defaults = 0 THEN 1.0
            ELSE LEAST(1.0, t.tail) END                        AS p_value_one_sided,
       CASE WHEN j.n_obligors = 0 THEN NULL
            ELSE j.expected_defaults < 1 END                   AS low_power,
       CASE WHEN j.n_obligors = 0 THEN 'NO_DATA'
            WHEN j.realised_defaults > 0 AND t.tail < cfg.alpha THEN 'UNDER_PREDICTED'
            ELSE 'PASS' END                                    AS test_result
FROM joined j
CROSS JOIN cfg
LEFT JOIN LATERAL (
    SELECT SUM(exp(lgamma(j.n_obligors + 1) - lgamma(i + 1) - lgamma(j.n_obligors - i + 1)
                   + i * ln(j.expected_pd) + (j.n_obligors - i) * ln(1 - j.expected_pd))) AS tail
    FROM (SELECT unnest(generate_series(CAST(j.realised_defaults AS BIGINT), CAST(j.n_obligors AS BIGINT))) AS i)
) t ON TRUE
ORDER BY j.q_index, j.notch_min;
