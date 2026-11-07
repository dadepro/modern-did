# Screening instructions (per paper)

Input: full text of one candidate paper (main text, tables, figures, appendix if
available) plus its replication-package README when present.
Output: one JSON record appended to `data/screening/screened.jsonl`.

## Step 1. Paper-level questions

1. Does the paper estimate a difference-in-differences or event-study design in which
   units adopt a binary treatment at different calendar dates (at least two adoption
   cohorts)? If no, record `eligible_design: false` and stop.
2. Which estimators are reported for that design? (TWFE static, TWFE event study,
   Callaway-Sant'Anna, Sun-Abraham, Borusyak-Jaravel-Spiess imputation,
   de Chaisemartin-D'Haultfoeuille, stacked, Gardner two-stage, synthetic control, other.)
3. Is the staggered design the paper's main identification strategy, or a robustness
   check?
4. Data: public, proprietary under NDA, licensed (Nielsen, Compustat, etc.), scraped.
   Does the replication package appear to contain the data needed for the eligible
   specifications? (From the data availability statement or README.)
5. Software of the replication code (Stata, R, Python, MATLAB, Julia, other).
6. Management Science department (MS only), from the article page.

## Step 2. Specification-level records

For every main-text specification that satisfies the eligibility rules in
`PROTOCOL.md` Section 2, record:

```
paper_doi, spec_id, location (table/figure, panel, column/row), estimator_reported,
static_or_event, outcome, outcome_transform, treatment_definition, unit, assignment_unit,
time_unit, sample, weights, fixed_effects, controls (must be none or time-invariant x time),
clustering, event_bins, omitted_period, coef, se, n_obs, preferred_spec (y/n/unclear),
in_abstract_or_intro (y/n), exclusion_reason (if ineligible), notes
```

Count every qualifying specification regardless of sign, size or significance.
Mark as ineligible (with reason) any specification with time-varying controls, lagged
outcomes, unit trends, continuous or multi-valued treatment, additional treatments,
subgroup-by-treatment interactions, IV, nonlinear models, matching or synthetic control.

## Step 3. Summary flags

`eligible_design`, `n_eligible_specs`, `reports_modern_estimator`, `main_or_robustness`,
`data_access` (public / partial / proprietary), `package_expected` (y/n), `priority`
(1 = eligible and package expected; 2 = eligible but data doubtful; 3 = not eligible).
