# Joint weighted (Bayesian) bootstrap of TWFE and modern DiD estimates, following Hull (2026, fn. 18: "Covariances are
# obtained by a weighted (Bayesian) bootstrap with 999 replications"). Cluster-level Exp(1) weights multiply the analysis
# weights; each draw re-estimates TWFE, BJS (imputation) and CSA on the same weights, so the covariance enters the
# significance test of the TWFE-modern difference. Written Nov 1 2026.
# Usage: Rscript code/R/boot_cov.R <spec.json> [B]   (from the project root, through code/rslot.sh)
# Output: $OUT_DIR/boot_cov[ _controls]/<suffix>__<spec_id>.csv (OUT_DIR defaults to output), one row per window (static, or
#   post and pre), with cov_twfe_csa, cov_twfe_bjs, bootstrap SDs, B, and checks that the draw-0 (unit weight) estimates equal
#   the main output.
# CSA per draw uses exact cell-level re-implementations (no covariates): composition-fixed panel cells (= csa_manual for
# unbalanced panels, = did::att_gt for balanced panels, verified to 1e-10) or did's cohort-average cells (csa_hull_prep / eval)
# for unbalanced panels and repeated cross-sections. If the draw-0 CSA does not reproduce the main CSA (e.g. covariates in
# att_gt), CSA covariances are NA.
# Nov 2: the draws use the estimators of compare_spec / compare_spec_event: the spec's event_structure (or es_legacy()), the
# CSA options (csa_cells pairs, csa_control_group, balance_e; drop_e_above acts on the sample in run_spec.R) and explicit-
# reference contrasts (CSA reference effect and BJS reference residual mean are re-estimated in each draw, Hull App. B),
# csa_cells "rc_csdid" (csdid RC cells with cell-count weights), csa_aggregation "calendar", event_time_authors_var (row coding
# for TWFE and BJS) and post-sample adopters (never-treated for CSA). BJS per draw is bjs_point() in estimators.R, which is also
# the main BJS estimate when did2s is too large (bjs_se_bootstrap: use boot_sd_bjs as its SE).
# Repeated cross-sections now use csa_hull_prep(rc = TRUE), the did replica of the main lean path, instead of a separate
# cell path that skipped did's period rules (identical when never-treated units exist; it failed the draw-0 check otherwise).
args0 <- commandArgs(trailingOnly = TRUE); BOOT_B <- if (length(args0) > 1) as.integer(args0[2]) else 999L
src <- readLines("code/R/run_spec.R"); cut <- grep('if (Sys.getenv("LEVERAGE_ONLY")', src, fixed = TRUE)[1]
commandArgs <- function(trailingOnly = TRUE) args0[1]
eval(parse(text = src[1:(cut - 1)]))          # sources estimators.R and builds d, opt and es_spec exactly as run_spec.R does
B <- BOOT_B                                    # (run_spec.R's preamble defines its own B)
main_dir <- file.path(OUT_DIR, if (length(ctrl)) "specs_controls" else "specs")
main <- fread(file.path(main_dir, paste0(spec$suffix, "__", spec$spec_id, ".csv")), colClasses = list(character = c("suffix", "spec_id")))
ctrl <- if (length(ctrl)) ctrl else NULL
pre_min <- as.integer(spec$event_pre_min %||% -5L); post_max <- as.integer(spec$event_post_max %||% 5L)

# ---- sample, standardization and event coding exactly as in compare_spec / compare_spec_event (Nov 2) -----------------
S <- if (is_event) es_parse(es_spec %||% es_legacy(pre_min, post_max)) else NULL
dp <- prep_panel(copy(d), standardize = FALSE); if (is_event) dp <- es_assign(dp, S)$d
reg <- reg_rows(dp, opt); invisible(std_y(dp, reg))
dr <- if (all(reg)) dp else dp[reg]            # TWFE / imputation sample (balance_e); CSA uses dp
fe <- fe_str(xt)
plan <- if (is_event) S else if (identical(opt$agg, "calendar")) "calendar" else NULL   # CSA aggregation plan (csa_summarize)
cls <- unique(dp$cl); cli <- match(dp$cl, cls); w0 <- dp$w
wins <- if (is_event) c("post", "pre") else "static"

