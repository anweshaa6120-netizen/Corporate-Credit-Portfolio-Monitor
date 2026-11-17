"""Seed a synthetic corporate loan book into DuckDB.

Python is used here only to *generate data*. Every analytic (exposure, HHI, PSI,
back-testing, watchlist) lives in sql/. Anything that looks like a policy
threshold is written to the `config` table so the SQL never carries magic numbers.

Run:  python seed.py [--db data/portfolio.duckdb] [--seed 42]
"""
from __future__ import annotations

import argparse
from pathlib import Path

import duckdb
import numpy as np
import pandas as pd

DEFAULT_SEED = 42
DEFAULT_DB = Path(__file__).parent / "data" / "portfolio.duckdb"

N_OBLIGORS = 500
N_AT_START = 400            # remainder originate during 2021Q2..2024Q4 so the book is not static
YEARS = range(2021, 2026)
N_Q = 20                    # 2021Q1 .. 2025Q4

# ---------------------------------------------------------------------------
# Rating scale
# ---------------------------------------------------------------------------
# 17 performing notches + D = 18 states. S&P publishes CCC/CC/C as a single
# 'CCC/C' bucket in its transition tables, so a finer scale would have no
# published matrix behind it.
RATINGS = ["AAA", "AA+", "AA", "AA-", "A+", "A", "A-", "BBB+", "BBB", "BBB-",
           "BB+", "BB", "BB-", "B+", "B", "B-", "CCC/C"]
STATES = RATINGS + ["D"]
D_IDX = len(RATINGS)


def bucket_of(rating: str) -> str:
    if rating == "D":
        return "D"
    if rating == "CCC/C":
        return "CCC/C"
    return rating.rstrip("+-")


