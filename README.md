# Do Modern Difference-in-Differences Estimators Change Published Findings in Business Research?

Replication materials for the paper of the same title (Proserpio, 2026; PDF at
https://dadepro.github.io/papers/modern-did.pdf). The study follows the
protocol of Hull (2026), "How Different are Different Differences-in-Differences? A Large-Scale Meta-Analysis"
(arXiv:2610.39995), for business-school journals: published staggered-adoption specifications are re-estimated with
two-way fixed effects (TWFE), DiD-averaging (Callaway and Sant'Anna, 2021) and imputation (Borusyak, Jaravel and
Spiess, 2024), and the estimates are compared.

- Replication sample: *Management Science* (2019 onwards) and *Marketing Science* (2013 onwards), the two journals
  with public replication archives.
- Archive and text screening only: *Journal of Marketing Research*, *Information Systems Research*, *Manufacturing &
  Service Operations Management*, *Operations Research*, *Organization Science*.
- Protocol, eligibility rules and every ruling, in the order they were made: `docs/PROTOCOL.md`. Instructions given to
  the screening and replication agents: `docs/SCREENING*.md`, `docs/REPLICATION*.md`.

## Layout

```
docs/               PROTOCOL.md (rules and rulings), screening and replication instructions
code/               pipeline (numbered Python steps) and R estimation and analysis code (code/R/)
data/
  frame/frame.csv   bibliographic frame of the seven journals (OpenAlex)
  candidates/       candidate list, replication-package manifest, hits outside the frame
  hits/             archive search results per journal and method keyword
  screening/        one JSON record per screened candidate (by_paper/), text-only screens of the other journals
                    (other_journals/), second-opinion screens, screened.csv and near_miss.csv
  specs/            one JSON per re-estimated specification (main analysis)
  specs_controls/   specifications with time-varying controls (secondary analysis, PROTOCOL 5c)
  specs_appendix/   specifications printed in article appendices (paper appendix on appendix specifications)
  specs_excluded/   specifications coded and then excluded, with the reason
  synthetic_packages.txt   packages whose data are synthetic or disguised (excluded from the main analysis)
output/
  specs/, specs_controls/          per-specification TWFE, DiD-averaging and imputation estimates (code/R/run_spec.R)
  boot_cov/, boot_cov_controls/    999-draw joint cluster Bayesian bootstrap covariances (code/R/boot_cov.R)
  tables/, figures/, specs_main.csv, comparison_summary.csv, ...   analysis outputs
output_hullA/       DiD-averaging under Hull's settings for the specifications whose paper publishes a
                    Callaway-Sant'Anna estimate; these columns are the main analysis (analysis.R swaps them in)
output_appx/        the appendix-specification sample under Hull's settings
output_appxB/       the same specifications under the authors' own settings (printed-value check)
output_xtdrop/      specifications with a high-cardinality control dropped from all three estimators
                    (the like-with-like check of the methods section)
paper/tables/, paper/tables_appx/, paper/figures/   generated tables, macros and figures used by the paper
```

## Pipeline

1. Frame and candidates: `code/01_openalex_frame.py` (OpenAlex; set `OPENALEX_API_KEY` in the environment or in
   `~/.did_env`), `01b`, `02`-`05`, `03_merge_candidates.py`.
2. Replication packages: `code/12_fetch_packages.py` (INFORMS replication-file request form), `09_package_intake.py`.
   Packages are extracted under `~/did_packages/<journal>/<suffix>/`; set `DID_PKG_ROOT` to point the specification
   files at another location.
3. Article text: full texts were obtained through the authors' university library access and converted with
   `code/07b_pdf_to_text.py`. They are not part of the repository (see below).
4. Screening: `code/13_make_screening_batches.py`, agent screening per `docs/SCREENING_PACKAGE.md` and
   `docs/SCREENING.md`, `code/14_screening_summary.py`, `17_outreach_and_nearmiss.py`, `18_mark_ineligible.py`.
5. Replication: one JSON per specification; `Rscript code/R/run_spec.R data/specs/<spec>.json`. R jobs run through
   `./code/rslot.sh`, which caps memory per job, with `code/memguard_keepalive.sh` running.
6. Bootstrap: `code/run_boot_queue.sh <log> <specs...>` (calls `code/R/boot_cov.R`, 999 draws).
7. Analysis and tables:
   ```
   Rscript code/R/analysis.R && Rscript code/R/analysis_controls.R && Rscript code/R/appendix.R
   python3 code/15_tables.py && python3 code/20_nearmiss_table.py && python3 code/22_journal_funnel.py && python3 code/23_characteristics.py
   ```
   Step 7 runs from the files in this repository alone: it needs no package data and no article text.

## Not in the repository

- Article PDFs and extracted article text: copyrighted. They were obtained through a university library.
- Replication packages: obtained from the journals' archives under their terms; re-download with step 2.
- The LaTeX source of the paper.
- Per-paper replication logs, run logs and backups.

## Software

R 4.6.0 with data.table 1.18.6.1, fixest 0.14.2, did 2.5.1, DRDID 1.3.0, didimputation 0.5.1, Matrix 1.7.5,
jsonlite 2.0.0, haven 2.5.5 and arrow 25.0.0; Python 3.9.13 with the standard library only. Stata 16.1 with csdid 1.81
was used only to validate a few Callaway-Sant'Anna estimates. The full list, with the server used for the re-runs, is in
`docs/SOFTWARE.md`.
