# Aggregate analysis of TWFE vs modern DiD comparisons (Hull 2026 Figures 2-3, A3, Table 2).
# Inputs : output/specs/*.csv (one row per specification, from run_spec.R)
#          data/specs/*.json (spec metadata), data/candidates/candidates.csv (paper metadata)
# Outputs: output/tables/*.tex, output/figures/*.pdf, output/summary.json
suppressPackageStartupMessages({ library(data.table); library(jsonlite); library(ggplot2) })
source("code/R/hierarchical.R")
# Output locations (Nov 4): the main run writes to paper/tables and output/tables; APPENDIX_SPECS=1 adds the printed-appendix
# specifications (data/specs_appendix JSONs with appendix_printed = true, outputs in output_appx/) and should be run with
# TABLES_DIR=paper/tables_appx OUT_TABLES=output/tables_appx MACRO_SUFFIX=Appx so that nothing of the main run is overwritten.
TAB <- Sys.getenv("TABLES_DIR", "paper/tables"); OUTT <- Sys.getenv("OUT_TABLES", "output/tables"); MSUF <- Sys.getenv("MACRO_SUFFIX", "")
MAIN_RUN <- TAB == "paper/tables"
SPEC_DIRS <- "data/specs"; OUT_SPEC_DIRS <- "output/specs"; BOOT_DIRS <- "output/boot_cov"
if (Sys.getenv("APPENDIX_SPECS") == "1") { SPEC_DIRS <- c(SPEC_DIRS, "data/specs_appendix"); OUT_SPEC_DIRS <- c(OUT_SPEC_DIRS, "output_appx/specs"); BOOT_DIRS <- c(BOOT_DIRS, "output_appx/boot_cov") }
lf <- function(dirs, pattern) unlist(lapply(dirs, list.files, full.names = TRUE, pattern = pattern))
dir.create(OUTT, showWarnings = FALSE, recursive = TRUE); dir.create(TAB, showWarnings = FALSE, recursive = TRUE); dir.create("output/figures", showWarnings = FALSE)

specs <- rbindlist(lapply(lf(OUT_SPEC_DIRS, "csv$"), function(f) fread(f, colClasses = list(character = c("suffix", "spec_id")))), fill = TRUE)
specs <- specs[!duplicated(specs[, .(suffix, spec_id, window)])]   # a spec present in two output folders (e.g. output/specs and output_appx/specs) counts once
# joint 999-draw weighted bootstrap covariances (code/R/boot_cov.R; Hull fn. 18). Rows without one keep covariance 0 in the
# significance test and are counted below.
bfiles <- lf(BOOT_DIRS, "csv$")
if (length(bfiles)) {
  bc <- rbindlist(lapply(bfiles, function(f) fread(f, colClasses = list(character = c("suffix", "spec_id")))), fill = TRUE)
  bc <- bc[!duplicated(bc[, .(suffix, spec_id, window)])]
  specs[, intersect(c("cov_twfe_csa", "cov_twfe_bjs"), names(specs)) := NULL]
  specs <- merge(specs, bc[, .(suffix, spec_id, window, cov_twfe_csa, cov_twfe_bjs, boot_B, boot_sd_twfe, boot_sd_csa, boot_sd_bjs, boot_cor_twfe_csa, boot_cor_twfe_bjs)],
                 by = c("suffix", "spec_id", "window"), all.x = TRUE)
}
cat(sprintf("bootstrap covariances available: CSA %d, BJS %d of %d rows\n", sum(is.finite(specs$cov_twfe_csa %||% NA)), sum(is.finite(specs$cov_twfe_bjs %||% NA)), nrow(specs)))
meta  <- rbindlist(lapply(lf(SPEC_DIRS, "json$"), function(f) {
  j <- fromJSON(f); if (grepl("specs_appendix", f) && !isTRUE(j$appendix_printed)) return(NULL); data.table(suffix = j$suffix, spec_id = j$spec_id, journal = j$journal %||% NA,
    static_or_event = j$static_or_event %||% NA, preferred = isTRUE(j$preferred), in_abstract_intro = isTRUE(j$in_abstract_intro),
    table = j$table %||% NA, column = as.character(j$column %||% NA), provenance = j$data_provenance %||% "real",
    published_estimator = as.character(j$published_estimator %||% NA), appendix_printed = isTRUE(j$appendix_printed)) }), fill = TRUE)
# paper-level flag: does the paper itself report a modern DiD estimator (CSA / BJS / SA / did2s / dCDH)?
MODERN_PAT <- "csdid|att_gt|callaway|sant.?anna|did_imputation|borusyak|imputation|did2s|gardner|sunab|eventstudyinteract|sun.{0,5}abraham|did_multiplegt|chaisemartin"
scr <- rbindlist(lapply(list.files("data/screening/by_paper", full.names = TRUE, pattern = "json$"), function(f) {
  j <- tryCatch(fromJSON(f), error = function(e) NULL); if (is.null(j)) return(NULL)
  data.table(suffix = sub("\\.json$", "", basename(f)), reported_modern_scr = any(grepl(MODERN_PAT, unlist(j$estimators_reported), ignore.case = TRUE))) }), fill = TRUE)
cand <- fread("data/candidates/candidates.csv")[, .(doi, journal, year, cited_by, reports_modern_ft = pmax(ft_callaway, ft_borusyak, ft_sun_and_abraham, ft_de_chaisemartin, na.rm = TRUE), cite_modern)]
cand[, suffix := sub(".*/", "", doi)]
# publication year = journal issue year from Crossref (print year, else issued year; data/candidates/crossref_years.csv, Nov 3):
# the OpenAlex year in candidates.csv is often the online-first year or a merged working-paper year (final check, Nov 3)
if (file.exists("data/candidates/crossref_years.csv")) {
  cy <- fread("data/candidates/crossref_years.csv", colClasses = list(character = "doi"))[, .(doi, cyear = fcoalesce(as.integer(print_year), as.integer(issued_year)))]
  cand <- merge(cand, cy, by = "doi", all.x = TRUE); cand[!is.na(cyear), year := cyear]; cand[, cyear := NULL]
}
# only specifications with a current spec JSON (outputs of excluded specs, data/specs_excluded/, are ignored; Nov 2)
specs <- specs[paste(suffix, spec_id) %in% meta[, paste(suffix, spec_id)]]
# imputation SE from the bootstrap where did2s cannot run (note bjs_se_bootstrap; e.g. mnsc.2025.03238 T4_c1, Nov 2)
if ("boot_sd_bjs" %in% names(specs)) specs[is.na(bjs_se) & !is.na(bjs) & is.finite(boot_sd_bjs) & grepl("bjs_se_bootstrap", bjs_note), bjs_se := boot_sd_bjs]
d <- merge(specs, meta, by = c("suffix", "spec_id"), all.x = TRUE)
d <- merge(d, cand, by = "suffix", all.x = TRUE, suffixes = c("", ".cand"))
d <- merge(d, scr, by = "suffix", all.x = TRUE)
d[, reported_modern := (!is.na(reported_modern_scr) & reported_modern_scr) | grepl(MODERN_PAT, published_estimator, ignore.case = TRUE)]
d[, paper := suffix]
d[is.na(provenance) | provenance %in% c("", "original", "real", "random_subsample", "authors_transformed"), provenance := fifelse(is.na(provenance) | provenance %in% c("", "original"), "real", provenance)]
d[grepl("synth|disguis|pseudo|simulat|scrambl|fuzz", provenance, ignore.case = TRUE) & !grepl("^\\s*(real|original)", provenance, ignore.case = TRUE), provenance := "synthetic"]   # labels starting "real"/"original" stay real (e.g. "real (anonymized ... not synthetic)")
synth_list <- if (file.exists("data/synthetic_packages.txt")) readLines("data/synthetic_packages.txt") else character(0)
d[suffix %in% synth_list, provenance := "synthetic"]
d[provenance %in% c("random_subsample", "authors_transformed"), provenance := "real"]  # original data, subsampled or linearly rescaled by the authors; flagged in logs
# pre-window rows with no TWFE estimate (event studies without pre bins under the authors' coding) are not comparisons; they
# inflated nMainComparisons and nPassSpecs by 57 rows (code review, Nov 3)
d <- d[!(window == "pre" & !is.finite(twfe))]
synth <- d[provenance != "real"]
cat(sprintf("%d specifications from %d papers in total; %d specs from %d papers use synthetic/disguised package data and are excluded from the main analysis\n",
            nrow(d), uniqueN(d$paper), nrow(synth), uniqueN(synth$paper)))
fwrite(synth, if (MAIN_RUN) "output/specs_synthetic.csv" else file.path(OUTT, "specs_synthetic.csv"))   # appendix.R reads the main run's file
d <- d[provenance == "real"]
d[, pass := G_eff >= 10 & L_max <= 0.25]
# Hull App. B: a TWFE-modern pair is retained only if BOTH estimators have G_eff >= 10 and L_max <= 0.25. The modern
# estimators' leverage (G_eff_csa/L_max_csa, G_eff_bjs/L_max_bjs; Nov 2) comes from their linear weights on y; where those
# are unavailable (NA) the pair falls back to the TWFE screen alone and is counted (nLevFallback*).
lev_flags <- function(d, ms = c("csa", "bjs")) {
  for (m in ms) {
    gc <- paste0("G_eff_", m); lc <- paste0("L_max_", m)
    if (!gc %in% names(d)) d[, (gc) := NA_real_]
    if (!lc %in% names(d)) d[, (lc) := NA_real_]
    d[, paste0("pass_", m) := pass & fifelse(is.na(get(gc)) | is.na(get(lc)), TRUE, get(gc) >= 10 & get(lc) <= 0.25)]
    # Imputation estimates whose leverage system is inconsistent (some treated rows' Y(0) not identified by the untreated rows,
    # so the estimate depends on the fixed-effect normalization) fail the screen (decision, Nov 3, option (a) of code review E1)
    if (m == "bjs" && "lev_note" %in% names(d)) d[grepl("lev_bjs_inconsistent", lev_note), pass_bjs := FALSE]
    d[, paste0("levfb_", m) := pass & !is.na(get(m)) & (is.na(get(gc)) | is.na(get(lc)))]
    if (m == "bjs" && "lev_note" %in% names(d)) d[grepl("lev_bjs_inconsistent", lev_note), levfb_bjs := FALSE]   # these fail, not fall back
    d[, paste0("levfail_", m) := pass & !is.na(get(m)) & !get(paste0("pass_", m))]
  }
  invisible(d)
}
lev_flags(d)
# ---- Option A (decision, Nov 3): Hull's DiD-averaging settings also for papers that publish a CS estimate ------------------------
# The main analysis (option B) estimates DiD-averaging with the authors' csdid/did settings where the paper itself publishes a CS
# estimate (csa_cells, csa_control_group, csa_aggregation, csa_weights in the spec JSON). output_hullA/ reruns those specs with
# CSA_STRICT_HULL=1, i.e. Hull's estimator throughout (cohort-average cells for unbalanced panels, not-yet-treated controls,
# Hull's weights). TWFE, imputation and the TWFE bootstrap draws are identical in the two runs (checked on all 105 rows, Nov 3),
# so dHA swaps in the strict-Hull DiD-averaging columns only.
read_out <- function(dir) { fs <- list.files(dir, full.names = TRUE, pattern = "csv$"); if (!length(fs)) return(NULL)
  rbindlist(lapply(fs, function(f) fread(f, colClasses = list(character = c("suffix", "spec_id")))), fill = TRUE) }