# ---------------------------------------------------------------------------
# Published S&P long-run average one-year transition matrix
# ---------------------------------------------------------------------------
# Source: S&P Global Ratings, "Default, Transition, and Recovery: 2020 Annual
# Global Corporate Default And Rating Transition Study" (7 April 2021),
# Table 23 "Average One-Year Transition Rates For Global Corporates By Rating
# Modifier (1981-2020) (%)", pp. 54-55. Sources cited there: S&P Global Ratings
# Research and S&P Global Market Intelligence's CreditPro.
# Columns: the 17 ratings above, then D, then NR (rating withdrawn). Percent.
# Rows sum to 100 +/- 0.04 because S&P rounds each cell.
# Vintage note: the 2020 study is used because it is the edition whose full
# table could be retrieved and checked cell-by-cell; later editions move cells
# by a few bp and do not change the method.
SP_ONE_YEAR_PCT = {
    "AAA":   [87.06, 5.88, 2.50, 0.69, 0.16, 0.24, 0.13, 0.00, 0.05, 0.00, 0.03, 0.05, 0.03, 0.00, 0.03, 0.00, 0.05, 0.00, 3.11],
    "AA+":   [2.26, 79.28, 10.77, 3.45, 0.69, 0.32, 0.18, 0.05, 0.09, 0.05, 0.00, 0.00, 0.00, 0.00, 0.00, 0.00, 0.00, 0.00, 2.85],
    "AA":    [0.42, 1.29, 80.91, 8.45, 2.67, 1.13, 0.35, 0.38, 0.13, 0.08, 0.05, 0.03, 0.02, 0.02, 0.00, 0.02, 0.05, 0.02, 3.99],
    "AA-":   [0.04, 0.10, 3.67, 78.89, 9.77, 2.21, 0.59, 0.25, 0.14, 0.07, 0.03, 0.00, 0.00, 0.03, 0.08, 0.00, 0.00, 0.03, 4.10],
    "A+":    [0.00, 0.06, 0.42, 4.30, 78.77, 8.67, 2.09, 0.59, 0.33, 0.08, 0.06, 0.08, 0.01, 0.07, 0.03, 0.00, 0.00, 0.05, 4.39],
    "A":     [0.03, 0.04, 0.21, 0.40, 5.16, 79.16, 6.70, 2.38, 0.84, 0.26, 0.09, 0.10, 0.06, 0.08, 0.02, 0.00, 0.01, 0.05, 4.41],
    "A-":    [0.04, 0.01, 0.06, 0.14, 0.40, 6.26, 78.58, 7.24, 1.90, 0.56, 0.13, 0.13, 0.11, 0.10, 0.03, 0.01, 0.03, 0.06, 4.24],
    "BBB+":  [0.00, 0.01, 0.05, 0.06, 0.19, 0.72, 6.85, 76.09, 8.22, 1.56, 0.34, 0.28, 0.12, 0.14, 0.09, 0.02, 0.06, 0.09, 5.10],
    "BBB":   [0.01, 0.01, 0.05, 0.03, 0.10, 0.29, 0.96, 7.45, 76.18, 6.30, 1.34, 0.64, 0.27, 0.21, 0.10, 0.03, 0.05, 0.15, 5.82],
    "BBB-":  [0.01, 0.01, 0.02, 0.04, 0.06, 0.13, 0.24, 1.13, 9.04, 72.61, 5.62, 2.05, 0.84, 0.37, 0.22, 0.15, 0.20, 0.24, 7.01],
    "BB+":   [0.04, 0.00, 0.00, 0.03, 0.03, 0.08, 0.08, 0.39, 1.53, 10.88, 65.43, 7.88, 2.66, 1.00, 0.53, 0.23, 0.35, 0.32, 8.58],
    "BB":    [0.00, 0.00, 0.03, 0.01, 0.00, 0.05, 0.04, 0.15, 0.45, 1.92, 9.29, 65.22, 8.81, 2.38, 1.06, 0.36, 0.50, 0.48, 9.22],
    "BB-":   [0.00, 0.00, 0.00, 0.01, 0.01, 0.01, 0.04, 0.09, 0.22, 0.33, 1.65, 9.32, 63.62, 8.76, 3.07, 0.81, 0.73, 0.96, 10.37],
    "B+":    [0.00, 0.01, 0.00, 0.03, 0.00, 0.03, 0.06, 0.04, 0.05, 0.10, 0.30, 1.38, 8.00, 62.48, 9.60, 2.64, 1.83, 1.98, 11.48],
    "B":     [0.00, 0.00, 0.01, 0.01, 0.00, 0.03, 0.04, 0.01, 0.05, 0.03, 0.10, 0.21, 1.03, 7.11, 61.38, 10.24, 4.10, 3.13, 12.52],
    "B-":    [0.00, 0.00, 0.00, 0.00, 0.01, 0.03, 0.00, 0.06, 0.06, 0.09, 0.07, 0.13, 0.42, 1.99, 9.36, 54.59, 13.04, 6.52, 13.63],
    "CCC/C": [0.00, 0.00, 0.00, 0.00, 0.02, 0.00, 0.07, 0.05, 0.07, 0.05, 0.02, 0.15, 0.37, 0.92, 2.42, 9.12, 43.11, 28.30, 15.31],
}

# ---------------------------------------------------------------------------
# Rating-implied one-year PDs
# ---------------------------------------------------------------------------
# Source: same study and table as above -- the 'D' column of Table 23 is the
# published long-run average one-year default rate per rating notch (%).
# Cross-check: Table 24 "Global Corporate Average Cumulative Default Rates
# (1981-2020)", 1-year column, gives AAA 0.00, AA 0.02, A 0.05, BBB 0.16,
# BB 0.63, B 3.34, CCC/C 28.30, consistent with the notch values.
# These come out as `pd_published`; `pd_nr_adjusted` rescales by 1/(1-NR) so the
# expected PD is defined on the same basis as the simulated matrix (see
# `nr_adjust` below for why).


def nr_adjust(pct_row: list[float]) -> np.ndarray:
    """Drop the NR column and renormalise.

    NR (withdrawn) is censoring, not a credit event: the issuer's later fate is
    unobserved. Redistributing NR mass pro-rata to the other outcomes is the
    standard treatment and keeps simulated obligors from silently vanishing.
    """
    p = np.array(pct_row[:-1], dtype=float)
    return p / p.sum()


def build_annual_matrix() -> np.ndarray:
    """18x18 annual transition matrix with D absorbing."""
    p = np.vstack([nr_adjust(SP_ONE_YEAR_PCT[r]) for r in RATINGS])
    return np.vstack([p, np.r_[np.zeros(D_IDX), 1.0]])


