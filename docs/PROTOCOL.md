# Replication protocol (adapted from Hull 2026, Appendix B)

Goal: assess the empirical importance of negative TWFE weights in staggered-adoption
difference-in-differences published in Management Science, Marketing Science and JMR,
by re-estimating each eligible specification with TWFE, Callaway-Sant'Anna
DiD-averaging (CSA) and Borusyak-Jaravel-Spiess imputation (BJS).

## 1. Search frame

| Journal | Window | Reason for start year |
|---|---|---|
| Management Science (mnsc) | 2019-01-01 to cutoff | Code and Data Disclosure Policy effective June 1, 2019 (applies by submission date, so some 2019-2020 papers predate it) |
| Marketing Science (mksc) | 2013-01-01 to cutoff | Data Disclosure and Replication Policy, Jan-Feb 2013 editorial |
| JMR (jmr) | 2019-01-01 to cutoff | Transparency policy July 1, 2023; Dataverse restricted by default, so JMR requires author outreach |

Cutoff date: TBD (Hull used Oct 10, 2026). Forthcoming papers count if the accepted
manuscript and the replication package are both available by the cutoff.

Frame construction:
1. OpenAlex metadata for every work in the window (`code/01_openalex_frame.py`).
2. Full-text hit lists from the INFORMS site for the terms below, recorded as flags per
   paper (`data/hits/`). Abstracts alone undercount badly in marketing.
   Terms: "difference-in-differences", "difference-in-difference", "differences-in-differences",
   "diff-in-diff", "staggered", "two-way fixed effects", "Callaway", "Goodman-Bacon",
   "Borusyak", "Sun and Abraham", "de Chaisemartin".
3. Candidate list = union of hits, merged to the OpenAlex frame (`data/candidates/`).

## 2. Screening rules (per paper, then per specification)

Keep a paper if it reports in the main text (tables, figures, or numerical prose) at least
one eligible specification AND that specification is replicable from the replication
package (public code and data, or materials obtained from the authors).

Eligible specification:
- Binary treatment that switches on at unit-specific adoption dates, with at least two
  distinct first-adoption dates among cohorts that have both untreated and treated
  observations, and an untreated comparison unit in at least one treated period.
- Linear regression with unit (or group) fixed effects and calendar-time fixed effects:
  static TWFE, or an unstacked event study with relative-time indicators.
- Allowed: analysis weights; time-invariant characteristics interacted with calendar-time
  fixed effects (e.g., region-by-year FE); panels or repeated cross-sections assigned to
  stable units.
- Also eligible: explicitly reported CSA or BJS estimates under the same design restrictions,
  and Sun-Abraham interacted event studies when they coincide with CSA.
- Excluded: time-varying controls, lagged outcomes, unit-specific trends, additional
  treatments, treatment-intensity or continuous regressors, subgroup-by-treatment
  interactions, other nonredundant additive fixed effects, stacked DiD, IV, nonlinear
  models (Poisson, logit), synthetic control, matching-based DiD.
- Treatments that switch off: drop post-adoption periods where treatment equals zero.

Unit of analysis: every qualifying main-text specification, regardless of sign, size,
significance or the authors' interpretation. Different outcomes, transformations, samples,
treatment definitions, event windows or bins, weights, fixed effects or controls are
distinct specifications. A jointly estimated event-study path is one specification.

## 3. Fields recorded per specification

paper_id, doi, journal, year, department (MS only), table/figure, panel, row, column,
outcome, outcome transformation, treatment definition, unit of observation, assignment
unit, calendar-time unit, sample restrictions, weights, fixed effects, clustering,
event-study bins and omitted period, reported coefficient and SE, preferred-spec flag,
abstract/intro prominence flag, reports-modern-estimator flag (CSA/BJS/SA/dCDH),
software of replication code, replication status (exact / approximate / failed), notes.

## 4. Estimation (per specification)

1. Replicate the published TWFE estimate from the package (record deviations).
2. Standardize the outcome to unit SD in the regression sample.
3. TWFE with original weights, FE, clustering.
4. CSA: cohort-by-period ATTs with never- and not-yet-treated controls, convex weights
   proportional to treated observations; event-study versions average by horizon.
5. BJS imputation: fit FE model on untreated observations, impute Y(0) for treated cells,
   average. Pre-trend summaries follow Hull's Appendix B.
6. Covariances between estimators by Bayesian bootstrap (999 draws). Status Nov 1: not yet run; analysis sets cov = 0 (conservative for significant reversals).
7. Leverage screen: keep pairs with effective clusters >= 10 and max cluster share <= 0.25.
8. Ex post TWFE weights (Borusyak-Hull): share of treated rows with negative weight and
   negative share of absolute weight.

## 5. Analyses to reproduce

Figure 2 (modern vs TWFE, sign flips, significant flips), Figure 3 correlates
(year, reports-modern flag, citations, prominence, preferred, event study, always- and
never-treated shares; journal rank replaced by journal and MS department), Figure A3
negative-weight distributions, Table 2 Gaussian hierarchical model with precision dependence.

## 5b. Screening decisions log (judgment calls, Nov 1, 2026)

- Matched estimation samples: a plain TWFE regression run on a matched (e.g., 1:1 nearest-neighbour,
  unweighted) sample counts as a sample restriction and is ELIGIBLE; matching estimators,
  propensity reweighting (IPW), and synthetic controls are not. (GLP-1 paper kept.)
- Random-effects intercepts (REML) in place of fixed effects: NOT eligible as reported.
- Assignment-unit-specific linear trends in every reported column: NOT eligible (Hull's unit-trend rule).
- A single time-varying control in every reported column: NOT eligible; recorded as a near-miss
  (e.g., mnsc.2021.01010 county-by-week mobility control).
- Extra treatment regressors (anticipation indicators, release indicators, post trends): NOT eligible.
- Triple differences with an additional staggered regressor (e.g., within-hotel platform DDD): NOT eligible.
- Treatments that switch off (discontinuation): keep the paper; drop post-adoption periods with
  treatment switched off (Hull footnote 6).
- Working-paper texts: eligibility and table references must be re-checked against the published
  version when the article PDF becomes available.
- Estimators admitted as "reported modern DiD": Callaway-Sant'Anna, Sun-Abraham (when it coincides
  with CSA), Borusyak-Jaravel-Spiess imputation, Gardner did2s. Wooldridge ETWFE (jwdid), synthetic
  DiD, matrix completion, stacked DiD are NOT admitted; a paper reporting only those is a near-miss.
- Additional additive fixed effects beyond unit and (group x) time (e.g., age FE, pair-level post
  main effects, event-time main effects for all units) make a column ineligible.
- A single anticipation bin (e.g., event months -2/-1) alongside the post indicator is treated as a
  two-bin event study: the static re-estimation drops the anticipation rows and dates onset at the
  start of the bin (recorded deviation).
- Appendix-only qualifying specifications are not counted (main-text rule), but are listed in the
  screening record for a possible appendix-inclusive sensitivity analysis.
- Random subsamples or linearly rescaled ("authors_transformed") original data count as original
  data with a flag; synthetic, disguised, pseudo, scrambled, or fuzzed data are excluded from the
  main analysis (data/synthetic_packages.txt).
- Unbalanced panels (revised Nov 2: follow Hull, and Hull's version is the main estimate): the Callaway-Sant'Anna
  step is did::att_gt with allow_unbalanced_panel = TRUE, i.e. Hull's DiD-averaging formula with cohort sample averages of
  whichever units are observed in each period (verified: cell ATTs equal the hand-computed cohort averages to 1e-13 on
  mnsc.2021.01740; aggte weights cohorts by units). The composition-fixed cells below are computed only as a diagnostic
  column (csa_fc, csa_fc_se; CSA_UNBALANCED=fixed restores them as main); the robustness check based on them was dropped
  (Nov 2: these can change the estimates reported in the paper, so they were removed from the main analysis). They are the main estimate only where the published CSA
  comes from Stata csdid, which uses the same cells (ruling Nov 2 evening (c) below). Bootstrap covariances for these specs
  come from boot_cov.R's repeated-cross-section path with unit-level cohort weights (BOOT_CSA_ONLY=1 updated the CSA columns
  on the original seeded draws). Superseded text:
  the Callaway-Sant'Anna step uses composition-fixed cells (units observed in
  both g-1 and t) with a cluster Bayesian bootstrap SE; did::att_gt is used for balanced panels and
  repeated cross-sections. Rationale: did's allow_unbalanced_panel treats cells as repeated cross
  sections, which lets entering/exiting units drive the estimate (documented in
  data/replication_logs/mnsc.2025.02515.md and mnsc.2020.3707.md).