hA <- read_out("output_hullA/specs"); hAb <- read_out("output_hullA/boot_cov")
if (!is.null(hA)) hA <- hA[!duplicated(hA[, .(suffix, spec_id, window)])]; if (!is.null(hAb)) hAb <- hAb[!duplicated(hAb[, .(suffix, spec_id, window)])]
dHA <- copy(d); d[, pubcs := FALSE]; dHA[, pubcs := FALSE]
if (!is.null(hA)) {
  bcols <- c("cov_twfe_csa", "boot_sd_csa", "boot_cor_twfe_csa")
  hA[, intersect(bcols, names(hA)) := NULL]
  if (!is.null(hAb)) hA <- merge(hA, hAb[, c("suffix", "spec_id", "window", intersect(bcols, names(hAb))), with = FALSE], by = c("suffix", "spec_id", "window"), all.x = TRUE)
  cc <- intersect(c("csa", "csa_se", "csa_fc", "csa_fc_se", "csa_note", "G_eff_csa", "L_max_csa", bcols), intersect(names(hA), names(dHA)))
  idx <- match(hA[, paste(suffix, spec_id, window)], dHA[, paste(suffix, spec_id, window)]); ok <- !is.na(idx)
  for (v in cc) {
    val <- hA[[v]][ok]
    # an all-NA column read as logical must not coerce the numeric main column (code review R1, Nov 3)
    if (is.logical(val) && all(is.na(val)) && !is.logical(dHA[[v]])) val <- as(val, class(dHA[[v]]))[seq_along(val)]
    else if (!identical(class(dHA[[v]]), class(val))) set(dHA, j = v, value = as(dHA[[v]], class(val)))
    set(dHA, i = idx[ok], j = v, value = val)
  }
  set(dHA, i = idx[ok], j = "pubcs", value = TRUE); set(d, i = idx[ok], j = "pubcs", value = TRUE)
  lev_flags(dHA, "csa")
  cat(sprintf("option A: strict-Hull DiD-averaging swapped in for %d rows (%d specs, %d papers)\n", sum(ok), uniqueN(hA[ok, paste(suffix, spec_id)]), uniqueN(hA[ok]$suffix)))
}
# MAIN ANALYSIS = Hull's settings for every specification (option A; the PI, Nov 3: "hull's is main"). The authors' CS settings for
# the papers that publish a CS estimate (option B, which reproduces their printed estimates) are kept in d_auth for the appendix.
d_auth <- d; d <- dHA
# ---- High-cardinality characteristics (PROTOCOL (u), Nov 4 evening; decision: "we drop cs estimates for those") -------------------
# A time-invariant characteristic with more than 60 categories cannot enter DiD-averaging (with 260 four-digit industry dummies every
# cohort-by-period cell regression is rank-deficient; checked on mnsc.2020.01838), so until Nov 4 TWFE and imputation kept the authors'
# industry-by-year effects while DiD-averaging omitted them, and the comparison attributed the covariate adjustment to the estimator.
# Main rule now: NO DiD-averaging estimate for such specifications; TWFE and imputation keep the published regression. Two checks
# for the text: (asym) the old comparison, TWFE with the effects vs DiD-averaging without; (like) both without the characteristic,
# from run_spec.R with XT_DROP_ALL=1 (output_xtdrop/: 45 specs re-estimated and bootstrapped on Nov 4).
XT_PAT <- "xt_ignored_highcard|xt_dropped_all_highcard"
xt_rows <- grepl(XT_PAT, d$csa_note)
d_xt_asym <- copy(d[xt_rows])   # compare() is defined below; the comparisons are computed after res
nXtHighcardCmp <- d[xt_rows & pass_csa %in% TRUE & !is.na(csa) & !is.na(twfe), .N]
xd <- read_out("output_xtdrop/specs"); xdb <- read_out("output_xtdrop/boot_cov"); res_xlike <- NULL; xd_like <- NULL
if (!is.null(xd)) xd <- xd[!duplicated(xd[, .(suffix, spec_id, window)])]; if (!is.null(xdb)) xdb <- xdb[!duplicated(xdb[, .(suffix, spec_id, window)])]   # Dropbox conflict copies (code review, Nov 4)
nXtHighcardPapers <- uniqueN(d[xt_rows & pass_csa %in% TRUE & !is.na(csa) & !is.na(twfe), paper])   # papers losing DiD-averaging comparisons (text)
nXtHighcardBJS <- d[xt_rows & pass_bjs %in% TRUE & !is.na(bjs) & !is.na(twfe), .N]   # of these specs, imputation comparisons that pass the screen (text)
nXtHighcardBJSinc <- d[xt_rows & pass %in% TRUE & grepl("lev_bjs_inconsistent", lev_note), .N]   # of the TWFE-screened rows, imputation not identified (text)
if (!is.null(xd)) {
  xd[, intersect(c("cov_twfe_csa", "cov_twfe_bjs", "boot_B", "boot_sd_twfe", "boot_sd_csa", "boot_sd_bjs", "boot_cor_twfe_csa", "boot_cor_twfe_bjs"), names(xd)) := NULL]
  if (!is.null(xdb)) xd <- merge(xd, xdb[, .(suffix, spec_id, window, cov_twfe_csa, cov_twfe_bjs, boot_B, boot_sd_twfe, boot_sd_csa, boot_sd_bjs, boot_cor_twfe_csa, boot_cor_twfe_bjs)],
                                by = c("suffix", "spec_id", "window"), all.x = TRUE)
  xd <- xd[grepl("xt_dropped_all_highcard", csa_note)]
  # the same rows as the main analysis (current specs, real data), with the main run's paper metadata
  meta_cols <- c("paper", "journal", "year", "static_or_event", "share_always", "share_never", "n_cohorts", "cite_modern", "reports_modern_ft", "cited_by", "preferred", "in_abstract_intro")
  key_d <- d[xt_rows, c("suffix", "spec_id", "window", intersect(meta_cols, names(d))), with = FALSE]
  xd <- merge(xd[, setdiff(names(xd), meta_cols), with = FALSE], key_d, by = c("suffix", "spec_id", "window"))
  xd[, pass := G_eff >= 10 & L_max <= 0.25]; lev_flags(xd, "csa")
  xd_like <- xd
}
for (dd in list(d, d_auth, synth)) dd[grepl(XT_PAT, csa_note), `:=`(csa = NA_real_, csa_se = NA_real_, csa_fc = NA_real_, csa_fc_se = NA_real_, cov_twfe_csa = NA_real_, boot_cor_twfe_csa = NA_real_,
                                                              csa_note = paste0(csa_note, ";csa_dropped_highcard_xt"))]
lev_flags(d, "csa"); lev_flags(d_auth, "csa")   # synth gets its pass flags where it is screened below
cat(sprintf("high-cardinality characteristics: DiD-averaging dropped for %d rows (%d specs, %d papers); %d would have passed the screen\n", sum(xt_rows), uniqueN(d[xt_rows, paste(suffix, spec_id)]), uniqueN(d[xt_rows, paper]), nXtHighcardCmp))
fwrite(d, file.path(if (MAIN_RUN) "output" else OUTT, "specs_main.csv"))   # specification-level dataset of the main analysis (pass flags included; read by code/23_characteristics.py, Nov 4)
# Main comparison: one row per specification (static estimate or event-study post-window average).
# Pre-window averages are pre-trend summaries (Hull Appendix B) and are compared separately below.
d_pre <- d[window == "pre"]; d_post <- d[window != "pre"]   # d keeps pre- and post-window averages (Hull Figure 2 convention); d_post is his Appendix A1 sample
cat(sprintf("%d specifications from %d papers; %d pass the leverage screen\n", nrow(d), uniqueN(d$paper), sum(d$pass, na.rm = TRUE)))

compare <- function(d, modern) {
  x <- d[get(paste0("pass_", modern)) %in% TRUE & !is.na(get(modern)) & !is.na(twfe)]   # Hull: both estimators pass
  m <- x[[modern]]; ms <- x[[paste0(modern, "_se")]]
  cv <- if (paste0("cov_twfe_", modern) %in% names(x)) fifelse(is.na(x[[paste0("cov_twfe_", modern)]]), 0, x[[paste0("cov_twfe_", modern)]]) else 0
  bc_ <- paste0("boot_cor_twfe_", modern); has_b <- if (bc_ %in% names(x)) is.finite(x[[bc_]]) & is.finite(cv) & cv != 0 else rep(FALSE, nrow(x))
  # Hull fn 18: analytic SEs with the bootstrap covariance. Where the two imply a non-positive variance for the difference
  # (analytic SEs below the bootstrap SDs, bootstrap correlation near 1), the bootstrap correlation is scaled by the analytic
  # SEs instead (always a valid variance). Flooring the variance at zero would count any nonzero difference as significant
  # (found Nov 2 on the 999-draw preview: 4 DiD-averaging and 10 imputation rows).
  negvar <- has_b & x$twfe_se^2 + ms^2 - 2 * cv <= 0
  cv_raw <- cv; if (any(negvar)) cv[negvar] <- x[[bc_]][negvar] * x$twfe_se[negvar] * ms[negvar]
  diff_se <- sqrt(pmax(x$twfe_se^2 + ms^2 - 2 * cv, 1e-12))
  flip <- sign(x$twfe) != sign(m); sig <- abs(x$twfe - m) / diff_se > 1.96
  # robustness of the significance test (rows with a bootstrap covariance): zero covariance; bootstrap correlation scaled by the
  # reported SEs (always a valid variance); variance of the difference entirely from the bootstrap draws
  zsig <- function(v) abs(x$twfe - m) / sqrt(pmax(v, 1e-12)) > 1.96
  sig_zero <- zsig(x$twfe_se^2 + ms^2)
  sig_corr <- if (any(has_b)) zsig(x$twfe_se^2 + ms^2 - 2 * fifelse(has_b, x[[bc_]], 0) * x$twfe_se * ms) else sig_zero
  sig_bvar <- if (any(has_b)) zsig(fifelse(has_b, x$boot_sd_twfe^2 + x[[paste0("boot_sd_", modern)]]^2 - 2 * cv_raw, x$twfe_se^2 + ms^2)) else sig_zero
  rob <- list(n_boot = sum(has_b), n_negvar = sum(negvar), sig_flip_zero = mean(flip & sig_zero),
              sig_flip_corr = mean(flip & sig_corr), sig_flip_bvar = mean(flip & sig_bvar),
              sig_diff = mean(sig), sig_diff_zero = mean(sig_zero), boot_cor_median = if (any(has_b)) median(x[[bc_]][has_b]) else NA_real_)
  pw <- 1 / as.numeric(table(x$paper)[x$paper]); pw <- pw / sum(pw)   # paper weights: each paper counts once
  corr_pw <- if (nrow(x) > 2) tryCatch(cov.wt(cbind(x$twfe, m), wt = pw, cor = TRUE)$cor[1, 2], error = function(e) NA_real_) else NA_real_
  list(n = nrow(x), papers = uniqueN(x$paper), corr = cor(x$twfe, m), flip = mean(flip), sig_flip = mean(flip & sig), rob = rob,
       flip_papers = uniqueN(x$paper[flip]), sig_flip_papers = uniqueN(x$paper[flip & sig]),   # papers with >= 1 (significant) sign reversal (abstract, Nov 4)
       se_ratio = mean(ms / x$twfe_se), flip_pw = sum(pw * flip), sig_flip_pw = sum(pw * (flip & sig)), corr_pw = corr_pw, se_ratio_pw = sum(pw * ms / x$twfe_se), x = x[, .(paper, spec_id, window, journal, year, twfe, twfe_se, modern = m, modern_se = ms, cov = cv, flip, static_or_event,
                                                   share_always, share_never, n_cohorts, cite_modern, reports_modern_ft, cited_by, preferred, in_abstract_intro)])
}
res <- list(csa = compare(d, "csa"), bjs = compare(d, "bjs"))
# high-cardinality checks (block after d <- dHA): the old asymmetric comparison and the like-with-like one
res_xasym <- compare(d_xt_asym, "csa"); if (!is.null(xd_like)) res_xlike <- compare(xd_like, "csa")
if (!is.null(res_xlike)) cat(sprintf("high-cardinality check: like-with-like %d comparisons (%d papers): corr %.2f, sign reversals %.1f%%, significant %.1f%%; asymmetric (old) %d comparisons: corr %.2f, %.1f%%, %.1f%%\n",
                                     res_xlike$n, res_xlike$papers, res_xlike$corr, 100 * res_xlike$flip, 100 * res_xlike$sig_flip, res_xasym$n, res_xasym$corr, 100 * res_xasym$flip, 100 * res_xasym$sig_flip))