# ---- TWFE and BJS for one weight vector -------------------------------------------------------------
# fixef.keep_names = TRUE: predict() needs FE names for combined FE such as t^xt (mnsc.2025.03238 failed without it, Nov 2)
bavg <- function(v, b, idx) { i <- which(b %in% idx); if (length(i)) mean(v[i]) else NA_real_ }   # equal-weight mean of available bins
fix_bjs <- function(x) lapply(x, function(v) if (length(v)) v else NA_real_)
# BOOT_CSA_ONLY=1 (Nov 2, unbalanced panels moved to did's cohort-average CSA): re-estimate TWFE and CSA only and update the CSA
# columns of the existing output file. The draws are seeded (20261101), so the TWFE draws are identical to the original run
# (checked via boot_sd_twfe) and the imputation columns stay valid.
CSA_ONLY <- Sys.getenv("BOOT_CSA_ONLY") == "1"
est_twfe_bjs <- function(wv, do_bjs = !CSA_ONLY) {
  set(dr, j = "wb", value = if (all(reg)) wv else wv[reg]); out <- list()
  if (!is_event) {
    out$twfe <- list(static = unname(coef(feols(as.formula(paste0("y ~ D", plus_ctrl(ctrl), " | ", fe)), data = dr, weights = ~wb, warn = FALSE, notes = FALSE))["D"]))
  } else {
    m <- feols(as.formula(paste0("y ~ i(ebin, ref = 0)", plus_ctrl(ctrl), " | ", fe)), data = dr, weights = ~wb, warn = FALSE, notes = FALSE)
    cf <- coef(m); k <- grepl("^ebin::", names(cf)); bn <- as.integer(sub("ebin::", "", names(cf)[k])); cf <- cf[k]
    out$twfe <- list(post = bavg(cf, bn, S$post_idx), pre = bavg(cf, bn, S$pre_idx))
  }
  # imputation: within-bin means of Y - Yhat(0) (= did2s's second-stage coefficients), standard lead regression or explicit
  # reference contrast, from the fixest first stage on the weighted draw (bjs_point)
  out$bjs <- if (!do_bjs) lapply(out$twfe, function(z) NA_real_) else fix_bjs(bjs_point(dr, xt, ctrl, if (is_event) S else NULL, wcol = "wb"))
  out
}

# ---- CSA fast paths (cluster multipliers) ----------------------------------------------------------
rc <- anyDuplicated(dp, by = c("id", "t")) > 0
# unbalanced panels: the main CSA is did's cohort-average (repeated cross-section) estimator since Nov 2 (CSA_UNBALANCED=hull),
# so the bootstrap uses the did replica for them; the draw-0 check below confirms it reproduces the main estimate
unbal_panel <- !rc && CSA_UNBAL == "hull" && is_unbalanced(dp)
main_has_csa <- any(is.finite(main$csa))   # CSA skipped in the main run (size/memory guards): build no CSA cells; the cells of a
                                           # guarded spec can exceed memguard's cap (mnsc.2021.4209, 6.9M rows, killed Nov 2 03:56)