def quarterly_matrix(annual: np.ndarray) -> tuple[np.ndarray, float]:
    """Fourth root of the annual matrix, so four simulated quarters reproduce it.

    Eigen-decomposition is used instead of scipy.linalg.fractional_matrix_power
    to keep the dependency list short. The annual matrix has strictly real,
    positive eigenvalues (checked at build time), so the principal root is real;
    tiny negative entries (~1e-5) are clipped and rows renormalised. The residual
    max|Q^4 - P| is returned and asserted small so the approximation is never silent.
    """
    w, v = np.linalg.eig(annual)
    if np.abs(w.imag).max() > 1e-12 or w.real.min() <= 0:
        raise ValueError("annual matrix has non-positive/complex eigenvalues; root is not real")
    q = (v @ np.diag(w.real ** 0.25) @ np.linalg.inv(v)).real
    q = np.clip(q, 0.0, None)
    q /= q.sum(axis=1, keepdims=True)
    q[D_IDX] = 0.0
    q[D_IDX, D_IDX] = 1.0
    err = float(np.abs(np.linalg.matrix_power(q, 4) - annual).max())
    return q, err


# ---------------------------------------------------------------------------
# Portfolio composition assumptions
# ---------------------------------------------------------------------------
# GICS sectors minus Utilities (low-default, adds little to a monitoring demo).
SECTORS = ["Energy", "Materials", "Industrials", "Consumer Discretionary",
           "Consumer Staples", "Health Care", "Financials",
           "Information Technology", "Communication Services", "Real Estate"]
SECTOR_W_START = dict(zip(SECTORS, [0.11, 0.09, 0.16, 0.12, 0.08, 0.08, 0.14, 0.07, 0.05, 0.10]))
# Later originations tilt toward IT / Health Care and away from Energy / Real
# Estate, plus a weaker rating centre: a deliberate "mix drift" so PSI has
# something real to detect without needing artificial perturbation of history.
SECTOR_W_LATE = dict(zip(SECTORS, [0.06, 0.07, 0.14, 0.11, 0.07, 0.12, 0.11, 0.16, 0.08, 0.08]))
RATING_CENTRE_START, RATING_CENTRE_LATE, RATING_SD = 9.0, 10.5, 2.6

# Synthetic stress episodes: multiplier on the probability mass of moving to a
# *worse* state (incl. default). Stored in sim_stress_overlay so the monitor's
# findings can be checked against known ground truth.
STRESS = [
    ("Energy",      "2022Q1", "2022Q4", 3.0),   # commodity-price shock
    ("Real Estate", "2024Q1", "2025Q4", 4.0),   # CRE refinancing wall
]

FACILITY_TYPES = {
    # type: (utilisation start range, mean-reversion target, quarterly vol)
    "Revolving Credit Facility": ((0.15, 0.60), 0.35, 0.05),
    "Term Loan":                 ((0.92, 1.00), 0.96, 0.01),
    "Trade Finance Line":        ((0.30, 0.70), 0.50, 0.06),
}
DRAWDOWN_ON_DOWNGRADE = 0.15     # distressed borrowers draw on committed lines
LIQUIDITY_GRAB_PROB, LIQUIDITY_GRAB_SIZE = 0.015, 0.30

NAME_PREFIX = ["Alder", "Brenton", "Calloway", "Dunmore", "Eastgate", "Fairhaven", "Granger",
               "Halcyon", "Ironbridge", "Jasper", "Kestrel", "Langford", "Meridian", "Northwind",
               "Oakridge", "Pembroke", "Quillon", "Redstone", "Stonehaven", "Thornfield",
               "Umber", "Vantage", "Westmoor", "Yarrow", "Zenith", "Ashcombe", "Bellamy",
               "Corvane", "Drayton", "Ellerby", "Fenwick", "Garrick", "Harlow", "Ingram",
               "Kingsley", "Lorimer", "Marlowe", "Norcross", "Osborne", "Prescott"]
NAME_NOUN = {
    "Energy": ["Petroleum", "Midstream", "Power"], "Materials": ["Chemicals", "Metals", "Packaging"],
    "Industrials": ["Engineering", "Logistics", "Aerospace"], "Consumer Discretionary": ["Retail", "Motors", "Leisure"],
    "Consumer Staples": ["Foods", "Beverages", "Household"], "Health Care": ["Pharma", "Medical", "Diagnostics"],
    "Financials": ["Capital", "Leasing", "Insurance"], "Information Technology": ["Systems", "Software", "Semiconductors"],
    "Communication Services": ["Telecom", "Media", "Broadband"], "Real Estate": ["Properties", "Estates", "REIT"],
}
NAME_SUFFIX = ["Holdings", "Group", "PLC", "Ltd", "Corp"]