# synthetic/disguised package data (Appendix): the same rules as the main comparison, pre-windows included, both-estimator
# leverage screen and the same significance test (code review #3, Nov 3; previously computed in appendix.R with other rules)
synth[, pass := G_eff >= 10 & L_max <= 0.25]; lev_flags(synth)
res_syn <- list(csa = compare(synth, "csa"), bjs = compare(synth, "bjs"))
res_pre <- list(csa = compare(d_pre, "csa"), bjs = compare(d_pre, "bjs"))
res_post <- list(csa = compare(d_post, "csa"), bjs = compare(d_post, "bjs"))
# Sensitivity to individual papers (decision, Nov 3): every paper is treated alike. The earlier results without one named paper
# (mnsc.2021.01740, Nov 2) are dropped; instead each statistic is recomputed dropping one paper at a time (loo below), and the
# text reports the range. No paper is singled out or named.
# Unbalanced panels (Nov 2, decision: follow Hull): the main DiD-averaging estimate is did's cohort-average estimator
# (allow_unbalanced_panel = TRUE). Robustness: composition-fixed cells (units observed in g-1 and t; the main estimator until
# Nov 2), stored as csa_fc; identical to the main estimate in balanced panels and repeated cross-sections. No bootstrap
# covariance for csa_fc, so its significance test uses zero covariance.
for (v in c("csa_fc", "csa_fc_se")) if (!v %in% names(d)) d[, (v) := NA_real_]
d[, unbal := is.finite(csa_fc) | grepl("unbalanced_did", csa_note)]
# the size-guard lean path writes "size_did_lean" without the unbalanced marker (code review #4, Nov 3): classify those rows from
# the guard note's period count, unbalanced when rows < units x periods (mnsc.2021.4209 T2_m3, mnsc.2023.01423 T9)
d[, T_note := suppressWarnings(as.numeric(sub(".*csa_skipped_size:G=[0-9]+,T=([0-9]+),N=.*", "\\1", csa_note)))]
d[grepl("size_did_lean", csa_note) & is.finite(T_note) & !grepl("rc_did_lean", csa_note), unbal := unbal | (as.numeric(n) < as.numeric(n_units) * T_note)]
d[, T_note := NULL]
d[, `:=`(csa_alt = fifelse(is.finite(csa_fc), csa_fc, csa), csa_alt_se = fifelse(is.finite(csa_fc), csa_fc_se, csa_se),
         cov_twfe_csa_alt = fifelse(is.finite(csa_fc), 0, cov_twfe_csa))]
d[, pass_csa_alt := pass_csa]   # no leverage weights for csa_fc: the same rows as the main DiD-averaging screen (Nov 3)
res_fc <- compare(d, "csa_alt")
res_unbal <- list(csa = compare(d[unbal == TRUE], "csa"), bjs = compare(d[unbal == TRUE], "bjs"))
res_bal <- list(csa = compare(d[unbal == FALSE], "csa"), bjs = compare(d[unbal == FALSE], "bjs"))
# Without the leverage screen (decision, Nov 3: report the papers the screen removes, appendix robustness): every re-estimated
# comparison with both estimates, including the 8 papers in which no specification passes Hull's screen
d_ns <- copy(d)[, `:=`(pass_csa = TRUE, pass_bjs = TRUE)]
res_ns <- list(csa = compare(d_ns, "csa"), bjs = compare(d_ns, "bjs"))
nNoPass <- uniqueN(d$paper) - d[pass == TRUE, uniqueN(paper)]
# Option A: DiD-averaging with Hull's settings for every spec, and the published-CS specs alone under both settings
res_auth <- compare(d_auth, "csa")   # authors' CS settings for the papers that publish a CS estimate (appendix)
res_pub <- compare(d[pubcs == TRUE], "csa"); res_pubB <- compare(d_auth[pubcs == TRUE], "csa")
# change from Hull's settings (main) to the authors' settings, in units of the main SE, over the specifications (static estimates and
# post-window averages), as in the appendix table published_cs.tex
gapB <- merge(d[pubcs == TRUE, .(paper, spec_id, window, csaA = csa, seA = csa_se)], d_auth[pubcs == TRUE, .(paper, spec_id, window, csaB = csa)], by = c("paper", "spec_id", "window"))
gapB[, gse := (csaB - csaA) / seA]; gapB <- gapB[window != "pre"]
print(gapB[abs(gse) > 1][order(-abs(gse))])
summ <- rbindlist(lapply(names(res), function(k) { r <- res[[k]]; data.table(estimator = k, n = r$n, papers = r$papers, corr = r$corr, flip = r$flip, sig_flip = r$sig_flip, se_ratio = r$se_ratio, flip_pw = r$flip_pw, sig_flip_pw = r$sig_flip_pw, corr_pw = r$corr_pw) }))
print(summ)

# ---- Figure 2 (layout follows Hull 2026, Figure 2) --------------------------------------
JCOL <- c(mnsc = "#0072B2", mksc = "#D55E00", jmr = "#009E73", isre = "#CC79A7", msom = "#E69F00", opre = "#56B4E9", orsc = "#999933")
JLAB <- c(mnsc = "Management Science", mksc = "Marketing Science", jmr = "JMR", isre = "ISR", msom = "M&SOM", opre = "Operations Research", orsc = "Organization Science")
fig2_panel <- function(r, title) {
  x <- copy(r$x); x[, `:=`(xt = pmax(pmin(twfe / twfe_se, 10), -10), yt = pmax(pmin(modern / twfe_se, 10), -10))]
  x[, dse := sqrt(pmax(twfe_se^2 + modern_se^2 - 2 * cov, 1e-12))][, sig := abs(twfe - modern) / dse > 1.96][, ev := grepl("event", static_or_event)]
  # axes padded past the +-10 cap (Hull's convention) so capped points are drawn in full inside the frame
  plot(NA, xlim = c(-10.8, 10.8), ylim = c(-10.8, 10.8), xlab = "TWFE / SE(TWFE)", ylab = "Modern estimate / SE(TWFE)", main = title,
       font.main = 1, cex.main = 1.05, las = 1, xaxs = "i", yaxs = "i", bty = "o", xaxt = "n", yaxt = "n")
  axis(1, at = seq(-10, 10, 5), cex.axis = 0.85); axis(2, at = seq(-10, 10, 5), las = 1, cex.axis = 0.85)
  abline(h = 0, v = 0, col = "grey82"); abline(0, 1, col = "black", lwd = 0.7)
  col <- unname(JCOL[x$journal]); col[is.na(col)] <- "grey40"
  points(x$xt, x$yt, pch = ifelse(x$ev, 22, 21), col = col, bg = ifelse(x$sig, col, "white"), cex = 0.75, lwd = 0.8)
  legend("bottomright", bty = "n", cex = 0.72, inset = 0.01, legend = c(sprintf("Correlation: %.3f", r$corr), sprintf("Sign reversals: %.1f%%", 100 * r$flip), sprintf("Significant reversals: %.1f%%", 100 * r$sig_flip)))
}
fig2 <- function(rA, rB, file) {
  if (rA$n == 0 || rB$n == 0) return(invisible(NULL))
  pdf(file, width = 9, height = 5.4, family = "Times")
  layout(matrix(c(1, 2, 3, 3), 2, 2, byrow = TRUE), heights = c(4.4, 1.0))
  par(mar = c(3.6, 4, 2.2, 1), mgp = c(2.2, 0.6, 0), pty = "s")
  fig2_panel(rA, "A. DiD-Averaging"); fig2_panel(rB, "B. Imputation")
  par(mar = c(0, 0, 0, 0), pty = "m"); plot.new()
  js <- names(JCOL)[names(JCOL) %in% unique(c(rA$x$journal, rB$x$journal))]
  legend("top", horiz = TRUE, bty = "n", cex = 0.85, legend = JLAB[js], pch = 19, col = JCOL[js], pt.cex = 1.1, x.intersp = 0.8)
  legend("bottom", horiz = TRUE, bty = "n", cex = 0.85, legend = c("Scalar", "Event average", "Significant difference"), pch = c(21, 22, 19), col = "black", pt.bg = c("white", "white", "black"), pt.cex = 1.1, x.intersp = 0.8)
  dev.off()
}
dir.create("paper/figures", showWarnings = FALSE, recursive = TRUE); FIGD <- if (MAIN_RUN) "output/figures" else OUTT
fig2(res$csa, res$bjs, file.path(FIGD, "fig2.pdf")); if (MAIN_RUN && file.exists("output/figures/fig2.pdf")) file.copy("output/figures/fig2.pdf", "paper/figures/fig2.pdf", overwrite = TRUE)
fig2(res_post$csa, res_post$bjs, file.path(FIGD, "fig2_post.pdf")); if (MAIN_RUN && file.exists("output/figures/fig2_post.pdf")) file.copy("output/figures/fig2_post.pdf", "paper/figures/fig2_post.pdf", overwrite = TRUE)

