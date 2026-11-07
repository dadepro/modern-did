# Secondary analysis (PROTOCOL 5c): TWFE vs modern DiD in specifications whose only violation is time-varying controls.
# Inputs : output/specs_controls/*.csv (run_spec.R), data/specs_controls/*.json (spec metadata)
# Outputs: output/tables/controls_summary.csv, output/summary_controls.json
# Same comparison rules as code/R/analysis.R (leverage screen G_eff >= 10 and L_max <= 0.25; flips; significant flips with
# the joint-bootstrap TWFE-modern covariance (zero where none); paper weights so each paper counts once). Rows: all, excluding mediator-control specs,
# and CSA restricted to estimates that actually condition on the controls (not flagged controls_ignored).
suppressPackageStartupMessages({ library(data.table); library(jsonlite) })
`%||%` <- function(a, b) if (is.null(a)) b else a
specs <- rbindlist(lapply(list.files("output/specs_controls", full.names = TRUE, pattern = "csv$"),
                          function(f) fread(f, colClasses = list(character = c("suffix", "spec_id")))), fill = TRUE)
meta <- rbindlist(lapply(list.files("data/specs_controls", full.names = TRUE, pattern = "json$"), function(f) {
  j <- fromJSON(f); data.table(suffix = j$suffix, spec_id = j$spec_id, journal = j$journal %||% NA,
    static_or_event = j$static_or_event %||% NA, provenance = j$data_provenance %||% "real",
    mediator_controls = isTRUE(j$mediator_controls), preferred = !isFALSE(j$preferred)) }), fill = TRUE)
d <- merge(specs, meta, by = c("suffix", "spec_id"))   # only specs with a current JSON (code review R2, Nov 3)
bfiles <- list.files("output/boot_cov_controls", full.names = TRUE, pattern = "csv$")   # joint bootstrap covariances (code/R/boot_cov.R)
if (length(bfiles)) { bc <- rbindlist(lapply(bfiles, function(f) fread(f, colClasses = list(character = c("suffix", "spec_id")))), fill = TRUE)
  d <- merge(d, bc[, .(suffix, spec_id, window, cov_twfe_csa, cov_twfe_bjs, boot_cor_twfe_csa, boot_cor_twfe_bjs)], by = c("suffix", "spec_id", "window"), all.x = TRUE) }
for (v in c("cov_twfe_csa", "cov_twfe_bjs", "boot_cor_twfe_csa", "boot_cor_twfe_bjs")) if (!v %in% names(d)) d[, (v) := NA_real_]
synth_list <- if (file.exists("data/synthetic_packages.txt")) readLines("data/synthetic_packages.txt") else character(0)
d[, synthetic := suffix %in% synth_list | (grepl("synth|disguis|pseudo|simulat|scrambl|fuzz", provenance, ignore.case = TRUE) & !grepl("^\\s*(real|original)", provenance, ignore.case = TRUE))]
cat(sprintf("%d rows from %d papers; %d rows from synthetic/disguised data excluded\n", nrow(d), uniqueN(d$suffix), sum(d$synthetic)))
d <- d[synthetic == FALSE]
d[, pass := G_eff >= 10 & L_max <= 0.25]
for (m in c("csa", "bjs")) {   # Hull App. B: both estimators pass (see analysis.R, Nov 2)
  gc <- paste0("G_eff_", m); lc <- paste0("L_max_", m)
  if (!gc %in% names(d)) d[, (gc) := NA_real_]
  if (!lc %in% names(d)) d[, (lc) := NA_real_]
  d[, paste0("pass_", m) := pass & fifelse(is.na(get(gc)) | is.na(get(lc)), TRUE, get(gc) >= 10 & get(lc) <= 0.25)]
}
d[, csa_uses_controls := !grepl("controls_ignored", csa_note)]

compare <- function(x, modern, label) {
  x <- x[get(paste0("pass_", modern)) %in% TRUE & !is.na(get(modern)) & !is.na(twfe)]
  if (!nrow(x)) return(data.table(sample = label, estimator = modern, n = 0L, papers = 0L))
  m <- x[[modern]]; ms <- x[[paste0(modern, "_se")]]
  cv <- x[[paste0("cov_twfe_", modern)]]; cv[!is.finite(cv)] <- 0
  # non-positive implied variance: scale the bootstrap correlation by the analytic SEs (same rule as code/R/analysis.R, Nov 2)
  rho <- x[[paste0("boot_cor_twfe_", modern)]]; neg <- is.finite(rho) & cv != 0 & x$twfe_se^2 + ms^2 - 2 * cv <= 0
  cv[neg] <- rho[neg] * x$twfe_se[neg] * ms[neg]
  flip <- sign(x$twfe) != sign(m); sig <- abs(x$twfe - m) / sqrt(pmax(x$twfe_se^2 + ms^2 - 2 * cv, 1e-12)) > 1.96
  pw <- 1 / as.numeric(table(x$suffix)[x$suffix]); pw <- pw / sum(pw)
  data.table(sample = label, estimator = modern, n = nrow(x), papers = uniqueN(x$suffix),
             corr = if (nrow(x) > 2) cor(x$twfe, m) else NA_real_, flip = mean(flip), sig_flip = mean(flip & sig),
             se_ratio = mean(ms / x$twfe_se), flip_pw = sum(pw * flip), sig_flip_pw = sum(pw * (flip & sig)),
             mean_abs_diff_sd = mean(abs(x$twfe - m)))
}
out <- rbind(
  compare(d, "csa", "all"), compare(d, "bjs", "all"),
  compare(d[mediator_controls == FALSE], "csa", "no_mediator_controls"), compare(d[mediator_controls == FALSE], "bjs", "no_mediator_controls"),
  if (any(!d$csa_uses_controls & !is.na(d$csa))) compare(d[csa_uses_controls == TRUE], "csa", "csa_conditions_on_controls"), fill = TRUE)