# ---------------------------------------------------------------------------
# Config table: every threshold the SQL reads
# ---------------------------------------------------------------------------
CONFIG = [
    # key, numeric, text, description
    ("baseline_quarter", None, "2021Q4", "PSI baseline (reference) quarter"),
    ("asof_quarter", None, "2025Q4", "Reporting date for the watchlist"),
    ("tm_from_quarter", None, "2024Q4", "Default window start for v_transition_matrix"),
    ("tm_to_quarter", None, "2025Q4", "Default window end for v_transition_matrix"),
    ("psi_amber", 0.10, None, "PSI >= this is amber (moderate shift)"),
    ("psi_red", 0.25, None, "PSI > this is red (significant shift)"),
    ("psi_epsilon", 0.0001, None, "Floor on bucket share so LN(a/e) is defined for empty buckets"),
    ("ccf_undrawn", 0.5, None, "Credit conversion factor applied to undrawn commitments: EAD = drawn + CCF * undrawn"),
    ("lgd", 0.45, None, "Flat LGD for expected loss (Basel F-IRB senior unsecured corporate)"),
    ("pd_floor", 0.0003, None, "PD floor of 3bp (Basel III IRB) -- published AAA/AA+ default rate is 0.00%"),
    ("top_n", 10.0, None, "Number of single names in the concentration view"),
    ("hhi_moderate", 0.15, None, "Sector HHI (0-1 scale) at or above which concentration is 'moderate'"),
    ("hhi_high", 0.25, None, "Sector HHI (0-1 scale) above which concentration is 'high'"),
    ("backtest_horizon_q", 4.0, None, "Forward window for PD back-test; 4 quarters matches a one-year PD"),
    ("backtest_alpha", 0.05, None, "Significance level for the one-sided binomial test"),
    ("wl_downgrade_notches", 2.0, None, "Watchlist: downgrade of at least this many notches ..."),
    ("wl_downgrade_window_q", 2.0, None, "... within this many quarters"),
    ("wl_util_increase", 0.25, None, "Watchlist: quarter-on-quarter utilisation increase above this (fraction, 0.25 = 25pp)"),
    ("wl_sector_ratio", 1.5, None, "Watchlist: sector realised/expected default rate above this"),
    ("wl_sector_lookback_q", 4.0, None, "Look-back (quarters) for the sector realised default rate"),
    ("wl_sector_min_defaults", 2.0, None, "Guard: sector needs at least this many realised defaults before the ratio counts"),
]

