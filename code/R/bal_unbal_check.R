# Balanced vs unbalanced panels: does the TWFE-modern correlation gap depend on the normalization? (Nov 7, 2026)
# Backs the Section 4.6 sentence "In our sample the gap is larger and does not depend on the normalization", written after
# Hull provided his split by panel type (hulls-corrs-v2.jpg): his gap is -0.06 for both estimators, not significant, and
# its sign reverses under TWFE-SE normalization (his figure coordinates) vs outcome-SD units (his annotated correlations
# and every correlation in the paper). Reads output/specs_main.csv (written by analysis.R) and rebuilds the unbal flag
# with the same rule as analysis.R. The paper-cluster bootstrap interval is a check only; the paper reports no interval.
# Run from the repo root: Rscript code/R/bal_unbal_check.R
suppressMessages(library(data.table))
d <- fread("output/specs_main.csv")
stopifnot(all(c("csa_fc","csa_note","n","n_units") %in% names(d)))
d[, unbal := is.finite(csa_fc) | grepl("unbalanced_did", csa_note)]
d[, T_note := suppressWarnings(as.numeric(sub(".*csa_skipped_size:G=[0-9]+,T=([0-9]+),N=.*", "\\1", csa_note)))]
d[grepl("size_did_lean", csa_note) & is.finite(T_note) & !grepl("rc_did_lean", csa_note), unbal := unbal | (as.numeric(n) < as.numeric(n_units) * T_note)]
set.seed(20261107)
for (m in c("csa","bjs")) {
  x <- d[get(paste0("pass_", m)) %in% TRUE & is.finite(get(m)) & is.finite(twfe), .(paper, unbal, twfe, twfe_se, mod = get(m))]
  cb <- function(z, f = identity) if (nrow(z) > 2) cor(f(z$twfe, z$twfe_se), f(z$mod, z$twfe_se)) else NA_real_
  sd_f <- function(v, s) v; se_f <- function(v, s) v / s
  stat <- function(z, f) c(bal = cb(z[unbal == FALSE], f), unbal = cb(z[unbal == TRUE], f), pooled = cb(z, f))
  s_sd <- stat(x, sd_f); s_se <- stat(x, se_f)
  papers <- unique(x$paper); B <- 999
  boot <- t(replicate(B, { p <- sample(papers, length(papers), replace = TRUE)
    z <- rbindlist(lapply(seq_along(p), function(i) x[paper == p[i]][, paper := paste0(p[i], "_", i)]))
    c(sd = unname(diff(stat(z, sd_f)[c("bal","unbal")])), se = unname(diff(stat(z, se_f)[c("bal","unbal")]))) }))
  ci <- apply(boot, 2, quantile, probs = c(.025, .975), na.rm = TRUE)
  cat(sprintf("%s: n bal %d (%d papers), unbal %d (%d papers)\n", toupper(m), x[unbal==FALSE,.N], x[unbal==FALSE,uniqueN(paper)], x[unbal==TRUE,.N], x[unbal==TRUE,uniqueN(paper)]))
  cat(sprintf("  outcome-SD units : bal %.3f  unbal %.3f  pooled %.3f  diff %.3f  95%% CI [%.3f, %.3f]\n", s_sd["bal"], s_sd["unbal"], s_sd["pooled"], s_sd["unbal"]-s_sd["bal"], ci[1,"sd"], ci[2,"sd"]))
  cat(sprintf("  TWFE-SE units    : bal %.3f  unbal %.3f  pooled %.3f  diff %.3f  95%% CI [%.3f, %.3f]\n", s_se["bal"], s_se["unbal"], s_se["pooled"], s_se["unbal"]-s_se["bal"], ci[1,"se"], ci[2,"se"]))
}