# (the "DiD-averaging conditions on controls" row is shown only when some DiD-averaging estimate ignores the controls; otherwise it
#  duplicates "All specifications", referee review Nov 3)
cat(sprintf("%d rows from %d papers after exclusions; %d pass the leverage screen; CSA ignores the controls in %d of %d CSA rows\n",
            nrow(d), uniqueN(d$suffix), sum(d$pass, na.rm = TRUE), sum(!d$csa_uses_controls & !is.na(d$csa)), sum(!is.na(d$csa))))
print(out)
by_paper <- d[pass == TRUE, .(rows = .N, csa_rows = sum(!is.na(csa)), bjs_rows = sum(!is.na(bjs)),
                              flip_csa = mean(sign(twfe) != sign(csa), na.rm = TRUE), flip_bjs = mean(sign(twfe) != sign(bjs), na.rm = TRUE)), by = suffix]
print(by_paper[order(suffix)])
dir.create("output/tables", showWarnings = FALSE, recursive = TRUE)
fwrite(out, "output/tables/controls_summary.csv"); fwrite(by_paper, "output/tables/controls_by_paper.csv")
write_json(list(summary = out, by_paper = by_paper, n_rows = nrow(d), n_papers = uniqueN(d$suffix)), "output/summary_controls.json", auto_unbox = TRUE, digits = 4, pretty = TRUE)

# ---- paper table and macros -----------------------------------------------------------------------
f2 <- function(x, d = 2) ifelse(is.na(x), "--", formatC(x, digits = d, format = "f")); p1 <- function(x) ifelse(is.na(x), "--", formatC(100 * x, digits = 1, format = "f"))
lab <- c(all = "All specifications", no_mediator_controls = "No mediator controls", csa_conditions_on_controls = "DiD-averaging conditions on controls")
row <- function(r) sprintf("%s & %s & %d & %d & %s & %s & %s & %s \\\\", lab[r$sample], if (r$estimator == "csa") "DiD-averaging" else "Imputation",
                           r$n, r$papers, f2(r$corr), p1(r$flip), p1(r$sig_flip), f2(r$se_ratio))
tex <- c("\\begin{tabular}{llrrrrrr}", "\\toprule", "Sample & Estimator & Comparisons & Papers & Corr. & Flips (\\%) & Sig.\\ flips (\\%) & SE ratio \\\\", "\\midrule",
         vapply(seq_len(nrow(out)), function(i) row(out[i]), character(1)), "\\bottomrule", "\\end{tabular}")
dir.create("paper/tables", showWarnings = FALSE, recursive = TRUE); writeLines(tex, "paper/tables/controls.tex")
g <- function(smp, est, col) out[sample == smp & estimator == est][[col]]
# DiD-averaging estimates missing for computational reasons (Nov 4): size or memory guard, did's 2^31 sparse-matrix limit
# (influence-function matrix of n rows x cells), or an allocation failure; the main sample has none since the Nov 3 server run
d[, csa_fail := is.na(csa) & grepl("csa_skipped_size|csa_skipped_memory|2\\^31|cannot allocate", csa_note)]
d[, csa_cells := !is.na(csa) & grepl("did_cells", csa_note)]   # did's estimator computed cell by cell (estimators.R csa_did_cells, Nov 4)
macc <- c(nCtrlRows = nrow(d), nCtrlPapers = uniqueN(d$suffix), nCtrlPass = sum(d$pass, na.rm = TRUE),
          ctrlCorrBJS = f2(g("all", "bjs", "corr")), ctrlFlipBJS = p1(g("all", "bjs", "flip")), ctrlSigBJS = p1(g("all", "bjs", "sig_flip")), ctrlSeBJS = f2(g("all", "bjs", "se_ratio")),
          ctrlCorrCSA = f2(g("all", "csa", "corr")), ctrlFlipCSA = p1(g("all", "csa", "flip")), ctrlSigCSA = p1(g("all", "csa", "sig_flip")), ctrlSeCSA = f2(g("all", "csa", "se_ratio")),
          ctrlNCSA = g("all", "csa", "n"), ctrlNBJS = g("all", "bjs", "n"), ctrlPapersCSA = g("all", "csa", "papers"), ctrlPapersBJS = g("all", "bjs", "papers"),
          ctrlCSAignored = sum(!d$csa_uses_controls & !is.na(d$csa)), ctrlCSAany = sum(!is.na(d$csa)),
          ctrlCSAskipSize = d[csa_fail == TRUE, .N], ctrlCSAskipPapers = uniqueN(d[csa_fail == TRUE, suffix]),
          ctrlCSAcells = d[csa_cells == TRUE & pass_csa %in% TRUE, .N], ctrlCSAcellsPapers = uniqueN(d[csa_cells == TRUE & pass_csa %in% TRUE, suffix]),
          # comparisons that pass the TWFE screen but fail the modern estimator's own leverage screen (DiD-averaging leverage with covariates since Nov 4)
          ctrlCSAlevFail = d[pass %in% TRUE & !is.na(csa) & !is.na(twfe) & pass_csa %in% FALSE, .N], ctrlCSAlevFailPapers = uniqueN(d[pass %in% TRUE & !is.na(csa) & !is.na(twfe) & pass_csa %in% FALSE, suffix]),
          ctrlBJSlevFail = d[pass %in% TRUE & !is.na(bjs) & !is.na(twfe) & pass_bjs %in% FALSE, .N])
writeLines(sprintf("\\newcommand{\\%s}{%s}", names(macc), macc), "paper/tables/controls_numbers.tex")
cat("controls table and macros written to paper/tables/\n")
