# Software versions

Versions installed on the machines that produced the results (specification runs and bootstraps Nov 1-6, 2026;
aggregate analysis rerun from the committed per-specification outputs on Nov 7, 2026, reproducing every table
byte for byte).

## Estimation and analysis (R)

| Component | Version | Used for |
|---|---|---|
| R | 4.6.0 (2026-04-24), aarch64-apple-darwin23, R's own BLAS/LAPACK | all R code on the Mac |
| R, server | 4.6.1 on a Linux server (64 cores), same package versions | re-runs of every specification and bootstrap; results agree with the Mac to about 1e-14 |
| data.table | 1.18.6.1 | data handling |
| fixest | 0.14.2 | TWFE and event-study regressions, leverage weights |
| did | 2.5.1 | DiD-averaging (Callaway-Sant'Anna), `att_gt` with the unbalanced-panel option |
| DRDID | 1.3.0 | dependency of `did` |
| didimputation | 0.5.1 | imputation estimator (Borusyak-Jaravel-Spiess) |
| did2s | 1.2.1 | checks only |
| Matrix | 1.7.5 | sparse leverage computations |
| jsonlite | 2.0.0 | specification files |
| haven | 2.5.5 | Stata data files |
| arrow | 25.0.0 | parquet data files |
| numDeriv | 2016.8.1.1 | hierarchical model |
| ggplot2 | 4.0.3 | figures |

## Pipeline scripts (Python)

Python 3.9.13 (arm64), standard library only: no third-party package is imported by any script in `code/`.

## Validation

Stata 16.1 with `csdid` 1.81, used only to check a few Callaway-Sant'Anna estimates against the authors' Stata
output (PROTOCOL, Hull-alignment rulings).

## Operating system

macOS 27.0.1 (Apple silicon) for the pipeline, the aggregate analysis and part of the specification runs; the Linux
server for the full re-run of specifications and bootstraps.