- Hull alignment (Nov 1: follow Hull on every open issue):
  (a) Duplicate unit-periods: Hull's eq. (1) indexes observations j with u(j) a stable unit OR GROUP; data with several
  rows per (u, t) are repeated cross-sections and use the RC estimators. A scan of the 78 specs with duplicates found no
  stray duplicates (lowest: 10% of unit-periods duplicated; group designs up to 1,147 rows per cell), so all stay on RC.
  (b) The composition-fixed CSA SE uses 999 Bayesian bootstrap draws (was 49).
  (c) TWFE-modern covariances come from a joint weighted (Bayesian) bootstrap with 999 draws at the cluster level (Hull
  fn. 18), code/R/boot_cov.R -> output/boot_cov/; each draw re-estimates TWFE, BJS and CSA (CSA by exact cell-level
  re-implementations without covariates; specs whose CSA uses covariates get no CSA covariance and keep 0). Draw 0 must
  reproduce the main estimates (checked per spec).
  (d) BJS pre-trend averages: regression of y on the allowed FE (and controls) plus lead-bin indicators on untreated
  observations, averaging the identified lead coefficients over pre_min..-2 (Hull App. B; BJS 2024), replacing the
  did2s second-stage lead coefficients (in-sample residual means).

- Ruling (Nov 1 ~21:40, screening round 2): several group-by-time FE sets in one regression (e.g. branch x year and
  municipality x year, each a fixed characteristic of the unit) are allowed under Hull's rule admitting fixed subgroup-by-
  time fixed effects (mnsc.2022.4346; moot there because the package ships simulated data).

- Coding rule (Nov 1 ~22:00): in screening records, eligible_design = true only when at least one main-text specification
  satisfies every design rule (eligibility may still fail on data). Staggered designs whose every column violates a rule
  (stacked-only, extra treatment regressors, DDD with an extra post, controls) have eligible_design = false and near_miss =
  true (near_miss_5c_controls_only = true only when time-varying controls are the sole violation).

- Ruling (Nov 1 ~23:10, mnsc.2023.4968): stray duplicate unit-periods created by a data merge (11 of ~4,700 firms x 55
  quarters) are collapsed to one row with a frequency weight (outcome = mean). TWFE and the imputation estimator are exactly
  unchanged, and the panel is then estimated as a panel. Genuine group-level designs with many rows per unit-period stay
  repeated cross-sections (Hull alignment (a)).
  Applied again Nov 2 to mnsc.2023.01423: overlapping event windows of multi-split stocks repeat a few stock-months (0.2% of
  the pipeline sample) with identical outcomes; collapsed on (stkcd, ym, after, dummyh) with frequency weight w_mergedup.

- Ruling (Nov 2, significance test): the TWFE-modern difference is tested with analytic SEs and the joint-bootstrap
  covariance (Hull fn. 18). Where these imply a non-positive variance for the difference (4 CSA and 10 BJS rows in the final
  run: analytic SEs slightly below the bootstrap SDs, bootstrap correlation near 1), the covariance is replaced by the
  bootstrap correlation times the analytic SEs (always a valid variance). Flooring the variance at zero would count any
  nonzero difference as significant. Hull does not cover this case; the paper says so (code/R/analysis.R compare(), also
  code/R/analysis_controls.R). Robustness macros: zero covariance, correlation-scaled covariance, all-bootstrap variance.
- Ruling (Nov 2): paper-weighted results and the hierarchical model are also reported without
  mnsc.2021.01740 (OUTLIER_PAPER in analysis.R). It has no never-treated units and fixed per-product event windows, so the
  linear event-time trend is not identified; its two precise, opposite-sign estimates move the paper-weighted imputation
  correlation from 0.83 to 0.40 and the hierarchical imputation estimand correlation from 0.91 to 0.68. Reported alongside,
  not instead of, the full-sample figures.