# ---------------------------------------------------------------------------
# DDL
# ---------------------------------------------------------------------------
DDL = """
CREATE TABLE ref_quarter (
    quarter     VARCHAR PRIMARY KEY,          -- e.g. '2023Q2'; sorts correctly as text
    q_index     INTEGER NOT NULL UNIQUE,      -- 1..20, used for lags so SQL never parses strings
    quarter_end DATE    NOT NULL
);
CREATE TABLE ref_rating_scale (
    rating VARCHAR PRIMARY KEY,
    notch  INTEGER NOT NULL UNIQUE,           -- 1 = AAA ... 17 = CCC/C, 18 = D (higher = worse)
    bucket VARCHAR NOT NULL,                  -- letter grade without modifiers
    grade  VARCHAR NOT NULL CHECK (grade IN ('Investment Grade','Sub-Investment Grade','Default'))
);
CREATE TABLE ref_sector (sector VARCHAR PRIMARY KEY);
CREATE TABLE ref_transition_published (       -- verbatim S&P Table 23, percent, incl. NR
    from_rating VARCHAR NOT NULL, to_rating VARCHAR NOT NULL, pct DOUBLE NOT NULL,
    PRIMARY KEY (from_rating, to_rating)
);
CREATE TABLE ref_transition_matrix (          -- NR-adjusted, D absorbing; probabilities
    from_rating VARCHAR NOT NULL, to_rating VARCHAR NOT NULL, prob DOUBLE NOT NULL,
    PRIMARY KEY (from_rating, to_rating)
);
CREATE TABLE ref_pd (
    rating VARCHAR PRIMARY KEY,
    pd_published   DOUBLE NOT NULL,           -- S&P Table 23 'D' column, as a fraction
    pd_nr_adjusted DOUBLE NOT NULL            -- pd_published / (1 - NR); the long-run PD used in SQL
);
CREATE TABLE config (
    key VARCHAR PRIMARY KEY, value_num DOUBLE, value_txt VARCHAR, description VARCHAR NOT NULL
);
CREATE TABLE sim_stress_overlay (             -- ground truth of the synthetic stress episodes
    sector VARCHAR NOT NULL, start_quarter VARCHAR NOT NULL, end_quarter VARCHAR NOT NULL,
    downgrade_multiplier DOUBLE NOT NULL
);
CREATE TABLE obligor (
    obligor_id VARCHAR PRIMARY KEY, obligor_name VARCHAR NOT NULL,
    sector VARCHAR NOT NULL REFERENCES ref_sector(sector),
    origination_quarter VARCHAR NOT NULL REFERENCES ref_quarter(quarter)
);
CREATE TABLE facility (
    facility_id VARCHAR PRIMARY KEY,
    obligor_id VARCHAR NOT NULL REFERENCES obligor(obligor_id),
    facility_type VARCHAR NOT NULL
);
CREATE TABLE facility_snapshot (              -- one row per facility per quarter while the obligor is performing
    facility_id VARCHAR NOT NULL REFERENCES facility(facility_id),
    obligor_id  VARCHAR NOT NULL REFERENCES obligor(obligor_id),
    quarter     VARCHAR NOT NULL REFERENCES ref_quarter(quarter),
    committed   DECIMAL(18,2) NOT NULL CHECK (committed > 0),   -- USD mn; DECIMAL so SUMs are exact and order-independent
    drawn       DECIMAL(18,2) NOT NULL CHECK (drawn >= 0),      -- USD mn
    PRIMARY KEY (facility_id, quarter),
    CHECK (drawn <= committed)
);
CREATE TABLE rating_obs (                     -- quarter-end internal rating on the S&P scale; D is recorded once, in the default quarter
    obligor_id VARCHAR NOT NULL REFERENCES obligor(obligor_id),
    quarter    VARCHAR NOT NULL REFERENCES ref_quarter(quarter),
    rating     VARCHAR NOT NULL REFERENCES ref_rating_scale(rating),
    PRIMARY KEY (obligor_id, quarter)
);
CREATE TABLE default_event (
    obligor_id VARCHAR PRIMARY KEY REFERENCES obligor(obligor_id),
    default_quarter VARCHAR NOT NULL REFERENCES ref_quarter(quarter),
    prior_rating VARCHAR NOT NULL REFERENCES ref_rating_scale(rating)
);
"""


# ---------------------------------------------------------------------------
# Generation
# ---------------------------------------------------------------------------
def quarter_labels() -> list[str]:
    return [f"{y}Q{q}" for y in YEARS for q in range(1, 5)]


def draw_rating(rng: np.random.Generator, centre: float) -> int:
    k = np.arange(len(RATINGS))
    w = np.exp(-((k - centre) ** 2) / (2 * RATING_SD ** 2))
    return int(rng.choice(k, p=w / w.sum()))


def stressed_row(row: np.ndarray, state: int, mult: float) -> np.ndarray:
    """Inflate the mass moving to worse states, then renormalise."""
    if mult == 1.0 or state >= D_IDX:
        return row
    r = row.copy()
    r[state + 1:] *= mult
    return r / r.sum()


def build_obligors(rng: np.random.Generator) -> pd.DataFrame:
    n_late = N_OBLIGORS - N_AT_START
    orig_idx = np.r_[np.zeros(N_AT_START, dtype=int), rng.integers(1, 16, size=n_late)]  # 2021Q2..2024Q4
    names: set[str] = set()
    rows = []
    for i, q0 in enumerate(orig_idx):
        late = q0 > 0
        w = SECTOR_W_LATE if late else SECTOR_W_START
        sector = rng.choice(SECTORS, p=np.array([w[s] for s in SECTORS]) / sum(w.values()))
        while True:
            nm = f"{rng.choice(NAME_PREFIX)} {rng.choice(NAME_NOUN[sector])} {rng.choice(NAME_SUFFIX)}"
            if nm not in names:
                names.add(nm)
                break
        rows.append((f"OBL{i + 1:04d}", nm, str(sector), int(q0),
                     draw_rating(rng, RATING_CENTRE_LATE if late else RATING_CENTRE_START)))
    return pd.DataFrame(rows, columns=["obligor_id", "obligor_name", "sector", "orig_idx", "init_state"])


