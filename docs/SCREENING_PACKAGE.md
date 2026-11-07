# Package-based screening instructions (for screening agents)

You are screening one candidate paper for a meta-analysis that re-estimates published
staggered-adoption difference-in-differences (DiD) specifications with modern estimators
(Callaway-Sant'Anna, Borusyak-Jaravel-Spiess). You have:

1. `data/packages/<suffix>_regressions.txt`: every regression command found in the
   replication code (file :: command line).
2. The extracted package under `~/did_packages/<journal>/<suffix>/` (README, code, data).
3. If available, the article text under `data/text/<journal>/<suffix>.txt` and the
   OpenAlex abstract in `data/candidates/candidates.csv`.

Read the README first, then the main-results code, then the article text if present.
Answer the questions in `docs/SCREENING.md` and write ONE JSON object to
`data/screening/by_paper/<suffix>.json` with these keys:

```
doi, journal, eligible_design (true/false), design_notes,
estimators_reported (list), main_or_robustness, n_eligible_specs,
specs: [ {spec_id, code_file, code_line, outcome, treatment_var, unit_var, time_var,
          fe, controls, weights, cluster, sample_condition, static_or_event,
          reported_location (table/column if known), notes} ],
data_access (public / partial / proprietary / unclear), data_files_present (true/false),
software (stata/r/python/other), replication_feasible (yes/maybe/no), priority (1/2/3),
screener_notes
```

Eligibility reminders (from PROTOCOL.md): binary treatment switching on at unit-specific
dates with at least two adoption cohorts; unit and calendar-time fixed effects (static or
unstacked event study); time-invariant covariates interacted with time allowed; no
time-varying controls, lagged outcomes, unit trends, continuous treatments, IV, nonlinear
models, matching, stacked designs, or synthetic control. A paper that reports a modern
estimator (csdid, did_imputation, did2s, eventstudyinteract, did_multiplegt, att_gt,
sunab) counts as eligible if the underlying design qualifies, and TWFE counterparts can be
constructed. Record every qualifying main-text specification, not only the headline one.

Be precise about variable names: they will be used to run the estimators automatically.
If the code's treatment variable is an interaction (post x treated), name both components.
If data files are missing or clearly synthetic, say so under data_access.

## Added fields (Nov 1, 2026)
- `eligible` (bool): at least one reported specification satisfies every rule (this is the flag used downstream).
- `eligible_design` (bool): a qualifying staggered binary design exists at all, regardless of controls.
- `near_miss` (bool) and `near_miss_reason`: design qualifies but every reported column adds time-varying
  controls or extra treatment regressors; these papers are reported separately as a secondary category.
- `data_provenance` on spec JSONs: "real" or "synthetic" (synthetic/disguised/pseudo data shipped by the package).