# ---- Negative weights (Figure A3 analog) ---------------------------------------------
nw <- d[static_or_event %in% c("static", NA), .(neg_rows, neg_abs)]
nw_summary <- nw[, .(mean_rows = mean(neg_rows, na.rm = TRUE), median_rows = median(neg_rows, na.rm = TRUE), mean_abs = mean(neg_abs, na.rm = TRUE), median_abs = median(neg_abs, na.rm = TRUE), n = .N)]
print(nw_summary)

# ---- Correlates (Figure 3 analog): separate paper-weighted LPMs of sign flip on each predictor ----
correlates <- function(x) {
  x <- copy(x); x[, w := 1 / twfe_se^2]; x[, w := w / sum(w), by = paper]
  x[, `:=`(year10 = as.numeric(year) / 10, always10 = 10 * share_always, never10 = 10 * share_never,
           event = as.integer(grepl("event", static_or_event)), modern = as.integer(cite_modern > 0 | reports_modern_ft > 0),
           cites = log1p(as.numeric(cited_by)), pref = as.integer(preferred), abs_intro = as.integer(in_abstract_intro),
           mksc = as.integer(journal == "mksc"), jmr = as.integer(journal == "jmr"))]
  preds <- list(year10 = "Publication year / 10", modern = "Cites or reports a modern estimator", cites = "Log(1 + citations)",
                mksc = "Marketing Science (vs MS)", jmr = "JMR (vs MS)", abs_intro = "Abstract/intro prominence",
                pref = "Preferred specification", event = "Event study", always10 = "Always-treated share (per 10 pp)",
                never10 = "Never-treated share (per 10 pp)")
  out <- list()
  for (v in names(preds)) {
    if (!v %in% names(x) || all(is.na(x[[v]])) || length(unique(na.omit(x[[v]]))) < 2) next
    m <- tryCatch(fixest::feols(as.formula(paste0("flip ~ ", v)), data = x, weights = ~w, cluster = ~paper), error = function(e) NULL)
    if (!is.null(m)) out[[v]] <- data.table(predictor = preds[[v]], coef = coef(m)[v], se = fixest::se(m)[v], n = nobs(m))
  }
  rbindlist(out)
}
corr_tabs <- list()
for (k in names(res)) if (res[[k]]$n > 10) {
  cc <- correlates(res[[k]]$x); cc[, estimator := k]; corr_tabs[[k]] <- cc
}
if (length(corr_tabs)) {
  ct <- rbindlist(corr_tabs); fwrite(ct, file.path(OUTT, "correlates.csv")); print(ct)
  w <- dcast(ct, predictor ~ estimator, value.var = c("coef", "se"))
  tex <- c("\\begin{tabular}{lcc}", "\\toprule", " & DiD-averaging & Imputation \\\\", "\\midrule")
  for (i in seq_len(nrow(w))) tex <- c(tex, sprintf("%s & %s & %s \\\\", w$predictor[i], ifelse(is.na(w$coef_csa[i]), "--", sprintf("%.3f (%.3f)", w$coef_csa[i], w$se_csa[i])), ifelse(is.na(w$coef_bjs[i]), "--", sprintf("%.3f (%.3f)", w$coef_bjs[i], w$se_bjs[i]))))
  tex <- c(tex, "\\bottomrule", "\\end{tabular}")
  dir.create("paper/tables", showWarnings = FALSE, recursive = TRUE); writeLines(tex, file.path(TAB, "correlates.tex"))
}

# ---- Hierarchical model (Table 2 analog) ---------------------------------------------------
hier_tab <- list()
for (k in names(res)) {
  x <- res[[k]]$x
  if (nrow(x) >= 30) {
    hd <- x[, .(bT = twfe, sT = twfe_se, bM = modern, sM = modern_se, cov = cov, paper)]
    fit <- tryCatch(hier_fit(hd), error = function(e) NULL)
    if (!is.null(fit)) { s <- hier_summary(fit); s[, estimator := k]; hier_tab[[k]] <- s }
  }
}
if (length(hier_tab)) { ht <- rbindlist(hier_tab); print(ht); fwrite(ht, file.path(OUTT, "hierarchical.csv")) }
# Paper-clustered bootstrap standard errors of the hierarchical summary (hier_boot: B = 100 resamples of papers). Slow (about
# 200 refits), so it runs only with HIER_BOOT=1 and is cached in output/tables/hierarchical_boot.csv; the cache is used only
# while its comparison counts match the current fit (Nov 4).
if (length(hier_tab) && Sys.getenv("HIER_BOOT") == "1") {
  hb <- rbindlist(lapply(names(hier_tab), function(k) { x <- res[[k]]$x
    s <- hier_boot(x[, .(bT = twfe, sT = twfe_se, bM = modern, sM = modern_se, cov = cov, paper)], B = 100); s[, `:=`(estimator = k, n = nrow(x))]; s }))
  fwrite(hb, file.path(OUTT, "hierarchical_boot.csv"))
}
hier_se <- if (length(hier_tab) && file.exists(file.path(OUTT, "hierarchical_boot.csv"))) fread(file.path(OUTT, "hierarchical_boot.csv")) else NULL
if (!is.null(hier_se)) { ht0 <- rbindlist(hier_tab); if (!identical(hier_se[match(ht0$estimator, estimator)]$n, as.integer(ht0$n))) { cat("hierarchical_boot.csv is stale (comparison counts differ): rerun with HIER_BOOT=1\n"); hier_se <- NULL } }
# ---- Leave-one-paper-out ranges (every paper treated alike; Nov 3) -------------------------------------------------------------
# For each estimator, drop each contributing paper in turn and recompute the comparison statistics and the hierarchical model.
loo <- rbindlist(lapply(c("csa", "bjs"), function(k) rbindlist(lapply(res[[k]]$x[, unique(paper)], function(p) {
  r <- compare(d[paper != p], k)
  h <- if (r$n >= 30) tryCatch(hier_summary(hier_fit(r$x[, .(bT = twfe, sT = twfe_se, bM = modern, sM = modern_se, cov = cov, paper)])), error = function(e) NULL) else NULL
  data.table(estimator = k, dropped = p, corr = r$corr, flip = r$flip, sig_flip = r$sig_flip, corr_pw = r$corr_pw, flip_pw = r$flip_pw,
             sig_flip_pw = r$sig_flip_pw, h_corr = h$corr_estimands %||% NA_real_, h_flip = h$p_sign_reversal %||% NA_real_, h_sig = h$p_sig_wrong_sign %||% NA_real_)
}))))
fwrite(loo, file.path(OUTT, "leave_one_paper_out.csv"))
loo_rng <- loo[, lapply(.SD, function(v) list(c(min(v, na.rm = TRUE), max(v, na.rm = TRUE)))), by = estimator, .SDcols = -"dropped"]
lr <- function(k, col) loo_rng[estimator == k][[col]][[1]]

write_json(list(summary = summ, negative_weights = nw_summary, n_specs = nrow(d), n_papers = uniqueN(d$paper),
                by_journal = d[, .(specs = .N, papers = uniqueN(paper)), by = journal]), file.path(if (MAIN_RUN) "output" else OUTT, "summary.json"), auto_unbox = TRUE, pretty = TRUE)
fwrite(summ, file.path(OUTT, "comparison_summary.csv"))

# ---- LaTeX tables for the draft -----------------------------------------------------------
dir.create("paper/tables", showWarnings = FALSE, recursive = TRUE)
fmt <- function(x, d = 3) ifelse(is.na(x), "--", formatC(x, digits = d, format = "f"))
tex <- c("\\begin{tabular}{lcc}", "\\toprule", " & DiD-averaging & Imputation \\\\", "\\midrule",
  sprintf("Correlation of estimates & %s & %s \\\\", fmt(res$csa$corr), fmt(res$bjs$corr)),
  sprintf("Share of sign reversals & %s & %s \\\\", fmt(res$csa$flip), fmt(res$bjs$flip)),
  sprintf("Share of significant sign reversals & %s & %s \\\\", fmt(res$csa$sig_flip), fmt(res$bjs$sig_flip)),
  sprintf("Mean SE ratio (modern / TWFE) & %s & %s \\\\", fmt(res$csa$se_ratio, 2), fmt(res$bjs$se_ratio, 2)),
  "\\midrule", "\\multicolumn{3}{l}{\\emph{Paper-weighted (each paper counts once)}} \\\\",
  sprintf("Correlation of estimates & %s & %s \\\\", fmt(res$csa$corr_pw), fmt(res$bjs$corr_pw)),
  sprintf("Share of sign reversals & %s & %s \\\\", fmt(res$csa$flip_pw), fmt(res$bjs$flip_pw)),
  sprintf("Share of significant sign reversals & %s & %s \\\\", fmt(res$csa$sig_flip_pw), fmt(res$bjs$sig_flip_pw)),
  "\\midrule", "\\multicolumn{3}{l}{\\emph{Excluding pre-window averages of event studies}} \\\\",
  sprintf("Correlation of estimates & %s & %s \\\\", fmt(res_post$csa$corr), fmt(res_post$bjs$corr)),
  sprintf("Share of sign reversals & %s & %s \\\\", fmt(res_post$csa$flip), fmt(res_post$bjs$flip)),
  sprintf("Share of significant sign reversals & %s & %s \\\\", fmt(res_post$csa$sig_flip), fmt(res_post$bjs$sig_flip)),
  sprintf("Comparisons & %d & %d \\\\", res_post$csa$n, res_post$bjs$n),
  "\\midrule",
  sprintf("Comparisons & %d & %d \\\\", res$csa$n, res$bjs$n), sprintf("Papers & %d & %d \\\\", res$csa$papers, res$bjs$papers),
  "\\bottomrule", "\\end{tabular}")
writeLines(tex, file.path(TAB, "comparison.tex"))
tex <- c("\\begin{tabular}{lcc}", "\\toprule", " & DiD-averaging & Imputation \\\\", "\\midrule",
  sprintf("Correlation of estimates & %s & %s \\\\", fmt(res_syn$csa$corr), fmt(res_syn$bjs$corr)),
  sprintf("Share of sign reversals & %s & %s \\\\", fmt(res_syn$csa$flip), fmt(res_syn$bjs$flip)),
  sprintf("Share of significant sign reversals & %s & %s \\\\", fmt(res_syn$csa$sig_flip), fmt(res_syn$bjs$sig_flip)),
  sprintf("Mean SE ratio (modern / TWFE) & %s & %s \\\\", fmt(res_syn$csa$se_ratio, 2), fmt(res_syn$bjs$se_ratio, 2)),
  "\\midrule", "\\multicolumn{3}{l}{\\emph{Paper-weighted (each paper counts once)}} \\\\",
  sprintf("Correlation of estimates & %s & %s \\\\", fmt(res_syn$csa$corr_pw), fmt(res_syn$bjs$corr_pw)),
  sprintf("Share of sign reversals & %s & %s \\\\", fmt(res_syn$csa$flip_pw), fmt(res_syn$bjs$flip_pw)),
  sprintf("Share of significant sign reversals & %s & %s \\\\", fmt(res_syn$csa$sig_flip_pw), fmt(res_syn$bjs$sig_flip_pw)),
  "\\midrule", sprintf("Comparisons & %d & %d \\\\", res_syn$csa$n, res_syn$bjs$n), sprintf("Papers & %d & %d \\\\", res_syn$csa$papers, res_syn$bjs$papers),
  "\\bottomrule", "\\end{tabular}")