def simulate_ratings(obl: pd.DataFrame, qmat: np.ndarray, rng: np.random.Generator, qs: list[str]) -> np.ndarray:
    """state[i, t] = rating index, or -1 before origination / after default."""
    u = rng.random((len(obl), N_Q))          # drawn up front: the stream does not depend on path
    state = np.full((len(obl), N_Q), -1, dtype=int)
    stress = {(s, qs.index(a) + 1, qs.index(b) + 1): m for s, a, b, m in STRESS}
    for i, o in enumerate(obl.itertuples()):
        s = int(o.init_state)
        state[i, o.orig_idx] = s
        for t in range(o.orig_idx, N_Q - 1):
            if s == D_IDX:
                break
            mult = next((m for (sec, lo, hi), m in stress.items() if sec == o.sector and lo <= t + 1 <= hi), 1.0)
            cdf = np.cumsum(stressed_row(qmat[s], s, mult))
            s = min(int(np.searchsorted(cdf, u[i, t], side="right")), D_IDX)
            state[i, t + 1] = s
    return state


def simulate_facilities(obl: pd.DataFrame, state: np.ndarray, rng: np.random.Generator, qs: list[str]):
    types = list(FACILITY_TYPES)
    fac_rows, snap_rows = [], []
    fac_n = 0
    for i, o in enumerate(obl.itertuples()):
        # Better-rated names borrow more; lognormal gives the heavy tail that makes single-name concentration non-trivial.
        size = rng.lognormal(mean=np.log(40.0), sigma=0.85) * float(np.clip(1 + (9 - o.init_state) * 0.04, 0.5, 1.6))
        n_fac = int(rng.choice([1, 2, 3], p=[0.5, 0.35, 0.15]))
        shares = rng.dirichlet(np.ones(n_fac) * 3)
        ftypes = rng.choice(types, size=n_fac, replace=False)
        for k in range(n_fac):
            fac_n += 1
            fid = f"FAC{fac_n:05d}"
            ftype = str(ftypes[k])
            (lo, hi), target, vol = FACILITY_TYPES[ftype]
            committed = round(max(1.0, size * shares[k]), 2)
            util = rng.uniform(lo, hi)
            fac_rows.append((fid, o.obligor_id, ftype))
            for t in range(o.orig_idx, N_Q):
                if state[i, t] in (-1, D_IDX):
                    break
                if t > o.orig_idx:
                    shock = rng.normal(0, vol) + 0.1 * (target - util)
                    if ftype != "Term Loan":
                        if state[i, t] - state[i, t - 1] >= 2:
                            shock += DRAWDOWN_ON_DOWNGRADE
                        if rng.random() < LIQUIDITY_GRAB_PROB:
                            shock += LIQUIDITY_GRAB_SIZE
                    util = float(np.clip(util + shock, 0.0, 1.0))
                snap_rows.append((fid, o.obligor_id, qs[t], committed, round(util * committed, 2)))
    return fac_rows, snap_rows


# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------
def fingerprint(con: duckdb.DuckDBPyConnection) -> dict[str, str]:
    """Order-independent content hash per table; equal across runs iff data is identical."""
    out = {}
    for (t,) in con.execute("SELECT table_name FROM information_schema.tables WHERE table_schema='main' ORDER BY 1").fetchall():
        out[t] = con.execute(f"SELECT md5(string_agg(CAST(x AS VARCHAR), '|' ORDER BY CAST(x AS VARCHAR))) FROM {t} x").fetchone()[0]
    return out


