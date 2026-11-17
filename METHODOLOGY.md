# Methodology

Figures quoted below are from the default build (`seed 42`) and are reproducible: the same seed gives bit-identical tables and view outputs.

## 1. Data generation

The book is synthetic. It exists to exercise the monitoring logic, not to look like any institution's portfolio.

- **Population.** 500 obligors across 10 sectors (GICS, excluding Utilities). 400 are on the book at 2021Q1; the other 100 originate uniformly across 2021Q2 to 2024Q4. 807 facilities (revolver, term loan, trade finance line), 14,572 facility-quarter snapshots, all in USD mn.
- **Ratings.** 17 performing notches (AAA to CCC/C) plus D, 18 states in total. Initial ratings are a discretised normal centred on BBB-. Later originations are centred 1.5 notches weaker and tilted toward IT and Health Care, a deliberate mix drift so the PSI views have something to detect.
- **Migration.** Each quarter, each obligor draws its next rating from a quarterly transition matrix (section 2). D is absorbing and recorded once, in the default quarter; the obligor leaves the performing book from the next quarter. Result: 26 defaults.
- **Stress overlay.** Two episodes multiply the probability of moving to a worse state, including default: Energy ×3 in 2022, Real Estate ×4 from 2024Q1. They are stored in `sim_stress_overlay`, so the monitor's findings can be checked against known ground truth. Real Estate accounts for 9 of the 26 defaults.
- **Utilisation.** A bounded, mean-reverting random walk per facility. Revolvers and trade lines draw down by 15pp on a 2+ notch downgrade, plus a 1.5% per quarter chance of a 30pp liquidity draw. Term loans stay near fully drawn.
- **Sizing.** Lognormal obligor size (median about USD 40mn) scaled up for better ratings, giving the heavy tail that makes single-name concentration non-trivial.

## 2. Transition matrix source

S&P Global Ratings, *Default, Transition, and Recovery: 2020 Annual Global Corporate Default And Rating Transition Study* (7 April 2021), Table 23, "Average One-Year Transition Rates For Global Corporates By Rating Modifier (1981-2020)". Hardcoded in `seed.py` as published, with the NR column kept in `ref_transition_published`.

Two adjustments, both visible in code:

1. **NR is redistributed.** Withdrawn ratings are censoring, not a credit event, so each row is renormalised without the NR column (`ref_transition_matrix`).
2. **Annual to quarterly.** The quarterly matrix is the fourth root of the annual one, by eigen-decomposition. The annual matrix has real positive eigenvalues, so the root is real; about 1e-5 of negative entries are clipped and rows renormalised. The build asserts `max|Q⁴ − P| < 1e-3` (actual: 4e-4).

The 2020 edition was used because its full table could be retrieved and checked cell by cell. Later editions move cells by a few basis points.

## 3. PD source

The "D" column of the same Table 23, i.e. the long-run average one-year default rate per notch. It matches Table 24's one-year column at letter-grade level (AAA 0.00%, BBB 0.16%, BB 0.63%, B 3.34%, CCC/C 28.30%). `pd_nr_adjusted = D / (1 − NR)` puts the PD on the same basis as the simulated matrix; without it the back-test would show a built-in 4% to 18% under-prediction. A 3bp floor (`pd_floor`, Basel III IRB) covers AAA and AA+, whose published rate is 0.00%.

## 4. Exposure

`EAD = drawn + CCF × (committed − drawn)`, CCF 0.5 for every product. `EL = EAD × PD × LGD`, LGD 0.45. This is a through-the-cycle monitoring figure, not an IFRS 9 provision. All parameters are in `config`.

## 5. PD back-test

Cohort = obligors performing at quarter *t*. Realised = those defaulting in *t+1 … t+4*, so the window matches a one-year PD without annualising. Expected = the cohort's mean rating-implied PD, per letter bucket. The test is one-sided and exact: *p* = P(X ≥ k), X ~ Binomial(n, p̄), computed in SQL with `lgamma`. A small *p* means PDs are too low.

## 6. PSI

`PSI = Σᵢ (aᵢ − eᵢ) · ln(aᵢ / eᵢ)`, with *a* the share in the current quarter and *e* the share in the baseline (`baseline_quarter`, default 2021Q4). Shares below `psi_epsilon` are floored so empty bins do not produce ln(0). Bands: green < 0.10, amber 0.10 to 0.25, red > 0.25.

**Worked example** (rating PSI, 2025Q4 vs 2021Q4, obligor-count basis; four of the 17 notches shown, shares rounded):

| Rating | e (2021Q4) | a (2025Q4) | a − e | ln(a/e) | Term |
|---|---|---|---|---|---|
| BBB | 0.1116 | 0.1624 | +0.0508 | +0.3751 | 0.0191 |
| BB | 0.1021 | 0.0612 | −0.0410 | −0.5125 | 0.0210 |
| B- | 0.0119 | 0.0316 | +0.0198 | +0.9800 | 0.0194 |
| AA | 0.0024 | 0.0001 | −0.0023 | −3.1677 | 0.0072 |
| *13 other notches* | | | | | 0.0616 |
| **Total** | | | | | **0.1283 (AMBER)** |

Every term is non-negative whichever way the share moves, because (a − e) and ln(a/e) always share a sign. Both shares and logs are computed by the view; the table shows how one row is built.

## 7. Watchlist

An obligor performing at `asof_quarter` is flagged if any of:

- **R1:** rating down 2 or more notches over the last 2 quarters.
- **R2:** utilisation (sum drawn / sum committed) up by more than 25pp on the prior quarter.
- **R3:** its sector's realised default rate over the last 4 quarters exceeds 1.5× expected, where expected is the mean long-run PD of the sector's names at the start of the window.

Result at 2025Q4: 90 obligors, 5 tripping two rules. R3 accounts for most of the list.

## 8. Known limitations

- **Single-edition, global-average matrix.** No region, sector or cycle conditioning; the long-run average is not a forecast of the current year.
- **R3 is blunt and noisy.** It flags every name in a sector. Real Estate is a true positive (known stress). Materials is a false positive from chance: 3 defaults against about 0.3 expected. I added a guard (`wl_sector_min_defaults = 2`) that is not in the stated rule; without it a single default in a small sector would trip the flag.
- **Back-test power is low.** 64 of the 93 populated cohort-bucket rows expect fewer than one default, so a PASS says little (`low_power` marks them). Cohorts overlap, so *p*-values across rows are not independent. The bucket-mean PD treats notches inside a bucket as homogeneous.
- **PSI has a noise floor.** About (K−1)(1/n_base + 1/n_cur): roughly 0.07 for 17 notches at 450 names, so most of the way to amber. The sector PSI (10 bins) is green throughout, meaning the sector mix barely moved.
- **Flat CCF and LGD, one currency, no maturities, collateral, guarantees or connected-party aggregation.**
- **Synthetic ratings are Markov.** Real ratings show momentum and sector contagion that this generator does not model, so the monitor is validated here only against the shocks deliberately injected.
