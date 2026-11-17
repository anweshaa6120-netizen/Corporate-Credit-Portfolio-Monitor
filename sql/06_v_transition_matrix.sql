-- =============================================================================
-- v_transition_matrix  (+ table macro transition_matrix(from_quarter, to_quarter))
-- -----------------------------------------------------------------------------
-- Purpose     : Empirical rating migration matrix between any two quarters:
--               rows = rating at from_quarter, columns = rating at to_quarter,
--               cell = share of the row's obligors that ended in that rating.
--               Placed beside the S&P long-run annual probability for
--               model-validation style comparison.
-- Inputs      : rating_obs, default_event, ref_rating_scale, ref_transition_matrix, config
--               (config keys: tm_from_quarter, tm_to_quarter -> used by the view only)
-- Output grain: one row per (from_rating, to_rating): 17 x 18 cells.
-- Usage       : SELECT * FROM transition_matrix('2023Q4', '2024Q4');   -- any window
--               SELECT * FROM v_transition_matrix;                     -- config window
-- Assumptions : * from_quarter < to_quarter. The macro does not check.
--               * Denominator = obligors performing (rated, not D) at from_quarter.
--                 An obligor with no rating at to_quarter but a default on or
--                 before it is counted as D: rating_obs records D only once,
--                 in the default quarter, and defaults are absorbing.
--               * prob is NULL (not 0) for a from_rating with no obligors, so
--                 an empty row cannot be mistaken for "nobody migrated".
--               * prob_longrun_annual is the S&P one-year probability, comparable
--                 only when the window is four quarters. For other windows it is
--                 shown for context, not as a like-for-like benchmark.
--               * With ~500 names most off-diagonal cells are 0 or 1/n; read
--                 the matrix for pattern, not for individual-cell precision.
-- =============================================================================
CREATE OR REPLACE MACRO transition_matrix(from_quarter, to_quarter) AS TABLE
WITH pairs AS (
    SELECT f.obligor_id,
           f.rating AS from_rating,
           COALESCE(t.rating,
                    CASE WHEN d.default_quarter <= to_quarter THEN 'D' END) AS to_rating
    FROM rating_obs f
    LEFT JOIN rating_obs t     ON t.obligor_id = f.obligor_id AND t.quarter = to_quarter
    LEFT JOIN default_event d  ON d.obligor_id = f.obligor_id
    WHERE f.quarter = from_quarter
      AND f.rating <> 'D'
),
counts AS (
    SELECT from_rating, to_rating, COUNT(*) AS n
    FROM pairs
    WHERE to_rating IS NOT NULL
    GROUP BY from_rating, to_rating
),
grid AS (
    SELECT a.rating AS from_rating, a.notch AS from_notch,
           b.rating AS to_rating,   b.notch AS to_notch
    FROM ref_rating_scale a CROSS JOIN ref_rating_scale b
    WHERE a.rating <> 'D'
),
cells AS (
    SELECT g.*, COALESCE(c.n, 0) AS n_obligors,
           SUM(COALESCE(c.n, 0)) OVER (PARTITION BY g.from_rating) AS n_from
    FROM grid g
    LEFT JOIN counts c ON c.from_rating = g.from_rating AND c.to_rating = g.to_rating
)
SELECT from_quarter                             AS from_quarter,
       to_quarter                               AS to_quarter,
       c.from_rating, c.from_notch,
       c.to_rating,   c.to_notch,
       c.n_obligors,
       c.n_from                                 AS n_obligors_in_row,
       CASE WHEN c.n_from = 0 THEN NULL ELSE c.n_obligors * 1.0 / c.n_from END AS prob,
       r.prob                                   AS prob_longrun_annual
FROM cells c
LEFT JOIN ref_transition_matrix r
       ON r.from_rating = c.from_rating AND r.to_rating = c.to_rating
ORDER BY c.from_notch, c.to_notch;

CREATE OR REPLACE VIEW v_transition_matrix AS
SELECT *
FROM transition_matrix(
    (SELECT value_txt FROM config WHERE key = 'tm_from_quarter'),
    (SELECT value_txt FROM config WHERE key = 'tm_to_quarter'));
