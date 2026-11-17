# Corporate Credit Portfolio Monitor

A SQL-first monitoring pack for a corporate loan book, built the way a credit-risk modelling team would run it each quarter: exposure and concentration, rating migration, PD back-testing against long-run S&P default rates, population stability (PSI), and an early-warning watchlist. A synthetic book of 500 obligors, 10 sectors and 20 quarters (2021Q1 to 2025Q4) lives in a single DuckDB file. Every analytic is a SQL view with its inputs, grain and assumptions documented in the file header, and every threshold comes from a config table. Python only seeds the data and plots the results.

**Intended audience:** a credit-risk modelling and analytics team (corporate and investment banking), as a worked example of portfolio monitoring and model-performance reporting.

## Run it

```
make seed     # generate the loan book into data/portfolio.duckdb (seed 42)
make views    # create all SQL views and run the sanity checks
make report   # execute report.ipynb headless -> reports/report.html
make all      # all of the above
make clean    # remove generated data and reports
```

`make` creates a local `.venv` and installs the pinned `requirements.txt` on first use. Tested on Python 3.14 (macOS, arm64). No Docker, no external services.

To explore interactively, open `report.ipynb`, or query the database directly:

```python
import duckdb
con = duckdb.connect("data/portfolio.duckdb", read_only=True)
con.sql("SELECT * FROM transition_matrix('2022Q4', '2023Q4')")   # any window
```

## Folder layout

```
seed.py               synthetic data, S&P matrix and PDs, config table
apply_views.py        runs sql/*.sql in order (thin)
sql/
  00_checks_base_tables.sql      sanity checks on seeded data
  01_v_exposure_by_quarter.sql   EAD, utilisation, expected loss
  02_v_rating_distribution_by_quarter.sql
  03_v_sector_distribution_by_quarter.sql
  04_v_top10_concentration.sql   single-name, by EAD
  05_v_hhi_by_quarter.sql        sector HHI
  06_v_transition_matrix.sql     macro transition_matrix(from, to) + default view
  07_v_pd_backtest.sql           expected vs realised, exact binomial test
  08_v_psi_rating.sql            PSI vs baseline quarter
  09_v_psi_sector.sql
  10_v_watchlist.sql
  99_checks_views.sql            sanity checks on view outputs
report.ipynb          queries the views and plots; no analytics
METHODOLOGY.md        assumptions, sources, formulas, limitations
```

## Design notes

- **No magic numbers in SQL.** PSI bands, baseline quarter, watchlist rules, CCF, LGD and the PD floor all live in the `config` table.
- **Each view runs on its own** against the base tables; none depends on another view.
- **Deterministic.** Same seed gives bit-identical tables and view outputs. Money is stored as `DECIMAL` so sums do not depend on parallel execution order.
- **Sources.** Transition matrix and PDs are S&P Global Ratings' 1981-2020 global corporate averages (citation in `seed.py` and `METHODOLOGY.md`).

The data is synthetic and the monitor is only validated against the stress episodes injected into it. See `METHODOLOGY.md`, section 8, for what that does and does not show.