control <- opt$control; bal <- opt$balance_e; cells <- opt$cells %||% (if (isTRUE(opt$pairs)) "pairs" else "")
dpc <- csa_never_post(dp)   # adopters after the last period are never-treated for CSA (as in csa_static / csa_event)
if (!main_has_csa) {
  csa_draw <- function(m) rep(NA_real_, length(wins))
} else if (cells == "pairs" || (cells != "rc_csdid" && !rc && !unbal_panel)) {   # composition-fixed cells: balanced panels (= did) and csa_cells = "pairs"
  cc <- csa_cells(dpc, control, ekeep = if (is.list(plan)) function(e) es_needed(e, plan) else function(e) e >= 0,
                  zero_ref = csa_need_zero(plan))
  bb <- if (is.null(bal)) NULL else list(k = bal, Tmax = cc$Tmax, Tmin = cc$Tmin)
  mi <- match(cc$cls, as.character(cls))
  csa_draw <- function(m) { r <- csa_aggregate(cc$cells, mult = m[mi], plan = plan, bal = bb); if (is.null(r)) rep(NA_real_, length(wins)) else unname(r$est[1, ]) }
} else {   # unbalanced panels, repeated cross-sections and rc_csdid: the did replica in estimators.R (csa_hull_prep / csa_hull_eval)
  HO <- csa_hull_prep(dpc, cls, rc = rc || cells == "rc_csdid", control = control, wmode = csa_wmode(opt, rc, unbal_panel))   # Hull treated counts / did shares / csdid cells
  HCS <- csa_hull_cs(HO, plan, bal)
  csa_draw <- function(m) unname(csa_hull_eval(HO, m, plan, bal, HCS)$est)
}

# ---- draw 0 (unit weights) must reproduce the main estimates ------------------------------------
main_val <- function(col) { x <- if (is_event) setNames(main[[col]], main$window) else c(static = main[[col]][1]); x[wins] }
e0 <- est_twfe_bjs(w0); c0 <- csa_draw(rep(1, length(cls)))
chk <- function(a, b) { ok <- is.finite(a) & is.finite(b); if (!any(ok)) return(NA_real_); max(abs(a[ok] - b[ok])) }
d_twfe <- chk(unlist(e0$twfe), main_val("twfe")); d_bjs <- chk(unlist(e0$bjs), main_val("bjs")); d_csa <- chk(c0, main_val("csa"))
csa_ok <- is.finite(d_csa) && d_csa < 1e-6
cat(sprintf("draw0 max|diff| vs main: twfe %.2e  bjs %.2e  csa %s (%s)\n", d_twfe, d_bjs, format(d_csa), if (csa_ok) "fast path ok" else "no CSA covariance"))