def build(db_path: Path, seed: int) -> None:
    db_path.parent.mkdir(parents=True, exist_ok=True)
    if db_path.exists():
        db_path.unlink()       # rebuild from scratch; stale rows would break determinism
    # Independent child streams per concern, so tweaking one generator does not reshuffle the others.
    r_obl, r_rate, r_fac = (np.random.default_rng(s) for s in np.random.SeedSequence(seed).spawn(3))

    annual = build_annual_matrix()
    qmat, root_err = quarterly_matrix(annual)
    if root_err > 1e-3:
        raise RuntimeError(f"quarterly matrix root too inaccurate: max|Q^4-P|={root_err:.2e}")

    qs = quarter_labels()
    obl = build_obligors(r_obl)
    state = simulate_ratings(obl, qmat, r_rate, qs)
    fac_rows, snap_rows = simulate_facilities(obl, state, r_fac, qs)

    rating_rows, default_rows = [], []
    for i, o in enumerate(obl.itertuples()):
        for t in range(N_Q):
            if state[i, t] >= 0:
                rating_rows.append((o.obligor_id, qs[t], STATES[state[i, t]]))
                if state[i, t] == D_IDX:
                    default_rows.append((o.obligor_id, qs[t], STATES[state[i, t - 1]]))

    con = duckdb.connect(str(db_path))
    con.execute(DDL)

    def load(table: str, df: pd.DataFrame) -> None:
        con.register("_df", df)
        con.execute(f"INSERT INTO {table} SELECT * FROM _df")
        con.unregister("_df")

    load("ref_quarter", pd.DataFrame({
        "quarter": qs, "q_index": range(1, N_Q + 1),
        "quarter_end": [pd.Period(q.replace("Q", "-Q")).end_time.date() for q in qs]}))
    load("ref_rating_scale", pd.DataFrame({
        "rating": STATES, "notch": range(1, len(STATES) + 1), "bucket": [bucket_of(r) for r in STATES],
        "grade": ["Investment Grade" if i < 10 else "Sub-Investment Grade" for i in range(len(RATINGS))] + ["Default"]}))
    load("ref_sector", pd.DataFrame({"sector": SECTORS}))
    load("ref_transition_published", pd.DataFrame(
        [(r, c, SP_ONE_YEAR_PCT[r][j]) for r in RATINGS for j, c in enumerate(STATES + ["NR"])],
        columns=["from_rating", "to_rating", "pct"]))
    load("ref_transition_matrix", pd.DataFrame(
        [(r, c, float(annual[i, j])) for i, r in enumerate(STATES) for j, c in enumerate(STATES)],
        columns=["from_rating", "to_rating", "prob"]))
    load("ref_pd", pd.DataFrame(
        [(r, SP_ONE_YEAR_PCT[r][D_IDX] / 100, float(annual[i, D_IDX])) for i, r in enumerate(RATINGS)],
        columns=["rating", "pd_published", "pd_nr_adjusted"]))
    load("config", pd.DataFrame(CONFIG, columns=["key", "value_num", "value_txt", "description"]))
    load("sim_stress_overlay", pd.DataFrame(STRESS, columns=["sector", "start_quarter", "end_quarter", "downgrade_multiplier"]))
    load("obligor", pd.DataFrame({
        "obligor_id": obl.obligor_id, "obligor_name": obl.obligor_name, "sector": obl.sector,
        "origination_quarter": [qs[i] for i in obl.orig_idx]}))
    load("facility", pd.DataFrame(fac_rows, columns=["facility_id", "obligor_id", "facility_type"]))
    load("facility_snapshot", pd.DataFrame(snap_rows, columns=["facility_id", "obligor_id", "quarter", "committed", "drawn"]))
    load("rating_obs", pd.DataFrame(rating_rows, columns=["obligor_id", "quarter", "rating"]))
    load("default_event", pd.DataFrame(default_rows, columns=["obligor_id", "default_quarter", "prior_rating"]))

    print(f"Seeded {db_path} (seed={seed}); quarterly-root residual max|Q^4-P| = {root_err:.1e}")
    for t in ["obligor", "facility", "facility_snapshot", "rating_obs", "default_event"]:
        print(f"  {t:<18}{con.execute(f'SELECT COUNT(*) FROM {t}').fetchone()[0]:>8,}")
    print("Content fingerprints (identical across runs for the same seed):")
    for t, h in fingerprint(con).items():
        print(f"  {t:<26}{h}")
    con.close()


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--db", type=Path, default=DEFAULT_DB)
    ap.add_argument("--seed", type=int, default=DEFAULT_SEED)
    args = ap.parse_args()
    build(args.db, args.seed)
