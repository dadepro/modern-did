# Replication instructions (for replication agents)

Goal: for one screened-in paper, reproduce the published TWFE estimate(s) from the
replication package and produce one spec JSON per eligible specification so that
`code/R/run_spec.R` can re-estimate it with TWFE, Callaway-Sant'Anna, and
Borusyak-Jaravel-Spiess imputation.

Inputs
- Screening record: `data/screening/by_paper/<suffix>.json` (eligible specs, tables, columns,
  published coefficients, variable hints).
- Package: `~/did_packages/<journal>/<suffix>/` (README, code, data). Regression commands
  found in the code: `data/packages/<suffix>_regressions.txt`.
- Article text if available: `data/text/<journal>/<suffix>.txt`.

Steps
1. Read the README and locate (a) the analysis dataset(s) used by the eligible
   regressions and (b) the code lines producing the published table columns.
2. If the analysis dataset exists in the package (dta/csv/rds/parquet), use it directly.
   If only raw data plus a data-building script exist, run the script (Stata:
   `/Applications/Stata/StataMP.app/Contents/MacOS/stata-mp -b do file.do` from the package
   directory; R: `Rscript`; Python: `python3`) to produce it. Never modify the authors' files;
   copy to `~/did_packages/_work/<suffix>/` if edits are needed and document them.
3. Verify the TWFE replication: run the authors' regression (or an equivalent fixest/reghdfe
   call) and compare with the published coefficient and SE. Record exact / approximate
   (same sign and within 10 percent) / failed, with notes.
4. Identify the panel structure: unit id, calendar time, first-treatment period (or an
   absorbing 0/1 treatment indicator from which it can be derived), analysis weights,
   cluster variable, and any time-invariant covariates interacted with time FE. Confirm
   at least two adoption cohorts and that treatment is absorbing (if it reverses, note it;
   run_spec.R drops post-adoption periods with treatment switched off).
5. Write one JSON per eligible specification to `data/specs/<suffix>__<spec_id>.json` with
   fields: suffix, spec_id, journal, data_path (absolute), id_var, time_var, y_var,
   treat_var or gvar, weight_var, cluster_var, xt_vars (list), sample_filter (R
   data.table expression or ""), log_y ("" / "log" / "log1p"), published_coef,
   published_se, table, column, static_or_event, preferred (true/false),
   in_abstract_intro (true/false), replication_status, notes.
   If the published regression used controls that make it ineligible but a controls-free
   version is implied by the design, do NOT fabricate a spec; skip it and say so.
6. Run `Rscript code/R/run_spec.R data/specs/<suffix>__<spec_id>.json` from the project
   root for each spec and check the output in `output/specs/`. If the TWFE from run_spec.R
   (in outcome-SD units) differs from the authors' TWFE by more than rounding after
   rescaling by the outcome SD, investigate the sample or FE definition before moving on.
7. Write a short log to `data/replication_logs/<suffix>.md`: what was run, deviations,
   and the mapping from spec_id to table/column.

Constraints: do not install software; do not download anything; do not alter files in the
package directory; keep each paper's work self-contained; report failures plainly.

## Pipeline changes, Nov 1 (evening)
- Event-study specifications now carry `G_eff` and `L_max` computed from the influence coefficients of the
  TWFE post-window average (`event_leverage_core` in estimators.R). Before this fix event rows had no
  leverage statistics and were dropped from the comparison. Existing outputs were patched with
  `LEVERAGE_ONLY=1 Rscript code/R/run_spec.R <spec.json>` (code/patch_event_leverage.sh).
- The Callaway-Sant'Anna size guard can be relaxed with the environment variables `CSA_MAX_CELLS` and
  `CSA_MAX_OBS`; specs skipped under the default guard are listed in data/csa_relaxed_queue.txt and are
  re-run overnight with `CSA_MAX_CELLS=20000`.
- The aggregate analysis now also splits the comparison by whether the paper itself reports a modern
  estimator (paper/tables/comparison_by_reported.tex), using `estimators_reported` from the screening
  records and `published_estimator` from the spec JSONs.
- Nov 1 ~18:25: run_spec.R dates adoption from a 0/1 treatment indicator on the full panel (after sample_filter, before
  rows with a missing outcome or weight are dropped). The old rule assigned a later cohort to units whose outcome was
  missing in their adoption period, shifting CSA cohorts and event time (static TWFE and BJS unaffected). Outputs carry
  g_shift_units (units whose cohort moved). Main specs using treat_var were audited with GSHIFT_AUDIT=1
  (logs/gshift_audit.log) and affected ones re-run.