writeLines(tex, file.path(TAB, "synthetic_comparison.tex"))
# leave-one-paper-out ranges (appendix): full-sample value and [min, max] over dropping each contributing paper in turn
rng <- function(k, col, d_ = 3) { v <- lr(k, col); if (any(!is.finite(v))) "--" else sprintf("[%s, %s]", fmt(v[1], d_), fmt(v[2], d_)) }
hv0 <- function(k, col) { if (!length(hier_tab) || is.null(hier_tab[[k]])) NA_real_ else hier_tab[[k]][[col]] }
rowL <- function(lab, full_c, full_b, col) sprintf("%s & %s & %s & %s & %s \\\\", lab, fmt(full_c), rng("csa", col), fmt(full_b), rng("bjs", col))
tex <- c("\\begin{tabular}{lcccc}", "\\toprule", " & \\multicolumn{2}{c}{DiD-averaging} & \\multicolumn{2}{c}{Imputation} \\\\",
  "\\cmidrule(lr){2-3}\\cmidrule(lr){4-5}", " & All & One dropped & All & One dropped \\\\", "\\midrule",
  rowL("Correlation of estimates", res$csa$corr, res$bjs$corr, "corr"), rowL("Share of sign reversals", res$csa$flip, res$bjs$flip, "flip"),
  rowL("Share of significant sign reversals", res$csa$sig_flip, res$bjs$sig_flip, "sig_flip"),
  "\\midrule", "\\multicolumn{5}{l}{\\emph{Paper-weighted (each paper counts once)}} \\\\",
  rowL("Correlation of estimates", res$csa$corr_pw, res$bjs$corr_pw, "corr_pw"), rowL("Share of sign reversals", res$csa$flip_pw, res$bjs$flip_pw, "flip_pw"),
  rowL("Share of significant sign reversals", res$csa$sig_flip_pw, res$bjs$sig_flip_pw, "sig_flip_pw"),
  "\\midrule", "\\multicolumn{5}{l}{\\emph{Hierarchical model}} \\\\",
  rowL("Correlation of estimands", hv0("csa", "corr_estimands"), hv0("bjs", "corr_estimands"), "h_corr"),
  rowL("Prior probability of a sign reversal", hv0("csa", "p_sign_reversal"), hv0("bjs", "p_sign_reversal"), "h_flip"),
  rowL("Significant wrong-signed TWFE prob.", hv0("csa", "p_sig_wrong_sign"), hv0("bjs", "p_sig_wrong_sign"), "h_sig"),
  "\\midrule", sprintf("Papers & %d & & %d & \\\\", res$csa$papers, res$bjs$papers), "\\bottomrule", "\\end{tabular}")
writeLines(tex, file.path(TAB, "loo.tex"))
tex <- c("\\begin{tabular}{lcc}", "\\toprule", " & DiD-averaging & Imputation \\\\", "\\midrule",
  sprintf("Correlation of pre-window averages & %s & %s \\\\", fmt(res_pre$csa$corr), fmt(res_pre$bjs$corr)),
  sprintf("Share of sign reversals & %s & %s \\\\", fmt(res_pre$csa$flip), fmt(res_pre$bjs$flip)),
  sprintf("Share of significant sign reversals & %s & %s \\\\", fmt(res_pre$csa$sig_flip), fmt(res_pre$bjs$sig_flip)),
  sprintf("Share of TWFE pre-averages significant at 5\\%% & %s & %s \\\\", fmt(res_pre$csa$x[, mean(abs(twfe / twfe_se) > 1.96)]), fmt(res_pre$bjs$x[, mean(abs(twfe / twfe_se) > 1.96)])),
  sprintf("Share of modern pre-averages significant at 5\\%% & %s & %s \\\\", fmt(res_pre$csa$x[, mean(abs(modern / modern_se) > 1.96)]), fmt(res_pre$bjs$x[, mean(abs(modern / modern_se) > 1.96)])),
  "\\midrule", sprintf("Event studies & %d & %d \\\\", res_pre$csa$n, res_pre$bjs$n), sprintf("Papers & %d & %d \\\\", res_pre$csa$papers, res_pre$bjs$papers),
  "\\bottomrule", "\\end{tabular}")
writeLines(tex, file.path(TAB, "pretrends.tex"))
# ---- Split by whether the paper itself reports a modern estimator (decision, Nov 1) ---------------
res_mod <- list(csa = compare(d[reported_modern == TRUE], "csa"), bjs = compare(d[reported_modern == TRUE], "bjs"))
res_tw  <- list(csa = compare(d[reported_modern == FALSE], "csa"), bjs = compare(d[reported_modern == FALSE], "bjs"))
row2 <- function(lab, f, d_ = 3) sprintf("%s & %s & %s & %s & %s \\\\", lab, fmt(f(res_tw$csa), d_), fmt(f(res_mod$csa), d_), fmt(f(res_tw$bjs), d_), fmt(f(res_mod$bjs), d_))
tex <- c("\\begin{tabular}{lcccc}", "\\toprule", " & \\multicolumn{2}{c}{DiD-averaging} & \\multicolumn{2}{c}{Imputation} \\\\",
  "\\cmidrule(lr){2-3} \\cmidrule(lr){4-5}", "Paper reports & TWFE only & modern DiD & TWFE only & modern DiD \\\\", "\\midrule",
  row2("Correlation of estimates", function(r) r$corr), row2("Share of sign reversals", function(r) r$flip),
  row2("Share of significant sign reversals", function(r) r$sig_flip), row2("Mean SE ratio (modern / TWFE)", function(r) r$se_ratio, 2),
  "\\midrule", sprintf("Comparisons & %d & %d & %d & %d \\\\", res_tw$csa$n, res_mod$csa$n, res_tw$bjs$n, res_mod$bjs$n),
  sprintf("Papers & %d & %d & %d & %d \\\\", res_tw$csa$papers, res_mod$csa$papers, res_tw$bjs$papers, res_mod$bjs$papers),
  "\\bottomrule", "\\end{tabular}")
writeLines(tex, file.path(TAB, "comparison_by_reported.tex"))
if (length(hier_tab)) {
  ht <- rbindlist(hier_tab); g <- function(k, col) { v <- ht[estimator == k][[col]]; if (!length(v)) "--" else if (col %in% c("n", "papers")) format(round(v), big.mark = ",") else fmt(v) }
  gse <- function(k, col) { if (is.null(hier_se)) return(NULL); v <- hier_se[estimator == k][[col]]; if (!length(v) || !is.finite(v)) "" else sprintf("(%s)", fmt(v)) }
  rowH <- function(lab, col) c(sprintf("%s & %s & %s \\\\", lab, g("csa", col), g("bjs", col)),
                               if (!is.null(hier_se)) sprintf(" & %s & %s \\\\", gse("csa", col), gse("bjs", col)))   # bootstrap SE line
  tex <- c("\\begin{tabular}{lcc}", "\\toprule", " & DiD-averaging & Imputation \\\\", "\\midrule",
    rowH("SD of TWFE estimands", "sd_twfe"),
    rowH("SD of modern-DiD estimands", "sd_modern"),
    rowH("Correlation of estimands", "corr_estimands"),
    rowH("Prior probability of a sign reversal", "p_sign_reversal"),
    rowH("Significant wrong-signed TWFE probability", "p_sig_wrong_sign"),
    "\\midrule", sprintf("Observations & %s & %s \\\\", g("csa", "n"), g("bjs", "n")), sprintf("Papers & %s & %s \\\\", g("csa", "papers"), g("bjs", "papers")),
    "\\bottomrule", "\\end{tabular}")
  writeLines(tex, file.path(TAB, "hierarchical.tex"))
}
writeLines(c("\\begin{tabular}{lcccc}", "\\toprule", " & Mean & Median & SD & N \\\\", "\\midrule",
  sprintf("Share of treated rows with negative weight & %s & %s & %s & %d \\\\", fmt(nw_summary$mean_rows), fmt(nw_summary$median_rows), fmt(nw[, sd(neg_rows, na.rm = TRUE)]), nw_summary$n),
  sprintf("Negative share of absolute weight & %s & %s & %s & %d \\\\", fmt(nw_summary$mean_abs), fmt(nw_summary$median_abs), fmt(nw[, sd(neg_abs, na.rm = TRUE)]), nw_summary$n),
  "\\bottomrule", "\\end{tabular}"), file.path(TAB, "negweights.tex"))
cat("LaTeX tables written to paper/tables/\n")

# ---- Side-by-side with Hull (2026) economics benchmarks ------------------------------------
hull <- list(csa = c(corr = 0.881, flip = 0.145, sig = 0.035, se = 1.47, hcorr = 0.913, hflip = 0.115, hsig = 0.021),
             bjs = c(corr = 0.930, flip = 0.108, sig = 0.022, se = 1.14, hcorr = 0.976, hflip = 0.056, hsig = 0.006))
hv <- function(k, col) { if (!length(hier_tab) || is.null(hier_tab[[k]])) return(NA_real_); hier_tab[[k]][[col]] }
row <- function(label, ours_c, ours_b, h_c, h_b, d = 3) sprintf("%s & %s & %s & %s & %s \\\\", label, fmt(ours_c, d), fmt(h_c, d), fmt(ours_b, d), fmt(h_b, d))
tex <- c("\\begin{tabular}{lcccc}", "\\toprule", " & \\multicolumn{2}{c}{DiD-averaging} & \\multicolumn{2}{c}{Imputation} \\\\",
  "\\cmidrule(lr){2-3}\\cmidrule(lr){4-5}", " & This paper & Hull (2026) & This paper & Hull (2026) \\\\", "\\midrule",
  row("Correlation of estimates", res$csa$corr, res$bjs$corr, hull$csa["corr"], hull$bjs["corr"]),
  row("Share of sign reversals", res$csa$flip, res$bjs$flip, hull$csa["flip"], hull$bjs["flip"]),
  row("Share of significant sign reversals", res$csa$sig_flip, res$bjs$sig_flip, hull$csa["sig"], hull$bjs["sig"]),
  row("Mean SE ratio (modern / TWFE)", res$csa$se_ratio, res$bjs$se_ratio, hull$csa["se"], hull$bjs["se"], 2),
  row("Share of sign reversals, excl. pre-window averages", res_post$csa$flip, res_post$bjs$flip, 0.128, 0.083),
  row("Correlation of estimands (hierarchical)", hv("csa", "corr_estimands"), hv("bjs", "corr_estimands"), hull$csa["hcorr"], hull$bjs["hcorr"]),
  row("Prior probability of a sign reversal", hv("csa", "p_sign_reversal"), hv("bjs", "p_sign_reversal"), hull$csa["hflip"], hull$bjs["hflip"]),
  row("Significant wrong-signed TWFE probability", hv("csa", "p_sig_wrong_sign"), hv("bjs", "p_sig_wrong_sign"), hull$csa["hsig"], hull$bjs["hsig"]),
  "\\midrule", sprintf("Comparisons & %d & 1,069 & %d & 1,116 \\\\", res$csa$n, res$bjs$n), sprintf("Papers & %d & 82 & %d & 89 \\\\", res$csa$papers, res$bjs$papers),
  "\\bottomrule", "\\end{tabular}")