- Rulings (Nov 2 evening, after an audit of every published value against our estimates).
  The audit (four agents, every gap reproduced by independent fixest/did/Stata runs) found no arithmetic error; the changes
  below are protocol alignments with Hull and corrections of reference values.
  (a) Event studies keep each specification's original bins and reference normalization (Hull fn. 10: "I preserve each
  specification's original reference-period normalization"; App. B keeps source bins), recorded per spec in
  `event_structure` (schema in code/R/event_structure.R). TWFE estimates the authors' indicators. DiD-averaging bin effects
  pool did's cohort-weighted cells within each bin and subtract the estimated effect in the reference set (omitted bins plus
  pooled uncovered relative times; zero when the reference is -1 alone). Imputation keeps the standard BJS method when the
  reference is -1 alone and otherwise uses Hull's explicit-reference contrasts (bin means of Y - Yhat(0), bins averaged
  equally, minus the weighted residual mean in the reference observations). Summaries average the available reported bins
  equally. Replaces the earlier re-normalization of every event study to -1 with endpoint bins (kept only for specs whose
  authors use that coding).
  (b) Adoption dates come from the original treatment history (Hull App. B): adopters before the first sample period keep
  their true date, which sets their TWFE event time; they stay always-treated for DiD-averaging and imputation. Replaces the
  mapping of pre-sample adoptions to period 1.
  (c) Where a paper reports Callaway-Sant'Anna itself, the DiD-averaging estimate uses the authors' settings, so that it
  equals the published number (the reported estimates are the reference): aggregation windows (did's max_e ->
  drop_e_above; balance_e), cohort coding (never-treated coded as the last cohort -> last period dropped), the control
  group (csdid's default is never-treated) and Stata csdid's cells on unbalanced panels, which use only units observed in
  both g-1 and t (csdid prints "Will use observations with Pair balanced"; checked in Stata 16.1 with csdid 1.81 on
  mnsc.2022.4660: -0.4310009, N 19,432, as printed; and mnsc.2022.02310). Restrictions on treated rows apply to TWFE and
  imputation as well, so the three estimators share the sample and the treated cells; the control pool is never reduced.
  Settings that do not move post-period estimates without covariates (base period, est_method, SE method) stay at Hull's.
  Each such spec must reproduce the published point estimate before it enters. Stata validates; the R implementation
  estimates and bootstraps.
  Hull does not say he re-estimates published CS with the authors' estimator settings; he applies one DiD-averaging
  estimator and preserves design features (reference, bins, windows). So both versions are run (Nov 2): (B, main) the authors' estimator internals for the 80 published-CS specs, as above; (A) Hull's
  estimator for every spec (CSA_STRICT_HULL=1, output_hullA/), with the published CS as a replication check. Design
  fields (event_structure, windows such as drop_e_above / balance_e, sample filters, adoption dates) are identical in A and
  B, so TWFE and imputation are identical and only the DiD-averaging column differs.
  (c') Hull's DiD-averaging weights are "proportional to the number of treated observations in adoption cohort g and
  post-treatment period t" (event studies: treated-count weights across cohorts at each horizon). This equals did's fixed
  cohort shares only in balanced panels; in unbalanced panels and repeated cross-sections the pipeline now uses Hull's
  treated-count weights (analysis-weighted). csa_weights = "did" keeps did's weights for the 70 published-CS specs whose
  authors used R did or staggered (option B); csdid's cells are already count-weighted.
  (d) Consistency: mnsc.2021.4043 keeps banks that move state (switch-off rows dropped) and Alaska as an always-treated
  state, as in the other papers; mnsc.2022.03186 Table 4 drops switch-off rows as its Table 5 does; mksc.2023.1437's
  month-cohort recoding (reviews posted in the adoption month before the first response count as treated) is a documented
  judgment call.
  (e) Sample: specifications the paper does not report (mksc.2022.1353's constructed static versions of its two-bin event
  studies) and specifications absent from the published article (10 in mnsc.2022.4394) are excluded, with reasons, in
  data/specs_excluded/; published CSA columns missing from the sample are added (mnsc.2022.03186 Table 4, columns 2-6).
  (f) Reference values come from the published article, not drafts, code emulations or our own estimates; values read off
  figures are flagged as digitized. Estimator labels follow the article (several csdid estimates had been coded as TWFE).
  (g) Every specification and bootstrap is re-run on the server (code/server_sync.sh, code/server_run.sh; R 4.6.1 with
  package versions pinned to the local ones).
- Rulings and fixes (Nov 3, after two referee-style reviews of the draft and the code, Fable 5.1).
  (h) Reporting: no individual paper is named or singled out in the text ("we do not want to mention individual papers").
  Results "without paper X" are dropped; sensitivity to single papers is shown symmetrically by leave-one-paper-out ranges for
  every statistic, the hierarchical model re-fit on each sample (analysis.R `loo`; Appendix table `loo.tex`). No paper is
  excluded from the main results. The greedy "drop the five papers that raise the correlation most" measure was removed.
  (i) Option A/B (ruling (c)), REVISED Nov 3 evening (option B moves to the appendix; Hull's settings are the main analysis): A, Hull's
  DiD-averaging settings for every specification (output_hullA/ for the 80 published-CS specs, output/ for the rest), is the
  main analysis; B, the authors' CS settings for the 8 papers that publish a CS estimate (output/specs for those specs, which
  reproduce the printed numbers), is the appendix table `authcs.tex` plus a Results paragraph. analysis.R: `d_auth <- d; d <- dHA`
  right after the option-A swap; every later statistic (loo, no-screen, regressions, macros) uses Hull's settings. The
  published-CS reproduction table (`published_cs.tex`, appendix.R) is grouped by the authors' software, not by paper: 74 of 76
  printed estimates matched to the last printed decimal with the authors' settings; the two misses are the documented
  mksc.2022.1409 data-version gap. Its last columns report the gap between the two settings in units of the main (Hull) SE.
  Superseded text: B stays main; A is an appendix table (`hullA.tex`, now deleted).
  (j) Leverage screen: main results keep Hull's two-sided screen; an appendix reports every comparison without it
  (`noscreen.tex`; agreement is somewhat higher without the screen, and the text says so).
  (k) Imputation leverage (code review #1): the CG tolerance in bjs_leverage was 1e-14, unattainable in double precision; the
  iteration diverged (p'Ap < 0 -> NaN -> lev_bjs_error) and 80 of 361 imputation comparisons silently fell back to the
  TWFE-only screen. Fixed: tolerance 1e-10 and a curvature guard (estimators.R). Affected specs are rerun: 27 small ones in full
  on the Mac, 58 heavy ones on the server with CSA_SKIP=1 (DiD-averaging skipped; code/levpatch.py copies only the BJS
  leverage columns into output/specs after checking that TWFE and imputation estimates are unchanged).
  (l) Non-identified imputation estimates (code review E1; option (a) chosen): where the leverage system is inconsistent,
  some treated rows' Y(0) is not identified by the untreated rows and the imputation estimate depends on the fixed-effect
  normalization; these comparisons fail the imputation screen (analysis.R lev_flags; macro \nBJSnotIdent). Re-estimating
  with the non-imputable rows dropped (BJS 2024) is deferred.
  (m) DiD-averaging size limits: no comparison is skipped for computational reasons. The lean exact implementation covers the
  main sample (identical to did to 2e-11 where did runs); for the 35 controls comparisons whose DiD-averaging conditions on
  the controls (lean path unavailable), did runs on the server with every guard off (CSA_GUARDS_OFF=1, run_spec.R;
  logs/fulldid3.sh, output_fulldid/). mksc.2023.1437 T6_c1_all keeps the default guard: with it lifted, did exceeds R's
  2^31 sparse-matrix limit.
  (n) Counts: pre-window rows without a TWFE estimate are not comparisons (analysis.R); panel balance of size-guard rows comes
  from the guard note's period count; the synthetic-data table uses the main rules (computed in analysis.R). Funnel and
  screening counts have one definition each in code/15_tables.py, imported by 20_nearmiss_table.py and
  22_journal_funnel.py (re-estimated papers 41 = 36 MS + 5 MKSC; eligible designs 84; near-misses 112, a lower bound).
  (o) Server runs on Nov 3: server_run2-4 (bootstraps; run4 splits long bootstraps into draw chunks, BOOT_CHUNK/BOOT_MERGE,
  identical to single-process runs); fulldid2/3 (controls, memory-capped after an incident at 17:58 in which concurrent
  jobs drove available memory to 1 GB next to a MySQL server on the same machine: per-job address-space cap, start gate on available memory,
  watchdog that kills the youngest job); levpatch_run.sh (CSA_SKIP leverage refresh).
  (p) DiD-averaging with covariates beyond did's limits (Nov 4): the controls run with guards off left 20 static comparisons
  of two papers without a DiD-averaging estimate inside did itself (mnsc.2022.03920: n x cells influence-function matrix
  beyond R's 2^31 sparse limit; mnsc.2025.00954 T6/T8: did's cells x cells covariance out of memory under the 150 GB cap).
  The lean path cannot take covariates, so estimators.R now has csa_did_cells: did's estimator cell by cell (same DRDID
  calls and guards as did 2.5.1's faster_mode path, influence function of the reported summary accumulated as one length-n
  vector, analytic clustered SE as did's getSE). Validated on 65 static controls specs where did ran: estimates and SEs
  agree to 3e-12 (output/csa_cells_check.csv, CSA_CELLS_CHECK=1 in run_spec.R); the did path is unchanged. Dispatch: size
  guard, memory guard and did's own size/memory errors route covariate specs to the cells (notes size_did_cells /
  rc_did_cells / unbalanced_did_cells / did_error_cells). The 20 specs were run on the Mac with the default guards
  (output_cells/, 3-45 s each) and installed in output/specs_controls (backups backups/pre_cells_20261104, server
  logs/cells_backup_20261104). Ruling (m) therefore holds in the controls sample too.
  (q) DiD-averaging leverage with covariates (Nov 4): until Nov 4 csa_leverage returned NA for did's covariate estimator
  (lev_csa_na_controls / lev_csa_na_covariates), so those pairs were screened on TWFE leverage alone (all controls
  comparisons and 9 main-sample xt specs of 3 papers). estimators.R now has csa_did_cells_lev: theta = sum_j a_j y_j with
  a = sum_c lambda_c c_c, c_c the y-coefficients of each DRDID cell (did_cell_coef, from DRDID 1.3.0's reg_did_panel,
  reg_did_rc and drdid_rc with the propensity score and trimming held fixed) and lambda_c the cell's weight in the
  reported summary (csa_cell_lambda, same cells and pg as the estimator); G_eff and L_max from leverage_screen on did's
  rows and clusters. Checks: sum(a y) equals the stored estimate on all 107 patched specs (max 1.5e-10; event studies
  included), every cell's coefficients reproduce its ATT to 1e-8, finite differences of the estimate agree with a to
  1e-11, and with an intercept only it matches csa_hull_lev to 1e-12. Installed with CSA_LEV_PATCH=1 in run_spec.R
  (backups backups/pre_levpatch_20261104, server logs/levpatch_backup_20261104; the patch table is in the session
  scratchpad). Main sample: all 9 xt specs keep their status (6 already failed the TWFE screen, 3 pass both), so
  nLevFallbackCSA = 0 and nothing else changes. Controls: 15 comparisons of 3 papers that pass the TWFE screen fail the
  DiD-averaging screen (mnsc.2022.03920, 8 specs, G_eff 2.3, L_max 0.6; mnsc.2025.00954 T3_c6 and T8_top3 c1-c4,
  G_eff 1.7-7.8; mnsc.2022.03486 T4A c1-c2, G_eff 6.3, L_max 0.35), including every estimate that drove the correlation
  to 0.06 on Nov 4. The DiD-averaging row of the controls table goes from 105 comparisons / 12 papers / corr 0.06 to 90 /
  10 / 0.80 (flips 28.9, significant 14.4, SE ratio 2.46); the imputation row is unchanged (100 / 11 / 0.99).
  Bug fixed on the way: in event-study files the all-NA leverage columns are read as logical and := coerced the numbers to
  TRUE (13 files); run_spec.R now coerces the columns to numeric first.
  (q2) Open items closed on Nov 4 (items 1 to 3 approved): mnsc.2022.03186 Table 4 now drops switch-off rows
  (ruling (d) activated; TWFE -12.87, authors'-settings CSA -20.84 raw on 16,962 rows, matching the Stata target;
  the published-CS appendix table uses the authors' re-run on that sample as the reference, with a note). Near-miss
  hand checks (agent, records backed up in backups/screening_nov4/): 11 records coded under the earlier rule checked,
  9 added as near-misses (3 controls-only), 2 left out; the 6 classifier/screener disagreements on "controls only"
  settled record by record (3698 and 4972 controls-only; 02805 and 4886 not; 3579 not a near-miss; 4961 excluded by
  rewording "No staggered binary adoption", which the keyword filter had matched); nNearMiss 112 -> 119. The three
  unassessable records were re-screened on Nov 4 evening from the correct published articles (backups in
  backups/screening_nov4_three/): 00222437231222857 (JMR safety-training paper) not eligible (single adoption date; the
  other design has no unit FE); mksc.2021.1329 (CARES Act stimulus paper) an eligible design through the ten Figure 7
  re-estimates of Broda and Parker's rebate model (household and week FE, weekly IRS cohorts; verification note in the
  record), data not shipped: the INFORMS archive for this DOI holds another paper's files (byte-identical on two
  downloads, a journal-side mislabeling); mnsc.2022.03733 (mutual-fund climate voting) a near-miss (stacked design with
  time-varying controls), complete package re-downloaded and unpacked, ISS/CRSP/Compustat not shipped. The unsourced "120/552/3/101 DiD articles" sentence was removed. Published PDFs obtained for all
  58 replication papers and all 148 near-miss papers that lacked one (routes in the session memory), supplementary
  files for 48 of 58 replication papers (10 have none), texts regenerated (267 were stale). Appendix count (three
  agents, scratchpad appx1-3): printed appendices would add about 89 table specifications from 6 of 45 papers, 70 of
  them replicable on real data (9 + 9 from mksc.2022.1353, 22 variants from mnsc.2021.02026, 36 variants from
  mnsc.2025.02515, 3 from mnsc.2023.4716), and one paper; 39 papers print no appendix regression. Outcome (Nov 4 evening): 76 printed-appendix specs replicated and bootstrapped (9 mksc.2022.1353 Table B.1; 22 mnsc.2021.02026 Tables D.1, E.4-E.6; 45 mnsc.2025.02515 Tables C.3, C.5, C.6 and Figures C.1-C.3, C.4 not built; mnsc.2023.4716 Table A.3 ineligible, pair-level post main effect). Appendix run (paper/tables_appx): 377 DiD-averaging and 365 imputation comparisons from 31 and 30 papers, correlations 0.57 and 0.72 (main 0.61 and 0.70), flips 27.1 and 19.2 percent (27.4 and 18.0), paper-weighted 19.9 and 16.8 (20.1 and 16.4): conclusions unchanged.
  Decision (Nov 4: report the appendix-specification results in a paper appendix): the main analysis keeps
  Hull's main-text rule; a paper appendix repeats the comparison on the sample enlarged by the specifications printed in
  the articles' appendices (online supplements excluded; synthetic-data and non-replicable ones excluded). Mechanics: spec
  JSONs in data/specs_appendix/ with appendix_printed = true (mksc.2022.1353 Table B.1, 9; mnsc.2025.02515 Tables C.3-C.6
  and Figures C.1-C.3; mnsc.2021.02026 Tables D.1, E.4-E.6; mnsc.2023.4716 Table A.3), run with CSA_STRICT_HULL=1
  OUT_DIR=output_appx (authors' settings to output_appxB for the printed-value check); analysis.R with APPENDIX_SPECS=1
  TABLES_DIR=paper/tables_appx OUT_TABLES=output/tables_appx MACRO_SUFFIX=Appx writes the enlarged-sample tables and
  macros (\corrCSAAppx etc.) without touching the main ones.
  New in the paper: Table 1 analog (code/23_characteristics.py), replication-status counts (label-based: 258 exact,
  83 approximate, 14 documented deviations, none failed), software mix, adoption-by-year appendix table, correlates
  and sharp-divergence paragraphs (macros nBig*, shareBig*, corrNever*, corrYear*), paper-clustered bootstrap SEs for
  the hierarchical model (HIER_BOOT=1, cached in output/tables/hierarchical_boot.csv).
  Cross-check of the cell path on a real spec (Nov 4, 06:53): the did package run alone on the server with a 300 GB cap
  (mnsc.2025.00954 T8_top3_c1, 2h15m, 36 GB) gives 2.0846609885 (SE 0.9728167873); the cell path stored in
  output/specs_controls gives the same estimate and standard error to 1e-13. Output kept on the server in
  output_fulldid_solo/ (not installed: the stored cell-path file already carries the leverage).
  (r) Main-text rule applied to mksc.2022.1353 (Nov 4): the published article, obtained Nov 4 (the project copy had been the
  2021 MPRA working paper), prints the staggered two-bin regressions only in Appendix B (Tables B.1-B.2); the main text
  discusses them in words and its own regression table is a single-date matched DiD. Hull's rule ("in the main text,
  including tables, figures, and text discussions") excludes them, so all 18 specs moved to data/specs_excluded/ and the
  paper is neither eligible nor a near miss (no main-text staggered regression). A printed appendix is not main text.
  The T11a reverse-event question is moot. Same rule for every paper: specifications reported only in an appendix,
  printed or online, do not qualify.
  (s) Printed values of mnsc.2020.01838 (Nov 4): the 21 static specs of Tables 2, 4 and 5 had
  published_coef = null because the article was unavailable when they were coded (replication graded against the authors'
  Replicate.R output). With the article obtained Nov 4, the printed coefficients, SEs and N were entered from Tables 2
  (16 columns), 4 (Panel A, 4 columns) and 5 (column 1); every printed coefficient and SE equals the code output rounded to
  the printed decimals (checked programmatically before writing). Table 4 columns (2a) and (2b) print N 149,874 and 149,825
  against 149,138 and 149,089 in the code output; recorded in published_source. Backups in
  backups/specs_01838_pubvals_20261104/. Effect: "no printed value" 48 -> 27 (all 27 are event studies shown only in
  figures: 12 mnsc.2022.01820, 9 mnsc.2020.01838, 4 mksc.2023.1437, 1 mnsc.2021.02026, 1 mnsc.2023.4968); number-based
  grades of the 21: 9 exact, 11 approximate, 1 failed (T2 column (16): printed -0.005, protocol TWFE -0.0069), from the
  protocol's sample changes (pre-sample adopters, anticipation bin); code-rerun labels unchanged (all exact). The
  published_coef/published_se columns of output/specs/*.csv for these specs were patched to the same values (run_spec.R
  copies them from the JSON; nothing downstream reads them).
  (t) Printed reference values for every main-sample spec (Nov 4 evening): a process-claims audit found that ~166 of the 355 main-sample specs
  had published_coef taken from the authors' shipped logs, output files, code re-runs, a manuscript or a README because the
  article text was not in the project when they were coded, 13 specs of two papers had replication_status "pending" with
  no replication log, and no "digitized" flag existed. Five agents (Fable) then: (1) mnsc.2022.4394: all 64 specs verified
  against the printed Tables 5-15 (t-statistics printed, so published_se = null and published_tstat / published_event_tstat
  added); all equal the shipped logs at the printed decimals -> exact. (2) mnsc.2020.3626 (9) and mnsc.2022.01333 (4): the
  authors' code re-run (Stata/MP 16.1; R didimputation for the two BJS columns, did_imputation.ado unavailable offline)
  reproduces every printed value exactly; logs written; 3626 `table` fields moved to the published numbering (do-file blocks
  2/3/5/6 = printed Tables 4/5/7/8) with table_note. (3)-(5) 23 further papers, ~100 specs: printed values entered from
  data/text or the PDF page, the authors' code output preserved in authors_code_coef/_se/_n (event studies:
  authors_code_event_coefs/_se), published_source rewritten, replication_status first word set by the stated rule (exact at
  the printed decimals; approximate = same sign within 10 percent; failed otherwise). Conventions fixed on the way: event-study
  published_coef = equal-weight mean of the printed post bins covered by event_structure.post_summary, bins in
  published_event_coefs; estimates shown only in a figure (no number in the article) have published_coef = null (figure-only;
  mksc.2022.1409 F1 x9, mnsc.2023.01423 F4/F5 x4, mnsc.2021.03484 F2, mnsc.2023.01390 rating effect, whose number is only
  in the online Web Appendix); numbers printed in the article's own appendix count as printed (mnsc.2021.02026 Figure 4 =
  Appendix Table D.1); online supplements do not. Table numbers in spec `table` fields now follow the article where the
  code numbered tables differently (mnsc.2023.4816 code 7/8 = printed 10/11; mnsc.2022.4326 code 4/5/6/12 = printed
  5/6/7/14), with table_note. Rulings on the non-exact cases: mnsc.2021.02026 (10 percent random seller sample) re-labelled
  failed for 10 of 11 specs by the stated rule (the shipped full-data log equals every printed value; the subsample re-run
  misses by 9-928 percent, five sign changes); mksc.2022.1356 Table 6 cereals failed (10.7 percent, transformed prices);
  mnsc.2023.4968 Table 5 col (7) prints 1.004 against its own t = -0.06 while the code gives exp(b) = 0.998 with the same
  t -> recorded as printed, failed, probable typographical error; mnsc.2021.03484 Table 6 Panel C: the printed column (2)
  adds time-varying controls, the spec is the authors' unprinted no-controls regression est1 -> published_coef = null (open
  open question: whether an unprinted regression qualifies as "reported"). New spec field replication_reason
  (random_subsample | altered_data | package_version | rounding | other) read by code/23_characteristics.py, which writes
  nReplApprox{Sub,Altered,Version,Rounding,Other}(Papers) and nReplLabelNonExact. Outcome: label-based exact 333,
  approximate 10, failed 12 (reasons: random subsample 15 specs / 3 papers, altered data 3 / 3, package version 2 / 1,
  truncated print 1, printed sign error 1); number-based (protocol TWFE vs printed): exact 207, within 10 percent 46,
  beyond 60 (10 subsample), no printed value 42. Backups: backups/specs_pubvals_20261104/<suffix>/. Per-spec tables in the
  session scratchpad (pubvals_4394.md, pubvals_groupA/B/C.md, pending_3626_01333.md); every log has a dated
  "verification against the printed article" section.
  (u) High-cardinality characteristics leave ALL estimators (Nov 4 evening: option (b), stated in the paper). Until Nov 4 a time-invariant characteristic with more than XT_MAX_LEVELS = 60 categories was dropped from
  DiD-averaging only (estimators.R expand_xt, note xt_ignored_highcard; 46 output files: mnsc.2020.01838 x30 naics4 with
  244-264 levels, mnsc.2022.02310, mnsc.2023.00900, mnsc.2023.04090, mnsc.2025.03238, and the synthetic mnsc.2024.04716 x11),
  while TWFE and imputation kept the authors' industry-by-year effects. A diagnostic on mnsc.2020.01838 (scratchpad xt_test,
  copied to output/xt_check/specs/; code/24_xt_check.py summarizes it) showed: (A) all 260 four-digit dummies in did's cell
  regressions: every one of the 722 cohort-by-period cells rank-deficient, no estimate, in all 8 Table 2 Panel A specs;
  (B) two-digit sectors (24): runs, DiD-averaging SEs about three times larger, point estimates unstable; (C) no industry
  effects in any estimator: TWFE and imputation move by at most 0.13 SD, but in the cartel-breakup designs TWFE changes sign
  (-0.10 -> +0.03), matching DiD-averaging, so 6 of the paper's 9 TWFE-vs-DiD-averaging sign reversals (24 passing
  comparisons) came from the covariate asymmetry, not from the estimator. Options considered: (a) treat these comparisons
  as "no DiD-averaging estimate"; (b) drop the characteristic from all three estimators (like-with-like; TWFE is then not the
  published regression); (c) keep and describe; (d) imputation and its TWFE keep the controls, DiD-averaging is compared with
  a TWFE that drops the characteristic. Option (b) was chosen first, then, on the point that imputation can carry the controls, (a): NO
  DiD-averaging estimate for specifications with such a characteristic; TWFE and imputation keep the published regression.
  Implementation: run_spec.R preamble (before the LEVERAGE_ONLY cut, so boot_cov.R inherits it) removes any xt with more than
  XT_MAX_LEVELS categories (0/1 indicators exempt) from ALL estimators only when XT_DROP_ALL=1 (environment; default off =
  previous behaviour, DiD-averaging alone drops it via expand_xt), recording xt_dropped_all_highcard in the output row and
  "xt_dropped_all_highcard:<var>(<levels>)" in csa_note. The 45 current specs with such a characteristic (the 46th output,
  mnsc.2025.03238 F2_SA_dynamic, is an orphan of an excluded spec) were re-run with XT_DROP_ALL=1 on the Mac (run_spec.R
  then boot_cov.R with 999 draws, three rslot lanes, logs/xt_rule/) and the results stored in output_xtdrop/{specs,boot_cov};
  output/ keeps the published-regression outputs (restored from backups/xt_rule_20261104/, which also holds the bootstrap
  chunks). analysis.R (block after d <- dHA): rows whose csa_note matches "xt_ignored_highcard|xt_dropped_all_highcard" get
  csa, csa_se, csa_fc, cov_twfe_csa set to NA with ";csa_dropped_highcard_xt" (main d and d_auth), after storing two checks
  computed with compare(): res_xasym (the old asymmetric comparison on those rows) and res_xlike (output_xtdrop rows merged
  with the main run's paper metadata, TWFE leverage from the controls-free TWFE); macros nXtHighcardCmp, nXtLike(Papers),
  corrXtLike, flipXtLike, sigflipXtLike, nXtAsym, corrXtAsym, flipXtAsym, sigflipXtAsym (corrCSAxhc/flipCSAxhc/nCSAxhc
  retired). code/24_xt_check.py keeps only the variant facts (xtFullRankDef 8 of 8, xtTwoDigitSeRatio 3.5) in
  paper/tables/xt_check_numbers.tex. Outcome (Nov 4 evening): 43 rows / 34 specs / 5 papers lose their DiD-averaging estimate,
  35 of which would have passed the screen; main DiD-averaging comparisons 318 -> 283 (30 -> 28 papers), sign reversals 27.4 ->
  25.1 percent; the checks: asymmetric corr 0.82, 45.7 percent reversals; like-with-like corr 0.90, 25.7 percent. Snapshot of
  every result file before this change: backups/results_pre_xtrule_20261104/ (README with the revert steps). The flagged 02310 spec is T4_c1_ev0 (xt `cas`, 573 levels), not an
  option-A spec, so both checks use the same CSA for it. Code review of the change (Fable, Nov 4 late; scratchpad
  code_review_nov4_late.md): no bug affecting a reported number; fixes applied: Dropbox conflict copies ("<name> 2.csv", 10
  files) in output_xtdrop renamed and duplicate guards added to the output_xtdrop and output_hullA read paths; new macros
  nXtHighcardPapers (papers losing comparisons, from the main sample) and nXtHighcardBJS (4 of the 43 flagged rows pass the
  imputation screen; 34 carry lev_bjs_inconsistent, so the text no longer says imputation carries the controls "without
  difficulty"); the rule also nulls the synthetic sample's DiD-averaging for flagged rows (no numeric effect); XT_DROP_ALL
  level counts taken after the NA-treatment drop; approx_reason() patterns with word boundaries and altered-data tested
  before version; 24_xt_check.py parses variant names with a regex.
  (v) Late paper review (Fable, Nov 4; scratchpad review_nov4_late.md, 16 items) and its fixes: (1) imputation on the
  high-cardinality rows: 31 of the 35 TWFE-screened rows carry lev_bjs_inconsistent, only 4 enter the imputation comparison;
  text and macros nXtHighcardBJS / nXtHighcardBJSinc. (2) Figure-only convention applied to mnsc.2025.02515's 12 Figure 3 event
  studies (published_coef null, code output in authors_code_*), so no printed value = 54 specs; appendix.R rerun: published
  Callaway-Sant'Anna estimates reproduced for 52 of the 54 with a printed value (was 74 of 76 before the figure-only nulling).
  (3) Section 2.4 now separates the 54 without a printed value from the 301 with one (279 exact, 22 with a documented reason;
  macros nReplPrinted, nReplLabelExactPrinted, nReplNonExactNoPrinted = 0). (4) 23_characteristics.py grades the GDPR Table 4
  Callaway-Sant'Anna specs against authors_rerun_csdid_dropoff_coef as appendix.R does: number-based failures 60 -> 54.
  (5) Downloads: the server returned 1,070 files (727 candidates, 343 others), macros nPkgFiles / nPkgNonCand from the
  manifest in 15_tables.py; "predate the policy" softened to "most articles published before the policies took effect".
  (6) Two-digit variant: 4 of 722 cells estimated (xtTwoDigitCellsUsed/Cells), SE ratio relative to the no-characteristic
  estimator. (7) Intro contribution list no longer names "short windows" or "few cohorts" (not documented in Section 4).
  (8) Stale Appendix A bullets (reference values; working-paper rechecks done; appendix specs analysed in Appendix I), Table 14
  note, Appendix F sentence (Section 4.5 exists), "between a third and a half" vs 54 percent, median cohorts wording,
  "\citet{}'s settings" possessives, equal hFlip values ("28.0 percent for both estimators", macro hFlipText), "100.0 percent"
  -> "all" (shareBigNoNeverBJStext), two to four years, \citealp inside parentheses, \clearpage before Appendix I,
  mnsc.2023.4968 F5_es note updated. Verified consistent by the reviewer: all DiD-averaging numbers, funnel, near-miss counts,
  LOO ranges, Hull benchmarks, Appendix I counts, paper list sums.
  (w) Prose pass (Fable academic-editor agent against the project style guide and three of the PI's published papers; 75 items): 79 string replacements
  applied, no number, macro or citation changed. Main ones: abstract ("We ask whether negative weights change published
  findings", "large language model agents", leverage screen glossed, "sizable share"); intro results preview split into three
  paragraphs with the Hull benchmark next to the rates it benchmarks and the near-miss counts left to Section 4.5; JMR
  reason stated ("its repository is restricted by default"); contributions trimmed ("systematic", the mislabeled-archive
  clause); Section 2.4 split into three paragraphs, the replication accounting restructured ("fall into five groups"),
  "our replication logs" vs the authors' packages, software sentence moved up, four "where" clauses unwound; Section 3
  covariate paragraph in short sentences, leverage screen "described below", totals paragraph separated; conclusion opens
  with what the paper does ("We draw three conclusions"), "heterogeneity-robust estimators cost precision", and a closing
  limitations-and-implications paragraph (single papers move the statistics, candidate search not exhaustive, report a
  robust estimate alongside TWFE); Section 4 reorderings (concern before result), "sign reversals" everywhere including
  the Figure 2 legend (analysis.R fig2 labels), "exit that depends on the outcome", one convention for standard errors;
  appendix wording (our repository vs packages, "problem too large for the did package", csdid named for pair-balanced
  cells, generated Table pubcs note). Not applied: S1 (the "43 full texts" sentence was not found verbatim), S6 ("for some
  specifications": the condition behind the flags is not recorded), I10 (roadmap; removed), item 5 of the
  cross-cutting list ("his" density; judgment).
  Decision 2 (same message): the mnsc.2021.03484 Table 6 Panel C spec (the authors' unprinted no-controls regression est1)
  stays in the sample; its published_coef is null (the printed column adds time-varying controls).
  Author requests (Nov 4 evening): 44 papers have an eligible design and no usable data in the archive
  (18 synthetic or disguised, 25 analysis data not shipped, 1 usable data whose package does not reproduce); list written to
  the session scratchpad (author_request_candidates.csv). No author has been contacted (ruling (t), audit).

  (x) Full-text coverage and second-opinion screens (Nov 5, 2026). Decision: every article in the frame of all
  seven journals gets its full text on disk, not only the candidates. Routes: Management Science from pubsonline with the PI's INFORMS login
  (one file per 20-35 s at most; a burst of about 120 files in 15 minutes on Nov 5 got the session cut); Marketing
  Science, ISR, M&SOM, Organization Science and Operations Research from EBSCO Business Source Complete through the USC
  library proxy (DOI search, PDF viewer, Download); JMR from SAGE through the proxy. Files are identified by the DOI
  printed in the PDF and filed under papers/<journal>/<suffix>.pdf with text in data/text/<journal>/. Second-opinion
  re-screen of Marketing Science: all 128 candidates outside the eligible set were re-read in full by fresh Fable readers
  with no access to the first verdicts (data/screening/second_opinion/mksc_rescreen_nov5.json): 100 ineligible, 26
  near-miss, 2 borderline eligible (mksc.2017.1043 Table 9 triple difference with responding-by-month effects;
  mksc.2019.1176 Equation 1 with additive demographic dummies). Both borderline cases fail the rules on a strict reading
  (treated-status-by-time effects; other nonredundant additive fixed effects) and stay near-miss unless ruled
  otherwise; 16 papers move from ineligible to near-miss and 2 previously unscreened papers enter as near-miss, to be
  folded into the funnel table once the other journals are screened. Eligibility screen of ISR, M&SOM, Organization
  Science and Operations Research candidates from full text (no packages exist):
  data/screening/other_journals/<journal>_screen_nov5.json; ISR wave 1 (68 of 225 candidates): 4 eligible designs, 20
  near-miss, 44 ineligible, none with public replication materials. Two INFORMS replication packages are served under
  the wrong DOI (mksc.2021.0292 holds Numerator grocery files; mksc.2021.1329 another paper's files).

  Addendum to (x), Nov 5 afternoon: 13 Management Science candidates without a package state that data files are
  available at their DOI, and their article pages link to replication files, but the dataset server's signed S3 link
  returns 404 for every one (data/packages/advertised_but_missing_nov5.json; verified by hand for mnsc.2023.02789).
  They count as "analysis data not shipped" in the funnel, and the archive audit gains a category: advertised files
  missing on the server. Three of them have eligible designs (mnsc.2023.02789, mnsc.2024.05073, mnsc.2022.02462).
  Opus full-text screen of the 74 Management Science candidates that had no package
  (data/screening/other_journals/mnsc_nopackage_screen_nov5.json): 5 eligible designs, 28 near-miss, 41 ineligible.
  ISR screen now covers 202 of 225 candidates: 14 eligible designs, 61 near-miss, 127 ineligible, none with public
  materials.

  Final other-journal screen (Nov 5, 15:00): ISR 206 of 225 candidates read, 14 eligible designs, 62 near-miss, 130
  ineligible; M&SOM 105 of 107, 5 / 25 / 75; Organization Science 150 of 151, 8 / 43 / 99; Operations Research 13
  of 18, 0 / 0 / 13. None of the 27 eligible designs posts data or code. Unread candidates are those EBSCO does not
  index. Verdict files: data/screening/other_journals/<journal>_screen_nov5.json. Readers: Fable for ISR wave 1-2,
  Opus for the rest (cheaper model for first-pass screens, Nov 5).

- Addendum (Nov 5, 14:30), funnel consolidation: code/15_tables.py now merges the text screens into the screening
  records (load_screening): every verdict in data/screening/other_journals/*.json (ISR, M&SOM, OrgSci, OR candidates and
  the 74 Management Science candidates without a package) becomes a record with screened_from = "article_text",
  data_files_present = false and data status "no package"; the Marketing Science second opinion
  (second_opinion/mksc_rescreen_nov5.json) adds a near-miss flag to the 14 first-screen "ineligible" records it relabels
  and supplies records for the 17 candidates the first screen never reached (2 near-miss, 15 ineligible). Its two
  "eligible" relabels of first-screen near-misses are not applied. Ruling (Nov 5): mksc.2017.1043 stays a
  near-miss and is not added to the sample. Its Table 9 DDD is the only column set without controls, and the within-platform
  specification (Eq. 6, Table 11; code: xtreg stars first_response t_review_stay t_review_stay_2 c.treated#c.t i.t, fe) has
  time-varying controls plus a treatment-status linear trend, which keeps it out of the main sample and of the 5c appendix.
  mksc.2019.1176 stays a near-miss as well; its data are disguised, so it could not enter the sample in any case. code/17 and code/20 read the merged records, so the near-miss appendix includes the text-screened
  near-misses of the three replication journals; Table 3 counts the other journals' near-misses from the screener flag.
  Effect: screened 1,149 -> 1,240; eligible designs 84 -> 89 (5 MS designs with no package, 3 of them advertised-but-
  missing); near-misses 120 -> 163 (MS 102 -> 130, MKSC 16 -> 31); other journals 474 screened, 27 eligible, 130
  near-miss, 27 candidates not yet screened (no text in EBSCO). 118 candidates remain unscreened (87 MS, 4 MKSC, 27
  other); they are screened in one Opus batch once the EBSCO queue has delivered the candidate texts.

- Addendum (Nov 5, ~16:50), final candidate screen: once the EBSCO queue had delivered the candidate block, the 92 still-unscreened
  candidates with a text were screened from the article alone by nine Opus agents (scratchpad screen_final/, brief = the
  no-package brief): Management Science 85 (3 eligible, 19 near-miss, 63 ineligible), Marketing Science 2 (ineligible),
  Operations Research 5 (ineligible). The three eligible designs (mnsc.2019.3560, mnsc.2020.3878, mnsc.2022.4602) rest on
  commercial or proprietary data with no availability statement and no package on the INFORMS server (fetch retried), so they
  enter the funnel as "no replication package" and add nothing to the re-estimation sample. Agents noted that many article
  headers say "data files are available at the DOI" although the server returns 404 (same defect as the 13 of the afternoon).
  Of the 26 candidates without a text, 16 are front matter (research spotlights, editorials, issue introductions, student
  abstract collections, "Focus on Authors"): recorded as ineligible from the item type and title, without a text. The other
  10 are research articles EBSCO's DOI search did not return; 7 were fetched by record id or title (6 ISR, orsc.22.16956)
  and screened separately (batchF_10: ISR 3 near-miss, 3 ineligible; orsc.22.16956 near-miss; isre.2020.475 is EBSCO's
  isre.2020.0475). Three ISR articles of vol. 29 (2018), isre.2017.0749, isre.2017.0750, isre.2017.0752, are in neither
  EBSCO (DOI and title searches) nor the USC proxy to pubsonline (403 on the PDF), so they remain the only "not screened"
  candidates. A first title-search attempt had filed a wrong 1981 scan under isre.2017.0752; it was deleted. Verdicts
  appended to data/screening/other_journals/{mnsc,mksc}_nopackage_screen_nov5.json and the opre/isre/orsc files.

- Addendum (Nov 6, 01:50), full-text download complete: the EBSCO queue of 3,750 items (candidates of the four
  other journals, then the Marketing Science and Management Science frames) finished at 01:20. 3,711 PDFs were
  delivered; 39 items EBSCO does not index ("not in ebsco" after DOI and title searches): 5 Management Science
  (mnsc.2021.4001, 2024.07272, 2025.00332, 2025.01032, 2025.05353), 30 Marketing Science (mksc.1120.0769, 29 of
  2013-2018 incl. mksc.2013.0819 "Focus on Authors", the only candidate among them, front matter), and the 4 ISR items
  already recorded (the three vol. 29 articles and isre.2021.1037, a research spotlight). Reconciliation against the
  frame (scratchpad reconcile_texts.py): 10 items the runner marked done had no file on disk (9 Marketing Science
  PDFs that never landed, among them the candidates mksc.2023.0345, mksc.2019.0208, mksc.2022.0212, mksc.2022.0245,
  mksc.2023.0482, mksc.2023.1440, and mnsc.2022.03849, whose Nov 1 pubsonline file was truncated and unreadable); all
  10 were refetched from EBSCO and extracted. Texts on disk: Management Science 3,242 of 3,197 frame articles plus
  supplements (all 760 candidates), Marketing Science 881 of 907 (all candidates except the front-matter item), JMR
  500 (all 73 candidates), ISR 212 of 225 candidates, M&SOM 105 of 107, Organization Science 151, Operations Research
  18. The frame articles without a text are non-candidates except the three ISR 2018 articles and front matter.
  Nov 6, 06:05: the 5 Management Science articles EBSCO lacks were fetched
  from pubsonline with the PI's INFORMS session (one file per 22-30 s, DOI verified in the PDF), so the Management
  Science frame is complete (3,197 of 3,197; mnsc.2021.4001 is a 2-page editorial). The residual of the full-text
  policy is the 30 Marketing Science articles of 2013-2018 EBSCO does not index (the PI's membership does not cover
  Marketing Science on pubsonline) and the 4 ISR items.

- Nov 6, ~17:00: the synthetic-data appendix is removed from the paper. Only 4 of the 18 eligible papers with
  synthetic or disguised data had been run (one on Nov 1 before the exclusion rule, three on Nov 2 for the appendix), the
  other 14 never had specifications extracted, and estimates on synthetic files say nothing about the published designs.
  Rather than extract and run the remaining 14, the appendix, its Table, the Table 5 footnote and the pointers in Section 2.3
  and Appendix A are deleted; the 18 papers remain in the funnel as eligible designs with synthetic data. The paper list
  (appendix.R) now covers the 40 papers re-estimated on original data and drops the "Package data" column.
  output/specs_synthetic.csv and tables/synthetic_comparison.tex are still written by analysis.R but are no longer used. The screening
  verdict files did not change after the ~16:50 screen, so the funnel numbers of the 17:35 regeneration are final:
  screened 1,331 (candidates 988, all screened; 182 Management Science and Marketing Science candidates from the text
  alone), eligible designs 92 (8 without a package), near-misses 186 (14.0% of screened), other journals 498 screened,
  27 eligible, 134 near-miss, 3 not screened.
- Nov 7: Hull provided a revised split of his Figure 2 correlations by panel type (hulls-corrs-v2.jpg; supersedes
  hulls-corrs.jpeg): DiD-averaging 0.933 in balanced panels (457 comparisons) and 0.876 in unbalanced panels (614);
  imputation 0.963 (430) and 0.909 (669); unbalanced minus balanced -0.057 [95% CI -0.144, 0.031] and -0.055 [-0.144,
  0.022]. His note: the differences are not statistically significant, and the ordering reverses when estimates are
  normalized by the TWFE standard error (his figure coordinates) instead of the outcome standard deviation (his annotated
  correlations, and every correlation in this paper). The table's pooled column (0.889 on 1,205; 0.930 on 1,254) does not
  match the published Figure 2 (0.881 on 1,069; 0.930 on 1,116; the two panel types sum to 1,071 and 1,099), so the paper
  keeps the published pooled benchmarks and uses the split only for the balanced/unbalanced comparison in Section 4.6
  (0.87 -> 0.88 for unbalanced DiD-averaging). For comparison, our own gap (paper-cluster bootstrap, 999 draws,
  code/R/bal_unbal_check.R) is -0.45 [-0.66, 0.20] for DiD-averaging and -0.43 [-0.88, -0.11] for imputation in outcome-SD
  units, and the balanced panels stay more correlated under TWFE-SE normalization (0.79 vs 0.42; 0.97 vs 0.39).

- Addendum (Nov 10, 2026), Journal of Marketing and Quantitative Marketing and Economics join the frame. decision: "what do we need
  to do to att qme and jme to the list of papers *add" ... "ok let's start doewnload what we need" ... "ok let's continue". Frame: OpenAlex sources
  S142990027 (JM, 2015-2026, 681 records, 614 articles) and S4210206015 (QME, 2015-2026, 149 records, 142 articles);
  code/01_openalex_frame.py and code/04_citation_flags.py now take journal keys as arguments and replace only those journals'
  rows (frame 10,886 rows; cites.csv 419 rows). Full-text hits: JM from the SAGE search engine through the USC proxy
  (SeriesKey=jmxa, the eleven queries, 109 unique DOIs, data/hits/readout_jm.txt, full DOIs accepted by 02b); QME from the
  article texts on disk (the eleven queries as regular expressions, scratchpad qme_text_hits.py -> data/hits/raw/qme__*.json,
  "source": "local text search"), because the Springer search engine is not query-stable. Candidates (tier <= 3): JM 90
  (21 / 56 / 13), QME 20 (6 / 14 / 0). Full texts: JM candidates from SAGE (journals.sagepub.com, 86 PDFs
  on Nov 10 plus 18 fetched earlier; all 90 candidates), QME whole frame from Springer (link.springer.com,
  141 PDFs); each file is named by its DOI suffix and the DOI is verified in the PDF text before filing (scratchpad
  filer_jmqme.py). Screening: 13 Opus readers (10 papers each at most) screened the 110 candidates from the article text with
  the no-package brief (scratchpad jm_screen/brief.md); every eligible or near-miss verdict and the four borderline
  "ineligible" calls the readers flagged (32 papers) were then re-read blind by 7 Fable readers (brief_second_opinion.md,
  data/screening/second_opinion/jm_qme_rescreen_nov10.json). Agreement 31 of 32; the one disagreement (00222429251363144:
  first read near-miss, second read ineligible because the main design has a single policy date and the staggered CSA run
  rests on a "small portion" of late converters) is resolved to the Fable read, the rule for this round. Verdicts:
  data/screening/other_journals/jm_screen_nov10.json (90: 3 eligible, 21 near-miss, 66 ineligible) and
  qme_screen_nov10.json (20: 0 / 3 / 17), each record carrying both reads. One JM candidate (00222429241282414, BNPL) has a
  Nov 2 package record (not near-miss) that both text reads call a near-miss (TWFE on a matched sample; logit for incidence):
  the by_paper record now carries near_miss = true with the two reasons (backup backups/screening_nov10/). Eligible JM
  designs: 00222429251351859 (household TWFE on a binary at-home-internet indicator, household and year FE, six outcomes;
  licensed NielsenIQ data, no package) and two Callaway-Sant'Anna cases that await the PI's ruling and are recorded with
  ruling_pending: 00222429261436003 (doubly robust CSA with propensity reweighting on pretreatment covariates, six outcomes
  with SEs in Table 4; disguised data in a restricted JM Dataverse deposit) and 00222429261507094 (CSA ATT reported in prose
  with a p-value only, no SE, N, covariates or comparison group; licensed data). Neither can be re-estimated, so the ruling
  moves only the "eligible staggered design" count of JM. Ruling (decision, Nov 10, "ok with your reccs"): 00222429261436003 eligible (CSA with pretreatment covariates admitted), 00222429261507094 near-miss (CSA reported in prose only, design not verifiable), so JM has 2 eligible designs and 22 near-misses. The near-miss appendix memo row "No staggered binary design" keeps its all-journal definition (152 -> 160). None of the 110 candidates posts analysis data. Code:
  EXTRA in code/15_tables.py adds jm and qme; journal_of() maps s11129- suffixes to qme; macro \nJMdeposits (21) keeps the
  Nov 2 deposit count while \nJMscreened (107) now includes the text screens; code/22 shows JM's non-candidate deposits (17)
  and its synthetic/disguised row. Table 3 has nine journal columns and needs \footnotesize with 3pt column separation in
  the wrapper (main.tex edit proposed to the PI). Funnel after the rerun: JM 614 / 90 / 107 screened / 3 eligible (1
  disguised, 2 no package) / 21 near-miss; QME 142 / 20 / 20 / 0 / 3; other-journal totals 611 candidates, 625 screened, 30
  eligible designs, 158 near-misses. The re-estimation sample (40 papers) is unchanged.

## 6. Access and ethics constraints

- INFORMS download terms restrict use to verifying replicability "using the same data and
  model(s)". The PI reports (Nov 1, 2026) having obtained the permissions needed for
  this use. Keep a note of the source of permission in the project records.
- JMR Dataverse files are restricted by default; contact authors.
- Papers authored by project members are included (decision of Nov 1, 2026) and
  will be disclosed in the paper.
- Reverse events (e.g., cartel breakup after cartel formation): a "switch-on" of the reverse state is an
  eligible staggered treatment only when it is estimated in its own regression with a single treatment
  indicator and the sample for treated units starts at or after the first event (so the untreated state
  is homogeneous). Regressions that include both the forward and the reverse indicator, or whose sample
  mixes pre-formation and in-cartel periods as "untreated", fall under the extra-treatment rule (near-miss).
  (mnsc.2020.01838 breakup columns, Nov 1.)
- Exposure treatments (e.g., a competitor's adoption): eligible as a distinct treatment definition only if
  the regressor is binary and absorbing; counts or shares of exposed competitors are continuous treatments
  and excluded.
- Policy removals at unit-specific dates (e.g., repeal of an ID requirement) are staggered adoptions of
  the removal and count as eligible designs; columns with interactions, trends, or time-varying controls
  remain near-misses (mnsc.2022.4580).
- Designs without unit or treated-group fixed effects (e.g., only city x cohort x day FE) are not TWFE
  and are excluded (mnsc.2024.05301).
- Entropy-balancing weights (ebalance) are covariate-balancing weights of the same class as inverse-propensity
  weights: NOT eligible as analysis weights; columns using them are near-misses (mnsc.2022.00953, mnsc.2023.4780).
- Cohort-by-time fixed effects where the cohort is the unit's own adoption date (so that comparison units are
  assigned to adoption cohorts) constitute a stacked design and are NOT eligible, even though the cohort is a
  time-invariant unit characteristic; this supersedes the group-by-time reading used for mnsc.2022.03770
  (synthetic data, appendix only; record to be re-checked). Only columns with plain unit and calendar-time FE
  qualify (mnsc.2021.4092: Table 7 only).
- Placebo specifications with artificial adoption dates are not the published treatment and are not counted.
- A single rule that takes effect in the same fiscal year for every unit, with calendar dates differing only
  by fiscal-year end and time FE defined at the exact adoption date, is a single-policy design, not staggered
  adoption (mnsc.2022.4515: not eligible, not a near-miss).
- A "post" main effect for control units built from an artificial common date is an extra treatment regressor
  (mnsc.2023.4774: near-miss).
- New journals (Nov 1 hosting check, data/newjournals_hosting.md): ISR and M&SOM have no data/code policy and
  post no packages; Organization Science requires third-party archiving only for submissions after Aug 1, 2025;
  Operations Research posts zips on pubsonline (browser session required) for a few dozen recent papers. These
  journals therefore enter the study through the search frame and author outreach only.

## 5c. Secondary analysis with time-varying controls (decision of Nov 1, 2026)

Reported separately from the Hull-comparable main sample; never pooled with it.
- Sample: near-miss papers whose ONLY violation in a given main-text column is the time-varying-controls
  rule. Columns that also violate another restriction (matching or IPW weights, extra treatment regressors,
  subgroup-by-treatment interactions, unit trends, stacking, extra additive FE, nonlinear models, lagged
  outcomes) stay excluded. Synthetic/disguised data and papers without shipped data are excluded as in 5b.
- Controls: covariates that vary within unit over time, entered additively and linearly, exactly as published.
  Lagged outcomes are not controls (still excluded). Categorical controls are expanded into 0/1 dummy columns
  in a prepared dataset (~/did_packages/_work/<suffix>/). Controls interacted with treatment are excluded.
- Estimators: TWFE with the controls as published; BJS (Gardner two-stage) with the controls in the first
  stage, estimated on untreated observations; Callaway-Sant'Anna with each control fixed at the unit's first
  observed value and passed as a covariate (outcome regression), which conditions on baseline covariates
  rather than adjusting for time-varying ones. In unbalanced panels the composition-fixed CSA cells ignore
  controls (flag "controls_ignored").
  Repeated cross-sections (several rows per unit-period, e.g. households within states): CSA passes the
  observation-level controls to att_gt(panel = FALSE) with the doubly robust estimator (est_method "dr"); the RC
  outcome-regression estimator assumes a stationary covariate distribution and doubled the ATT in a simulation with a
  trending control. Each control is first demeaned within period (weighted), mirroring the year FE in TWFE; SIPP
  measurement breaks across survey panels otherwise shifted covariate means and moved CSA (mnsc.2022.03486: 0.335 SD
  with raw controls and "reg", 0.062 with demeaned controls and "dr", 0.070 without controls). Fixed Nov 1 ~18:15 after
  ctrl-F's diagnosis; all controls specs are re-run centrally with the final code before aggregation.
- Files: spec JSONs in data/specs_controls/ with a "controls" list; run_spec.R writes these to
  output/specs_controls/ (main outputs stay in output/specs/).
- 5c rulings (Nov 1, evening): 5c relaxes ONLY the time-varying-controls restriction. Additive fixed effects on a
  dimension other than unit and calendar time (e.g., opponent FE and week-of-season FE in the NFL game-level
  regression, mnsc.2022.4588 Table 3 col 3) remain excluded rather than being recast as categorical controls.
  A "post" indicator defined for all firms at their own fiscal-year-end adoption date is an extra treatment regressor
  (mnsc.2024.04447 Table 2; same rule as mnsc.2023.4774), so its columns stay out. Appendix-only columns are not
  counted (mnsc.2024.06349 Table C2), as in the main analysis.
- More 5c rulings (Nov 1, evening): unweighted TWFE on a CEM-matched sample is a sample restriction (5b) and qualifies
  (mnsc.2020.03920 Tables 8-9 even columns); CEM analytic weights do not (mnsc.2020.03920 Table 4 col 2, mnsc.2021.4045).
  The mnsc.2024.04716 log's exclusion of a CEM-matched subsample is superseded by this rule (no effect: proprietary data).
  A treated-group linear trend (trend:treated) is a differential trend term, not a covariate, so its columns stay out
  (mksc.2021.1313 Tables 3 and 9).
- 5c rulings (Nov 1, ~18:40, batch G): controls that are plausible mediators (mnsc.2022.03920 Table 7 cols 2-4) are
  kept, because 5c reproduces the published specification, and flagged mediator_controls so they can be dropped in a
  robustness row. A pre-treatment measure taken at the start of each conversation (start_sentiment, mnsc.2022.03920
  Tables 5 and 7) is a control, not a lagged outcome. BJS coverage is reported when cells lack untreated observations
  (mnsc.2022.03920: 31% of treated rows imputable at daily time FE).