# ---- bootstrap -----------------------------------------------------------------------------------
set.seed(20261101); V <- matrix(rexp(B * length(cls)), B)
T_ <- matrix(NA_real_, B, length(wins)); J_ <- T_; C_ <- T_; t0 <- Sys.time()
od <- file.path(OUT_DIR, if (length(ctrl)) "boot_cov_controls" else "boot_cov"); outf <- file.path(od, paste0(spec$suffix, "__", spec$spec_id, ".csv"))
if (CSA_ONLY && !file.exists(outf)) { CSA_ONLY <- FALSE; cat("BOOT_CSA_ONLY: no earlier output, running the full bootstrap\n") }
skip_loop <- CSA_ONLY && !csa_ok   # nothing to update but the CSA flags
# Chunked runs (Nov 3, for the longest bootstraps): BOOT_CHUNK=k/K runs only the k-th of K contiguous blocks of draws and saves
# them to <od>/chunks/; BOOT_MERGE=K then reads the K blocks instead of running the loop. Draw b always uses row b of the
# seeded V above, so the merged draws equal the single-process draws.
CHUNK <- Sys.getenv("BOOT_CHUNK"); MERGE <- as.integer(Sys.getenv("BOOT_MERGE", "0"))
bidx <- seq_len(if (skip_loop) 0L else B)
if (nzchar(CHUNK)) { kK <- as.integer(strsplit(CHUNK, "/")[[1]]); bidx <- bidx[ceiling(bidx * kK[2] / B) == kK[1]] }
if (MERGE > 0) bidx <- integer(0)
for (b in bidx) {
  m <- V[b, ]; e <- tryCatch(est_twfe_bjs(w0 * m[cli]), error = function(err) NULL)
  if (!is.null(e)) { T_[b, ] <- unlist(e$twfe); J_[b, ] <- unlist(e$bjs) }
  if (csa_ok) C_[b, ] <- csa_draw(m)
}
chd <- file.path(od, "chunks"); stem <- paste0(spec$suffix, "__", spec$spec_id)
if (nzchar(CHUNK)) {
  dir.create(chd, showWarnings = FALSE, recursive = TRUE)
  saveRDS(list(idx = bidx, T = T_[bidx, , drop = FALSE], J = J_[bidx, , drop = FALSE], C = C_[bidx, , drop = FALSE], B = B,
               secs = as.numeric(Sys.time() - t0, units = "secs")), file.path(chd, sprintf("%s.%d.rds", stem, kK[1])))
  cat(sprintf("chunk %s: draws %d-%d saved\n", CHUNK, min(bidx), max(bidx))); quit(save = "no")
}
if (MERGE > 0) {
  secs <- 0; got <- integer(0)
  for (k in seq_len(MERGE)) {
    z <- readRDS(file.path(chd, sprintf("%s.%d.rds", stem, k))); stopifnot(z$B == B)
    T_[z$idx, ] <- z$T; J_[z$idx, ] <- z$J; C_[z$idx, ] <- z$C; secs <- secs + z$secs; got <- c(got, z$idx)
  }
  if (!identical(sort(got), seq_len(B))) stop("BOOT_MERGE: chunks do not cover draws 1..B exactly")
  t0 <- Sys.time() - secs   # seconds = total compute time over the chunks
  cat(sprintf("merged %d chunks (%d draws)\n", MERGE, length(got)))
}
cv <- function(a, b) { ok <- is.finite(a) & is.finite(b); if (sum(ok) < 10) NA_real_ else cov(a[ok], b[ok]) }
crr <- function(a, b) { ok <- is.finite(a) & is.finite(b); if (sum(ok) < 10) NA_real_ else cor(a[ok], b[ok]) }
sdv <- function(a) { a <- a[is.finite(a)]; if (length(a) < 10) NA_real_ else sd(a) }
out <- rbindlist(lapply(seq_along(wins), function(j) data.table(
  suffix = spec$suffix, spec_id = spec$spec_id, window = wins[j], boot_B = B,
  cov_twfe_csa = cv(T_[, j], C_[, j]), cov_twfe_bjs = cv(T_[, j], J_[, j]),
  boot_sd_twfe = sdv(T_[, j]), boot_sd_csa = sdv(C_[, j]), boot_sd_bjs = sdv(J_[, j]),
  boot_cor_twfe_csa = crr(T_[, j], C_[, j]), boot_cor_twfe_bjs = crr(T_[, j], J_[, j]),
  draws_ok_twfe = sum(is.finite(T_[, j])), draws_ok_csa = sum(is.finite(C_[, j])), draws_ok_bjs = sum(is.finite(J_[, j])),
  draw0_diff_twfe = d_twfe, draw0_diff_bjs = d_bjs, draw0_diff_csa = d_csa, csa_fast_path = csa_ok,
  seconds = round(as.numeric(Sys.time() - t0, units = "secs")))))
out[, es_source := if (is_event) (if (is.null(es_spec)) "legacy" else "spec") else NA_character_]   # Nov 2
dir.create(od, showWarnings = FALSE, recursive = TRUE)
if (CSA_ONLY) {   # keep TWFE/BJS columns of the original run, replace the CSA ones
  old <- fread(outf, colClasses = list(character = c("suffix", "spec_id")))
  if (!skip_loop) cat(sprintf("TWFE draws identical to the original run: max|boot_sd_twfe diff| = %.2e\n", max(abs(old$boot_sd_twfe - out$boot_sd_twfe[match(old$window, out$window)]), na.rm = TRUE)))
  cols <- c("cov_twfe_csa", "boot_sd_csa", "boot_cor_twfe_csa", "draws_ok_csa", "draw0_diff_csa", "csa_fast_path")
  for (cn in cols) set(old, j = cn, value = out[[cn]][match(old$window, out$window)])
  old[, csa_boot_updated := "csa_only_nov2"]; out <- old
}
fwrite(out, outf); print(out[, .(window, cov_twfe_csa, cov_twfe_bjs, boot_sd_twfe, boot_cor_twfe_csa, boot_cor_twfe_bjs, seconds)])