writeLines(tex, file.path(TAB, "vs_hull.tex"))
# ---- DiD-averaging with Hull's settings (main) vs the authors' CS settings for the papers that publish a CS estimate (appendix) ----
rowB <- function(lab, f, d_ = 3) sprintf("%s & %s & %s & %s & %s \\\\", lab, fmt(f(res$csa), d_), fmt(f(res_auth), d_), fmt(f(res_pub), d_), fmt(f(res_pubB), d_))
tex <- c("\\begin{tabular}{lcccc}", "\\toprule", " & \\multicolumn{2}{c}{All specifications} & \\multicolumn{2}{c}{Papers publishing a CS estimate} \\\\",
  "\\cmidrule(lr){2-3}\\cmidrule(lr){4-5}", "CS settings & Hull's & Authors' & Hull's & Authors' \\\\", "\\midrule",
  rowB("Correlation of estimates", function(r) r$corr), rowB("Share of sign reversals", function(r) r$flip),
  rowB("Share of significant sign reversals", function(r) r$sig_flip), rowB("Mean SE ratio (modern / TWFE)", function(r) r$se_ratio, 2),
  "\\midrule", "\\multicolumn{5}{l}{\\emph{Paper-weighted (each paper counts once)}} \\\\",
  rowB("Correlation of estimates", function(r) r$corr_pw), rowB("Share of sign reversals", function(r) r$flip_pw),
  rowB("Share of significant sign reversals", function(r) r$sig_flip_pw),
  "\\midrule", sprintf("Comparisons & %d & %d & %d & %d \\\\", res$csa$n, res_auth$n, res_pub$n, res_pubB$n),
  sprintf("Papers & %d & %d & %d & %d \\\\", res$csa$papers, res_auth$papers, res_pub$papers, res_pubB$papers),
  "\\bottomrule", "\\end{tabular}")
writeLines(tex, file.path(TAB, "authcs.tex"))
# ---- Without the leverage screen (appendix robustness) -----------------------------------------------------------------------
rowN <- function(lab, f, d_ = 3) sprintf("%s & %s & %s & %s & %s \\\\", lab, fmt(f(res$csa), d_), fmt(f(res_ns$csa), d_), fmt(f(res$bjs), d_), fmt(f(res_ns$bjs), d_))
tex <- c("\\begin{tabular}{lcccc}", "\\toprule", " & \\multicolumn{2}{c}{DiD-averaging} & \\multicolumn{2}{c}{Imputation} \\\\",
  "\\cmidrule(lr){2-3}\\cmidrule(lr){4-5}", "Leverage screen & Applied & Not applied & Applied & Not applied \\\\", "\\midrule",
  rowN("Correlation of estimates", function(r) r$corr), rowN("Share of sign reversals", function(r) r$flip),
  rowN("Share of significant sign reversals", function(r) r$sig_flip), rowN("Mean SE ratio (modern / TWFE)", function(r) r$se_ratio, 2),
  "\\midrule", "\\multicolumn{5}{l}{\\emph{Paper-weighted (each paper counts once)}} \\\\",
  rowN("Correlation of estimates", function(r) r$corr_pw), rowN("Share of sign reversals", function(r) r$flip_pw),
  rowN("Share of significant sign reversals", function(r) r$sig_flip_pw),
  "\\midrule", sprintf("Comparisons & %d & %d & %d & %d \\\\", res$csa$n, res_ns$csa$n, res$bjs$n, res_ns$bjs$n),
  sprintf("Papers & %d & %d & %d & %d \\\\", res$csa$papers, res_ns$csa$papers, res$bjs$papers, res_ns$bjs$papers),
  "\\bottomrule", "\\end{tabular}")
writeLines(tex, file.path(TAB, "noscreen.tex"))

# ---- Why correlations are lower than in Hull (2026) (Nov 3; no paper is named in the text) -------------------------------
# Same comparison samples as res: correlation by tercile of the negative-weight share (static specifications; analog of Hull's
# Appendix Figure A4) and in designs without never-treated units, with comparison and paper counts. (A greedy "drop the five
# papers that raise the correlation most" measure was removed on the referee review, Nov 3: one-directional; the symmetric
# leave-one-paper-out ranges replace it.)
gap_diag <- function(k) {
  x <- d[get(paste0("pass_", k)) %in% TRUE & !is.na(get(k)) & !is.na(twfe)]; x[, m := get(k)]
  cr <- function(z) if (nrow(z) > 2) cor(z$twfe, z$m) else NA_real_
  st <- x[window == "static" & is.finite(neg_abs)]; tq <- quantile(st$neg_abs, c(1/3, 2/3))
  lo <- st[neg_abs <= tq[1]]; hi <- st[neg_abs > tq[2]]; nn <- x[share_never %in% 0]
  list(neg_low = cr(lo), neg_high = cr(hi), neg_low_n = nrow(lo), neg_high_n = nrow(hi), neg_low_p = uniqueN(lo$paper), neg_high_p = uniqueN(hi$paper),
       no_never = cr(nn), no_never_n = nrow(nn), no_never_papers = uniqueN(nn$paper), unbal_papers = uniqueN(x[unbal == TRUE, paper]))
}
gd <- list(csa = gap_diag("csa"), bjs = gap_diag("bjs"))
# Comparison-level regression of sign reversals on design features (referee review, Nov 3): linear probability model with
# Hull's correlates weights (inverse TWFE variance, normalized to sum to one within paper) and paper-clustered SEs. Column 2 of
# each estimator adds the negative share of absolute TWFE weight, defined for static specifications only.
dis_reg <- function(k, static_only) {
  x <- d[get(paste0("pass_", k)) %in% TRUE & !is.na(get(k)) & !is.na(twfe)]; x[, m := get(k)]
  x[, `:=`(flip = as.integer(sign(twfe) != sign(m)), unbal_i = as.integer(unbal), no_never = as.integer(share_never %in% 0),
           lcoh = log(as.numeric(n_cohorts)), event = as.integer(window != "static"), always10 = 10 * share_always, negabs10 = 10 * neg_abs)]
  # the always-treated share and the negative-weight share are recorded for static specifications only, so they enter the
  # static columns; the "All" columns use the features defined for every comparison
  if (static_only) x <- x[window == "static" & is.finite(neg_abs) & is.finite(always10)]
  x <- x[is.finite(lcoh)]
  x[, w := 1 / twfe_se^2]; x[, w := w / sum(w), by = paper]
  f <- if (static_only) flip ~ unbal_i + no_never + lcoh + always10 + negabs10 else flip ~ unbal_i + no_never + lcoh + event
  fit <- fixest::feols(f, data = x, weights = ~w, cluster = ~paper)
  list(coef = coef(fit), se = fixest::se(fit), n = nobs(fit), papers = uniqueN(x$paper), mean = weighted.mean(x$flip, x$w))
}
dr <- list(csa_all = dis_reg("csa", FALSE), csa_st = dis_reg("csa", TRUE), bjs_all = dis_reg("bjs", FALSE), bjs_st = dis_reg("bjs", TRUE))
cell <- function(r, v) if (v %in% names(r$coef)) sprintf("%s (%s)", fmt(r$coef[[v]]), fmt(r$se[[v]])) else ""
regrows <- list(unbal_i = "Unbalanced panel", no_never = "No never-treated units", lcoh = "Log adoption cohorts",
                event = "Event-study window", always10 = "Always-treated share (per 10 pp)", negabs10 = "Negative weight share (per 10 pp)")
tex <- c("\\begin{tabular}{lcccc}", "\\toprule", " & \\multicolumn{2}{c}{DiD-averaging} & \\multicolumn{2}{c}{Imputation} \\\\",
  "\\cmidrule(lr){2-3}\\cmidrule(lr){4-5}", " & All & Static & All & Static \\\\", "\\midrule",
  vapply(names(regrows), function(v) sprintf("%s & %s & %s & %s & %s \\\\", regrows[[v]], cell(dr$csa_all, v), cell(dr$csa_st, v), cell(dr$bjs_all, v), cell(dr$bjs_st, v)), ""),
  "\\midrule", sprintf("Mean sign reversal (weighted) & %s & %s & %s & %s \\\\", fmt(dr$csa_all$mean), fmt(dr$csa_st$mean), fmt(dr$bjs_all$mean), fmt(dr$bjs_st$mean)),
  sprintf("Comparisons & %d & %d & %d & %d \\\\", dr$csa_all$n, dr$csa_st$n, dr$bjs_all$n, dr$bjs_st$n),
  sprintf("Papers & %d & %d & %d & %d \\\\", dr$csa_all$papers, dr$csa_st$papers, dr$bjs_all$papers, dr$bjs_st$papers), "\\bottomrule", "\\end{tabular}")
writeLines(tex, file.path(TAB, "disagreement.tex"))
# (high-cardinality characteristics: see the block after d <- dHA; macros nXtHighcardCmp, *XtLike, *XtAsym)

# ---- Macros for the prose ------------------------------------------------------------------
pct <- function(x, d = 1) ifelse(is.na(x), "--", formatC(100 * x, digits = d, format = "f"))
# correlates-table coefficients for the text (output/tables/correlates.csv; Nov 4)
cv <- function(k, lab, col) { if (!exists("ct")) return(NA_real_); v <- ct[estimator == k & predictor == lab][[col]]; if (length(v) == 1) v else NA_real_ }
# sharp divergences: comparisons passing the screen with |TWFE - modern| above half an outcome SD (Section 4 discussion, Nov 4)
big <- function(k) { x <- copy(res[[k]]$x)   # res predates the unbal flag (defined after the main comparison), so attach it by key
  x[, unbal := d$unbal[match(paste(x$paper, x$spec_id, x$window), d[, paste(paper, spec_id, window)])]]; x[abs(twfe - modern) > 0.5] }
# claim guard: Section 4 says "All of them come from unbalanced panels"; warn loudly if the data stop supporting it
if (any(vapply(c("csa", "bjs"), function(k) { b <- big(k); nrow(b) > 0 && !all(b$unbal %in% TRUE) }, logical(1))))
  cat("CLAIM CHECK: some sharp divergences (|TWFE - modern| > 0.5 SD) are NOT in unbalanced panels; edit the Section 4 sentence 'All of them come from unbalanced panels'\n")
# bootstrap SEs of the hierarchical summary for the text (hierarchical_boot.csv, when current)
hse <- function(k, col) { if (is.null(hier_se)) return(NA_real_); v <- hier_se[estimator == k][[col]]; if (length(v) == 1) v else NA_real_ }
mac <- c(
  nMainSpecs = d[window != "pre", .N], nMainComparisons = nrow(d), nMainPapers = uniqueN(d$paper), nPassSpecs = sum(d$pass, na.rm = TRUE),
  synthSpecs = synth[window != "pre", .N], synthPapers = uniqueN(synth$paper),
  corrCSA = fmt(res$csa$corr, 2), corrBJS = fmt(res$bjs$corr, 2),
  flipCSA = pct(res$csa$flip), flipBJS = pct(res$bjs$flip), sigflipCSA = pct(res$csa$sig_flip), sigflipBJS = pct(res$bjs$sig_flip),
  seratioCSA = fmt(res$csa$se_ratio, 2), seratioBJS = fmt(res$bjs$se_ratio, 2),
  flipCSApw = pct(res$csa$flip_pw), flipBJSpw = pct(res$bjs$flip_pw), sigflipCSApw = pct(res$csa$sig_flip_pw), sigflipBJSpw = pct(res$bjs$sig_flip_pw), corrCSApw = fmt(res$csa$corr_pw, 2), corrBJSpw = fmt(res$bjs$corr_pw, 2),
  nCSA = res$csa$n, nBJS = res$bjs$n, papersCSA = res$csa$papers, papersBJS = res$bjs$papers,
  nFlipPapersCSA = res$csa$flip_papers, nFlipPapersBJS = res$bjs$flip_papers, nSigFlipPapersCSA = res$csa$sig_flip_papers, nSigFlipPapersBJS = res$bjs$sig_flip_papers,
  nCSApost = res_post$csa$n, nBJSpost = res_post$bjs$n, flipCSApost = pct(res_post$csa$flip), flipBJSpost = pct(res_post$bjs$flip), sigflipCSApost = pct(res_post$csa$sig_flip), sigflipBJSpost = pct(res_post$bjs$sig_flip), corrCSApost = fmt(res_post$csa$corr, 2), corrBJSpost = fmt(res_post$bjs$corr, 2),
  nPreCSA = res_pre$csa$n, nPreBJS = res_pre$bjs$n, preCorrCSA = fmt(res_pre$csa$corr, 2), preCorrBJS = fmt(res_pre$bjs$corr, 2), preFlipCSA = pct(res_pre$csa$flip), preFlipBJS = pct(res_pre$bjs$flip),
  preSigTWFE = pct(res_pre$csa$x[, mean(abs(twfe / twfe_se) > 1.96)]), preSigCSA = pct(res_pre$csa$x[, mean(abs(modern / modern_se) > 1.96)]), preSigBJS = pct(res_pre$bjs$x[, mean(abs(modern / modern_se) > 1.96)]),
  negRowsMedian = pct(nw_summary$median_rows), negAbsMedian = pct(nw_summary$median_abs), negRowsMean = pct(nw_summary$mean_rows), negAbsMean = pct(nw_summary$mean_abs),
  hCorrCSA = fmt(hv("csa", "corr_estimands"), 2), hCorrBJS = fmt(hv("bjs", "corr_estimands"), 2),
  hFlipCSA = pct(hv("csa", "p_sign_reversal")), hFlipBJS = pct(hv("bjs", "p_sign_reversal")),
  hFlipText = if (identical(pct(hv("csa", "p_sign_reversal")), pct(hv("bjs", "p_sign_reversal")))) paste0(pct(hv("csa", "p_sign_reversal")), " percent for both estimators") else paste0(pct(hv("csa", "p_sign_reversal")), " and ", pct(hv("bjs", "p_sign_reversal")), " percent"),   # avoids "28.0 and 28.0 percent" (review Nov 4)
  hSigCSA = pct(hv("csa", "p_sig_wrong_sign")), hSigBJS = pct(hv("bjs", "p_sig_wrong_sign")),
  shareNeverMean = pct(d[window != "pre", mean(share_never, na.rm = TRUE)]), shareAlwaysMean = pct(d[, mean(share_always, na.rm = TRUE)]),   # per specification, as in the characteristics table (review, Nov 4)
  medianCohorts = as.character(res$csa$x[, median(n_cohorts, na.rm = TRUE)]),   # screened DiD-averaging comparisons, the sample the sentence describes (review, Nov 4)
  nModPapers = res_mod$csa$papers, nModSpecs = res_mod$csa$n, nTwPapers = res_tw$csa$papers, nTwSpecs = res_tw$csa$n,
  flipCSAmod = pct(res_mod$csa$flip), flipCSAtw = pct(res_tw$csa$flip), flipBJSmod = pct(res_mod$bjs$flip), flipBJStw = pct(res_tw$bjs$flip),
  corrCSAmod = fmt(res_mod$csa$corr, 2), corrCSAtw = fmt(res_tw$csa$corr, 2),
  # bootstrap covariances and CSA estimates skipped by the feasibility guards (main sample, all windows)
  nCovCSA = res$csa$x[, sum(cov != 0)], nCovBJS = res$bjs$x[, sum(cov != 0)],
  sigflipCSAzero = pct(res$csa$rob$sig_flip_zero), sigflipBJSzero = pct(res$bjs$rob$sig_flip_zero),
  sigflipCSAcorr = pct(res$csa$rob$sig_flip_corr), sigflipBJScorr = pct(res$bjs$rob$sig_flip_corr),
  sigflipCSAbvar = pct(res$csa$rob$sig_flip_bvar), sigflipBJSbvar = pct(res$bjs$rob$sig_flip_bvar),
  sigdiffCSA = pct(res$csa$rob$sig_diff), sigdiffBJS = pct(res$bjs$rob$sig_diff), sigdiffCSAzero = pct(res$csa$rob$sig_diff_zero), sigdiffBJSzero = pct(res$bjs$rob$sig_diff_zero),
  bootCorCSA = fmt(res$csa$rob$boot_cor_median, 2), bootCorBJS = fmt(res$bjs$rob$boot_cor_median, 2),
  nNegVarCSA = res$csa$rob$n_negvar, nNegVarBJS = res$bjs$rob$n_negvar,
  # median SE ratios (the means are pulled up by a few event studies with very imprecise imputation estimates)
  seratioCSAmed = fmt(res$csa$x[, median(modern_se / twfe_se)], 2), seratioBJSmed = fmt(res$bjs$x[, median(modern_se / twfe_se)], 2),
  # unbalanced panels: composition-fixed DiD-averaging (robustness) and the balanced/unbalanced split
  corrCSAfc = fmt(res_fc$corr, 2), flipCSAfc = pct(res_fc$flip), sigflipCSAfc = pct(res_fc$sig_flip), nCSAfc = res_fc$n,
  nUnbalCSA = res_unbal$csa$n, nUnbalBJS = res_unbal$bjs$n, nBalCSA = res_bal$csa$n, nBalBJS = res_bal$bjs$n,
  shareUnbal = pct(d[pass == TRUE & !is.na(bjs), mean(unbal)]),
  corrCSAunbal = fmt(res_unbal$csa$corr, 2), corrBJSunbal = fmt(res_unbal$bjs$corr, 2), corrCSAbal = fmt(res_bal$csa$corr, 2), corrBJSbal = fmt(res_bal$bjs$corr, 2),
  flipCSAunbal = pct(res_unbal$csa$flip), flipBJSunbal = pct(res_unbal$bjs$flip), flipCSAbal = pct(res_bal$csa$flip), flipBJSbal = pct(res_bal$bjs$flip),
  nCSAskipSize = d[grepl("csa_skipped_size", csa_note) & is.na(csa), .N], nCSAskipMem = d[grepl("csa_skipped_memory", csa_note) & is.na(csa), .N],
  nCSAskipPapers = uniqueN(d[grepl("csa_skipped", csa_note) & is.na(csa), paper]),   # lean / server runs fill some guarded specs (Nov 2)
  nCSAlean = d[grepl("_did_lean", csa_note) & pass_csa %in% TRUE & is.finite(csa) & is.finite(twfe), .N], nCSAserver = d[grepl("run_on_server", csa_note), .N],
  nCSAnone = uniqueN(d[grepl("No valid att_gt|csa_unsupported:no_valid_cells", csa_note), paper]), nXtHighcard = d[grepl("xt_ignored_highcard|xt_dropped_all_highcard", csa_note), .N],
  # comparisons passing the TWFE screen without a DiD-averaging estimate (csa_na_note, Nov 3): no valid cells, or covariate
  # cells rank-deficient (estimate kept NA; the covariate is not dropped for one paper)
  nCSAunsupRowsAll = d[is.finite(twfe) & !is.finite(csa), .N], nCSAunsupPapersAll = uniqueN(d[is.finite(twfe) & !is.finite(csa), paper]),   # before the screen
  nCSAunsupRows = d[pass == TRUE & is.finite(twfe) & !is.finite(csa), .N], nCSAunsupPapers = uniqueN(d[pass == TRUE & is.finite(twfe) & !is.finite(csa), paper]),
  nCSArankdefPapers = uniqueN(d[pass == TRUE & is.finite(twfe) & !is.finite(csa) & grepl("covariate_cells_rank_deficient", csa_note), paper]),
  nCSAnocellsPapers = uniqueN(d[pass == TRUE & is.finite(twfe) & !is.finite(csa) & grepl("no_valid_cells|No valid att_gt", csa_note), paper]),
  nLevFailCSA = d[levfail_csa %in% TRUE, .N], nLevFailBJS = d[levfail_bjs %in% TRUE, .N],
  nLevFallbackCSA = d[levfb_csa %in% TRUE, .N], nLevFallbackBJS = d[levfb_bjs %in% TRUE, .N],
  synthPapersScreened = uniqueN(c(res_syn$csa$x$paper, res_syn$bjs$x$paper)),
  nBJSnotIdent = d[pass == TRUE & is.finite(bjs) & is.finite(twfe) & grepl("lev_bjs_inconsistent", lev_note), .N],
  # option A: Hull's DiD-averaging settings for the specs of papers that publish a CS estimate (main: the authors' settings)
  nPubCSrows = d[pubcs == TRUE, .N], nPubCSspecs = uniqueN(d[pubcs == TRUE, paste(paper, spec_id)]), nPubCSpapers = uniqueN(d[pubcs == TRUE, paper]),
  corrCSAauth = fmt(res_auth$corr, 2), flipCSAauth = pct(res_auth$flip), sigflipCSAauth = pct(res_auth$sig_flip), seratioCSAauth = fmt(res_auth$se_ratio, 2),
  corrCSApwauth = fmt(res_auth$corr_pw, 2), flipCSApwauth = pct(res_auth$flip_pw), sigflipCSApwauth = pct(res_auth$sig_flip_pw), nCSAauth = res_auth$n,
  corrCSApub = fmt(res_pub$corr, 2), corrCSApubAuth = fmt(res_pubB$corr, 2), flipCSApub = pct(res_pub$flip), flipCSApubAuth = pct(res_pubB$flip),
  sigflipCSApub = pct(res_pub$sig_flip), sigflipCSApubAuth = pct(res_pubB$sig_flip), nCSApub = res_pub$n,
  authMedGapSE = fmt(gapB[, median(abs(gse), na.rm = TRUE)], 3), authMaxGapSE = fmt(gapB[, max(abs(gse), na.rm = TRUE)], 1),
  nAuthMoveOneSE = gapB[abs(gse) > 1, .N], nAuthMoveOneSEpapers = uniqueN(gapB[abs(gse) > 1, paper]),
  nAuthSignChange = gapB[sign(csaA) != sign(csaB), .N], nAuthSignChangePapers = uniqueN(gapB[sign(csaA) != sign(csaB), paper]),
  # why correlations are lower than in Hull (2026)
  corrCSAnegLow = fmt(gd$csa$neg_low, 2), corrCSAnegHigh = fmt(gd$csa$neg_high, 2), corrBJSnegLow = fmt(gd$bjs$neg_low, 2), corrBJSnegHigh = fmt(gd$bjs$neg_high, 2),
  corrCSAnoNever = fmt(gd$csa$no_never, 2), corrBJSnoNever = fmt(gd$bjs$no_never, 2), nNoNeverPapers = gd$bjs$no_never_papers,
  nNegLowCSA = gd$csa$neg_low_n, nNegHighCSA = gd$csa$neg_high_n, nNegLowBJS = gd$bjs$neg_low_n, nNegHighBJS = gd$bjs$neg_high_n,
  nNoNeverCSA = gd$csa$no_never_n, nNoNeverBJS = gd$bjs$no_never_n, nNoNeverPapersCSA = gd$csa$no_never_papers,
  # regression of sign reversals on design features (paper/tables/disagreement.tex)
  regUnbalCSA = fmt(dr$csa_all$coef[["unbal_i"]]), regUnbalCSAse = fmt(dr$csa_all$se[["unbal_i"]]), regUnbalBJS = fmt(dr$bjs_all$coef[["unbal_i"]]), regUnbalBJSse = fmt(dr$bjs_all$se[["unbal_i"]]),
  regNoNeverCSA = fmt(dr$csa_all$coef[["no_never"]]), regNoNeverCSAse = fmt(dr$csa_all$se[["no_never"]]), regNoNeverBJS = fmt(dr$bjs_all$coef[["no_never"]]), regNoNeverBJSse = fmt(dr$bjs_all$se[["no_never"]]),
  regNegCSA = fmt(dr$csa_st$coef[["negabs10"]]), regNegCSAse = fmt(dr$csa_st$se[["negabs10"]]), regNegBJS = fmt(dr$bjs_st$coef[["negabs10"]]), regNegBJSse = fmt(dr$bjs_st$se[["negabs10"]]),
  # paper-weighted SE ratios; TWFE pre-trend significance on the imputation sample
  seratioCSApw = fmt(res$csa$se_ratio_pw, 2), seratioBJSpw = fmt(res$bjs$se_ratio_pw, 2),
  preSigTWFEbjs = pct(res_pre$bjs$x[, mean(abs(twfe / twfe_se) > 1.96)]),
  # reports-modern split, all statistics
  sigflipCSAmod = pct(res_mod$csa$sig_flip), sigflipCSAtw = pct(res_tw$csa$sig_flip), corrBJSmod = fmt(res_mod$bjs$corr, 2), corrBJStw = fmt(res_tw$bjs$corr, 2),
  sigflipBJSmod = pct(res_mod$bjs$sig_flip), sigflipBJStw = pct(res_tw$bjs$sig_flip),
  # papers that publish a CS estimate, paper-weighted, authors' vs Hull's settings
  corrCSApwpub = fmt(res_pub$corr_pw, 2), corrCSApwpubAuth = fmt(res_pubB$corr_pw, 2), flipCSApwpub = pct(res_pub$flip_pw), flipCSApwpubAuth = pct(res_pubB$flip_pw),
  sigflipCSApwpub = pct(res_pub$sig_flip_pw), sigflipCSApwpubAuth = pct(res_pubB$sig_flip_pw),
  # DiD-averaging without the comparisons that drop high-cardinality characteristics
  nXtHighcardCmp = nXtHighcardCmp, nXtHighcardPapers = nXtHighcardPapers, nXtHighcardBJS = nXtHighcardBJS, nXtHighcardBJSinc = nXtHighcardBJSinc, nXtLike = res_xlike$n %||% NA, nXtLikePapers = res_xlike$papers %||% NA, corrXtLike = fmt(res_xlike$corr %||% NA, 2), flipXtLike = pct(res_xlike$flip %||% NA), sigflipXtLike = pct(res_xlike$sig_flip %||% NA),
  nXtAsym = res_xasym$n, corrXtAsym = fmt(res_xasym$corr, 2), flipXtAsym = pct(res_xasym$flip), sigflipXtAsym = pct(res_xasym$sig_flip),
  # unbalanced share by estimator sample (shareUnbal is the imputation sample)
  shareUnbalCSA = pct(d[pass_csa %in% TRUE & !is.na(csa) & !is.na(twfe), mean(unbal)]), shareUnbalBJS = pct(d[pass_bjs %in% TRUE & !is.na(bjs) & !is.na(twfe), mean(unbal)]),
  nUnbalPapersCSA = gd$csa$unbal_papers, nUnbalPapersBJS = gd$bjs$unbal_papers,
  # without the leverage screen (appendix robustness)
  # leave-one-paper-out ranges (min, max over dropping each contributing paper; output/tables/leave_one_paper_out.csv)
  corrCSAlooMin = fmt(lr("csa", "corr")[1], 2), corrCSAlooMax = fmt(lr("csa", "corr")[2], 2), corrBJSlooMin = fmt(lr("bjs", "corr")[1], 2), corrBJSlooMax = fmt(lr("bjs", "corr")[2], 2),
  corrCSApwlooMin = fmt(lr("csa", "corr_pw")[1], 2), corrCSApwlooMax = fmt(lr("csa", "corr_pw")[2], 2), corrBJSpwlooMin = fmt(lr("bjs", "corr_pw")[1], 2), corrBJSpwlooMax = fmt(lr("bjs", "corr_pw")[2], 2),
  flipCSAlooMin = pct(lr("csa", "flip")[1]), flipCSAlooMax = pct(lr("csa", "flip")[2]), flipBJSlooMin = pct(lr("bjs", "flip")[1]), flipBJSlooMax = pct(lr("bjs", "flip")[2]),
  hCorrCSAlooMin = fmt(lr("csa", "h_corr")[1], 2), hCorrCSAlooMax = fmt(lr("csa", "h_corr")[2], 2), hCorrBJSlooMin = fmt(lr("bjs", "h_corr")[1], 2), hCorrBJSlooMax = fmt(lr("bjs", "h_corr")[2], 2),
  hFlipCSAlooMin = pct(lr("csa", "h_flip")[1]), hFlipCSAlooMax = pct(lr("csa", "h_flip")[2]), hFlipBJSlooMin = pct(lr("bjs", "h_flip")[1]), hFlipBJSlooMax = pct(lr("bjs", "h_flip")[2]),
  hSigCSAlooMin = pct(lr("csa", "h_sig")[1]), hSigCSAlooMax = pct(lr("csa", "h_sig")[2]), hSigBJSlooMin = pct(lr("bjs", "h_sig")[1]), hSigBJSlooMax = pct(lr("bjs", "h_sig")[2]),
  nNoPassPapers = nNoPass, nCSAnoscreen = res_ns$csa$n, nBJSnoscreen = res_ns$bjs$n, papersCSAnoscreen = res_ns$csa$papers, papersBJSnoscreen = res_ns$bjs$papers,
  corrCSAnoscreen = fmt(res_ns$csa$corr, 2), corrBJSnoscreen = fmt(res_ns$bjs$corr, 2), flipCSAnoscreen = pct(res_ns$csa$flip), flipBJSnoscreen = pct(res_ns$bjs$flip),
  sigflipCSAnoscreen = pct(res_ns$csa$sig_flip), sigflipBJSnoscreen = pct(res_ns$bjs$sig_flip),
  # sharp divergences (|TWFE - modern| > 0.5 SD): counts, papers, and the shares in unbalanced panels and without never-treated units
  nBigCSA = nrow(big("csa")), nBigBJS = nrow(big("bjs")), nBigPapersCSA = uniqueN(big("csa")$paper), nBigPapersBJS = uniqueN(big("bjs")$paper),
  shareBigCSA = pct(res$csa$x[, mean(abs(twfe - modern) > 0.5)]), shareBigBJS = pct(res$bjs$x[, mean(abs(twfe - modern) > 0.5)]),
  shareBigUnbalCSA = pct(big("csa")[, mean(unbal)]), shareBigUnbalBJS = pct(big("bjs")[, mean(unbal)]),
  shareBigNoNeverCSA = pct(big("csa")[, mean(share_never %in% 0)]), shareBigNoNeverBJS = pct(big("bjs")[, mean(share_never %in% 0)]),
  shareBigNoNeverBJStext = if (big("bjs")[, mean(share_never %in% 0)] >= 0.9995) "all" else paste0(pct(big("bjs")[, mean(share_never %in% 0)]), " percent"),   # "all" instead of "100.0 percent" (review Nov 4)
  shareBigEventCSA = pct(big("csa")[, mean(grepl("event", static_or_event))]), shareBigEventBJS = pct(big("bjs")[, mean(grepl("event", static_or_event))]),
  # correlates table: never-treated share (per 10 pp) and publication year (per decade) coefficients, with paper-clustered SEs
  corrNeverCSA = fmt(cv("csa", "Never-treated share (per 10 pp)", "coef")), corrNeverCSAse = fmt(cv("csa", "Never-treated share (per 10 pp)", "se")),
  corrNeverBJS = fmt(cv("bjs", "Never-treated share (per 10 pp)", "coef")), corrNeverBJSse = fmt(cv("bjs", "Never-treated share (per 10 pp)", "se")),
  corrYearCSA = fmt(cv("csa", "Publication year / 10", "coef")), corrYearCSAse = fmt(cv("csa", "Publication year / 10", "se")),
  corrYearBJS = fmt(cv("bjs", "Publication year / 10", "coef")), corrYearBJSse = fmt(cv("bjs", "Publication year / 10", "se")),
  nCorrSigCSA = if (exists("ct")) ct[estimator == "csa", sum(abs(coef) > 1.96 * se)] else NA, nCorrSigBJS = if (exists("ct")) ct[estimator == "bjs", sum(abs(coef) > 1.96 * se)] else NA,
  nCorrRowsCSA = if (exists("ct")) ct[estimator == "csa", .N] else NA, nCorrRowsBJS = if (exists("ct")) ct[estimator == "bjs", .N] else NA,
  # paper-bootstrap SEs of the hierarchical estimand correlation and sign-reversal probability (HIER_BOOT=1 cache)
  hCorrCSAse = fmt(hse("csa", "corr_estimands"), 2), hCorrBJSse = fmt(hse("bjs", "corr_estimands"), 2),
  hFlipCSAse = pct(hse("csa", "p_sign_reversal")), hFlipBJSse = pct(hse("bjs", "p_sign_reversal")),
  # printed-appendix specifications in the sample (APPENDIX_SPECS=1 runs; zero in the main run)
  nAddedSpecs = uniqueN(d[appendix_printed %in% TRUE, paste(paper, spec_id)]), nAddedPapers = uniqueN(d[appendix_printed %in% TRUE, paper])
)
writeLines(sprintf("\\newcommand{\\%s%s}{%s}", names(mac), MSUF, mac), file.path(TAB, "results_numbers.tex"))
cat("results macros written\n")
