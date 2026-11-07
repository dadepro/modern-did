# Appendix tables: (1) synthetic/disguised package data: the comparison table is still written by analysis.R but no longer
#                      appears in the paper (appendix removed Nov 6, 2026; its rows are read here only to exclude them),
#                  (2) list of papers in the replication sample (original data only since Nov 6).
# Run from the project root:  Rscript code/R/appendix.R
# Inputs : output/specs_synthetic.csv (written by code/R/analysis.R), output/specs/*.csv,
#          data/specs/*.json, data/synthetic_packages.txt, data/candidates/candidates.csv,
#          data/screening/by_paper/*.json
# Outputs: paper/tables/synthetic_comparison.tex, paper/tables/paper_list.tex
suppressPackageStartupMessages({ library(data.table); library(jsonlite) })
dir.create("paper/tables", showWarnings = FALSE, recursive = TRUE)
fmt <- function(x, d = 3) ifelse(is.na(x), "--", formatC(x, digits = d, format = "f"))
texesc <- function(s) gsub("([_&%$#])", "\\\\\\1", s)
SYNTH_PAT <- "synth|disguis|pseudo|simulat|scrambl|fuzz"

# ---- (1) Synthetic package data -----------------------------------------------------------------------
# The comparison table (paper/tables/synthetic_comparison.tex) is written by analysis.R with the main sample rules (code review
# #3, Nov 3); this script only reads the synthetic rows for the paper list below.
syn <- fread("output/specs_synthetic.csv", colClasses = list(character = c("suffix", "spec_id")))
syn[, paper := as.character(suffix)]

# ---- (2) Papers in the replication sample ------------------------------------------------
spec_files <- list.files("output/specs", full.names = TRUE, pattern = "csv$")
specs <- rbindlist(lapply(spec_files, function(f) fread(f, colClasses = list(character = c("suffix", "spec_id")))[, .(suffix, spec_id, window)]), fill = TRUE)
rows <- unique(rbind(specs[, src := "specs"], syn[, .(suffix, spec_id, window, src = "synthetic_csv")]), by = c("suffix", "spec_id", "window"))
# Provenance, using the same rules as analysis.R: spec-level data_provenance, the synthetic-package list,
# and membership in output/specs_synthetic.csv.
meta <- rbindlist(lapply(list.files("data/specs", full.names = TRUE, pattern = "json$"), function(f) {
  j <- tryCatch(fromJSON(f), error = function(e) NULL); if (is.null(j) || is.null(j$suffix)) return(NULL)
  data.table(suffix = as.character(j$suffix), spec_id = as.character(j$spec_id), provenance = as.character(j$data_provenance %||% NA)) }), fill = TRUE)
synth_list <- if (file.exists("data/synthetic_packages.txt")) trimws(readLines("data/synthetic_packages.txt")) else character(0)
rows <- merge(rows, unique(meta, by = c("suffix", "spec_id")), by = c("suffix", "spec_id"), all.x = TRUE)
# only specifications with a current spec JSON (as in analysis.R): output files of excluded specs (data/specs_excluded/) are
# ignored, so a paper whose specifications were all excluded (mnsc.2022.03905, Nov 2 audit) is not listed (fixed Nov 3)
rows <- rows[src == "synthetic_csv" | paste(suffix, spec_id) %in% meta[, paste(suffix, spec_id)]]
rows[, synthetic := (!is.na(provenance) & grepl(SYNTH_PAT, provenance, ignore.case = TRUE)) | suffix %in% synth_list | suffix %in% syn$suffix]
rows <- rows[synthetic == FALSE]   # Nov 6 (decision): the synthetic-data appendix is removed, so the list covers papers re-estimated on original data
cand <- fread("data/candidates/candidates.csv", colClasses = list(character = "doi"))[, .(doi, journal, year)]
if (file.exists("data/candidates/crossref_years.csv")) {   # journal issue year from Crossref (as in analysis.R, Nov 3)
  cy <- fread("data/candidates/crossref_years.csv", colClasses = list(character = "doi"))[, .(doi, cyear = fcoalesce(as.integer(print_year), as.integer(issued_year)))]
  cand <- merge(cand, cy, by = "doi", all.x = TRUE); cand[!is.na(cyear), year := cyear]; cand[, cyear := NULL]
}
cand[, suffix := sub("^[^/]*/", "", doi)]
dup <- cand[duplicated(suffix), unique(suffix)]
if (length(dup)) cat(sprintf("Warning: %d duplicated suffixes in candidates.csv; first record kept\n", length(dup)))
cand <- unique(cand, by = "suffix")
MODERN_PAT <- "csdid|att_gt|callaway|sant|imputation|borusyak|did2s|sunab|eventstudyinteract|abraham|did_multiplegt|chaisemartin"
modern_flag <- function(s) {
  f <- file.path("data/screening/by_paper", paste0(s, ".json"))
  if (!file.exists(f)) return(NA)
  j <- tryCatch(fromJSON(f), error = function(e) NULL); if (is.null(j)) return(NA)
  any(grepl(MODERN_PAT, unlist(j$estimators_reported), ignore.case = TRUE))
}
pl <- rows[, .(n_specs = sum(window != "pre"), n_synth = sum(synthetic & window != "pre"), n_rows = .N, any_synth = any(synthetic), all_synth = all(synthetic)), by = suffix]
pl <- merge(pl, cand[, .(suffix, journal, year)], by = "suffix", all.x = TRUE)
pl[, modern := vapply(suffix, modern_flag, logical(1))]
pl[, data := fifelse(all_synth, "Synthetic", fifelse(any_synth, "Mixed", "Original"))]
jorder <- c(mksc = 1L, mnsc = 2L, jmr = 3L)
pl[, jlab := fifelse(journal == "mnsc", "MS", fifelse(journal == "mksc", "MKSC", fifelse(journal == "jmr", "JMR", toupper(journal))))]
setorder(pl, year, suffix)
pl[, ord := jorder[journal]]; setorder(pl, ord, year, suffix, na.last = TRUE)
miss_cand <- pl[is.na(journal) | is.na(year), suffix]
miss_scr <- pl[is.na(modern), suffix]
cat(sprintf("Paper list: %d papers (%d original, %d synthetic, %d mixed); %d specifications (window != pre)\n",
            nrow(pl), pl[data == "Original", .N], pl[data == "Synthetic", .N], pl[data == "Mixed", .N], sum(pl$n_specs)))
if (length(miss_cand)) cat("Warning: no candidates.csv match (journal/year missing) for:", paste(miss_cand, collapse = ", "), "\n")
if (length(miss_scr)) cat("Warning: no screening record for:", paste(miss_scr, collapse = ", "), "\n")
if (pl[n_specs == 0, .N]) cat("Note: papers with pre-window rows only:", paste(pl[n_specs == 0, suffix], collapse = ", "), "\n")
yn <- function(x) fifelse(is.na(x), "--", fifelse(x, "Yes", "No"))
body <- pl[, sprintf("%d & \\texttt{%s} & %s & %s & %d & %s \\\\", seq_len(.N), texesc(suffix), fifelse(is.na(jlab), "--", jlab),
                     fifelse(is.na(year), "--", as.character(year)), n_specs, yn(modern))]
head_row <- c(" & & & & & Reports \\\\", " & Paper (DOI suffix) & Journal & Year & Specifications & modern DiD \\\\")   # leading index column (decision, Nov 6)
notes <- paste0("{\\footnotesize\\noindent Notes: One row per paper with at least one re-estimated specification on original data, ",
  "including random subsamples and linear rescalings of the original data made by the authors; papers whose packages contain synthetic, disguised, pseudo or simulated data are not re-estimated. ",
  "Specifications count static estimates and event-study post-window averages (pre-window averages excluded), before the leverage screen. ",
  "``Reports modern DiD'' is based on the estimators listed in the screening record (Callaway--Sant'Anna, Sun--Abraham, Borusyak--Jaravel--Spiess, Gardner, or de Chaisemartin--D'Haultf\\oe{}uille). ",
  if (pl[journal == "jmr", .N]) "MS = \\emph{Management Science}; MKSC = \\emph{Marketing Science}; JMR = \\emph{Journal of Marketing Research}.\\par}"
  else "MS = \\emph{Management Science}; MKSC = \\emph{Marketing Science}.\\par}")   # JMR only when a JMR paper is listed (decision, Nov 6)
# Use a longtable when the list does not fit on one page (about 35 rows at \small, single spacing).
if (nrow(pl) > 35) {
  tex <- c("\\begingroup\\scriptsize\\setstretch{1}\\renewcommand{\\arraystretch}{0.95}",   # fits the 40 rows and the notes on one page (decision, Nov 6)
           "\\setlength{\\LTcapwidth}{\\textwidth}",
    "\\begin{longtable}{rlcccc}",
    "\\caption{Papers in the replication sample}\\label{tab:paperlist}\\\\", "\\toprule", head_row, "\\midrule", "\\endfirsthead",
    "\\multicolumn{6}{l}{\\emph{Table \\thetable, continued}} \\\\", "\\toprule", head_row, "\\midrule", "\\endhead",
    "\\midrule", "\\multicolumn{6}{r}{\\emph{Continued on next page}} \\\\", "\\endfoot",
    "\\bottomrule", "\\endlastfoot",
    body, "\\end{longtable}", "\\vspace{-0.5\\baselineskip}", notes, "\\endgroup")
} else {
  tex <- c("\\begin{table}[htbp]\\centering", "\\caption{Papers in the replication sample}\\label{tab:paperlist}",
    "\\small", "\\begin{tabular}{rlcccc}", "\\toprule", head_row, "\\midrule", body, "\\bottomrule", "\\end{tabular}", "\\par\\smallskip", notes, "\\end{table}")
}
writeLines(tex, "paper/tables/paper_list.tex")
fwrite(pl[, .(suffix, journal, year, n_specs, n_synth, data, reports_modern = modern)], "output/tables/paper_list.csv")

# ---- (3) Papers that publish a Callaway-Sant'Anna estimate: reproduction, and Hull's settings (Nov 3) ---------------------
# For these specifications the main analysis estimates DiD-averaging with the authors' settings (option B, output/specs);
# output_hullA/specs holds the same specifications with Hull's settings (option A, CSA_STRICT_HULL=1). Published values are
# in raw outcome units (published_coef in the spec JSON: the static estimate or the event-study post-window average); our
# estimates are stored in regression-sample SD units, so the raw estimate is csa * y_sd_regsample. A published value counts
# as reproduced when the difference is within half a unit of its last printed decimal (relative 1e-6 for values copied
# from the authors' log at full precision).
read_dir <- function(dir) { fs <- list.files(dir, full.names = TRUE, pattern = "csv$"); if (!length(fs)) return(NULL)
  rbindlist(lapply(fs, function(f) fread(f, colClasses = list(character = c("suffix", "spec_id")))), fill = TRUE) }
hA <- read_dir("output_hullA/specs")
if (!is.null(hA)) {
  ids <- unique(hA[, .(suffix, spec_id)])
  pj <- rbindlist(lapply(seq_len(nrow(ids)), function(i) {
    j <- fromJSON(file.path("data/specs", paste0(ids$suffix[i], "__", ids$spec_id[i], ".json")))
    # where the protocol's switch-off rule changes the sample (mnsc.2022.03186 Table 4, Nov 4), the reference is the authors' estimator
    # re-run on that sample (authors_rerun_csdid_dropoff_*); the printed estimate is reproduced by their code on the full sample
    data.table(suffix = ids$suffix[i], spec_id = ids$spec_id[i], pub = as.numeric(j$authors_rerun_csdid_dropoff_coef %||% j$published_coef %||% NA),
               pub_se = as.numeric(j$authors_rerun_csdid_dropoff_se %||% j$published_se %||% NA), rerun_ref = !is.null(j$authors_rerun_csdid_dropoff_coef),
               sw = if (grepl("csdid", as.character(j$published_estimator %||% ""))) "Stata \\texttt{csdid}" else "R \\texttt{did} or \\texttt{staggered}") }))
  B <- rbindlist(lapply(seq_len(nrow(ids)), function(i) fread(file.path("output/specs", paste0(ids$suffix[i], "__", ids$spec_id[i], ".csv")),
                                                              colClasses = list(character = c("suffix", "spec_id")))), fill = TRUE)
  x <- merge(B[, .(suffix, spec_id, window, csaB = csa, seB = csa_se, ysd = y_sd_regsample)], hA[, .(suffix, spec_id, window, csaA = csa, seA = csa_se)], by = c("suffix", "spec_id", "window"))
  x <- merge(x[window != "pre"], pj, by = c("suffix", "spec_id"))
  ndec <- function(v) nchar(sub("^[^.]*\\.?", "", sub("0+$", "", formatC(abs(v), digits = 12, format = "f"))))
  x[, ours := csaB * ysd][, gAB := abs(csaA - csaB) / seA]   # in units of the main (Hull's settings) SE (Nov 3)
  x[!is.na(pub), `:=`(repro = abs(ours - pub) <= pmax(0.5 * 10^(-ndec(pub)), 1e-6 * abs(pub)) + 1e-12, dpub = abs(ours - pub) / pub_se)]
  pt <- x[, .(specs = .N, with_pub = sum(!is.na(pub)), repro = sum(repro %in% TRUE), dmax = suppressWarnings(max(dpub[is.finite(dpub)])),
              gmed = median(gAB, na.rm = TRUE), gmax = max(gAB, na.rm = TRUE), flips = sum(sign(csaA) != sign(csaB), na.rm = TRUE), papers = uniqueN(suffix)), by = sw]   # by the authors' software; no paper is named (decision, Nov 3)
  pt[!is.finite(dmax), dmax := NA_real_]; setorder(pt, -specs)
  cat(sprintf("Published-CS table: %d papers, %d specifications, %d with a published value, %d reproduced\n", uniqueN(x$suffix), sum(pt$specs), sum(pt$with_pub), sum(pt$repro)))
  print(x[!is.na(pub) & !(repro %in% TRUE), .(suffix, spec_id, pub, ours = signif(ours, 6), dpub = round(dpub, 2))])
  body <- pt[, sprintf("%s & %d & %d & %d & %d & %s & %s & %s & %d \\\\", sw, papers, specs, with_pub, repro, fmt(dmax, 2), fmt(gmed, 2), fmt(gmax, 1), flips)]
  tex <- c("\\begin{table}[htbp]\\centering", "\\caption{DiD-averaging estimates of papers that publish a Callaway--Sant'Anna estimate}\\label{tab:pubcs}",
    "\\footnotesize", "\\setlength{\\tabcolsep}{4pt}", "\\begin{tabular}{lcccccccc}", "\\toprule",
    " & & & \\multicolumn{3}{c}{Authors' settings vs.\\ published} & \\multicolumn{3}{c}{Hull's vs.\\ authors' settings} \\\\",
    "\\cmidrule(lr){4-6}\\cmidrule(lr){7-9}",
    " & & & & & Max & Median & Max & Sign \\\\", "Authors' software & Papers & Specs. & Printed & Matched & gap/SE & gap/SE & gap/SE & changes \\\\", "\\midrule",
    body, "\\midrule",
    sprintf("All & %d & %d & %d & %d & %s & %s & %s & %d \\\\", uniqueN(x$suffix), sum(pt$specs), sum(pt$with_pub), sum(pt$repro), fmt(suppressWarnings(max(x$dpub, na.rm = TRUE)), 2), fmt(median(x$gAB, na.rm = TRUE), 2), fmt(max(x$gAB, na.rm = TRUE), 1), sum(pt$flips)),
    "\\bottomrule", "\\end{tabular}", "\\par\\smallskip",
    "\\begin{minipage}{0.95\\textwidth}",   # justified like the other table notes (decision, Nov 6); a bare paragraph under \centering is ragged
    paste0("{\\footnotesize\\noindent Notes: Papers that publish a Callaway--Sant'Anna estimate, grouped by the software of the published estimate; specifications count static estimates and event-study post-window averages. ",
      "``Printed'' counts specifications with a printed estimate (some event studies are shown only in figures); ``Matched'' counts the specifications for which our estimate under the authors' implementation choices matches the printed estimate to the last printed decimal. ",
      "Gaps to the published estimate are in units of the published standard error. ",
      if (any(pj$rerun_ref)) sprintf("For %d specifications of one paper, the protocol drops post-adoption rows in which the treatment switches off; their reference is the authors' estimator re-run on that sample, since the printed estimate, which their code reproduces on the full sample, is not the target. ", sum(pj$rerun_ref)) else "",
      "The last three columns compare these estimates with our main estimates, which use the settings of \\citet{hull2026}, and report the absolute difference in units of the standard error of the main estimate.\\par}"),
    "\\end{minipage}", "\\end{table}")
  writeLines(tex, "paper/tables/published_cs.tex")
  fwrite(x, "output/tables/published_cs.csv")
  writeLines(sprintf("\\newcommand{\\%s}{%s}", c("nPubCSprinted", "nPubCSrepro"), c(sum(pt$with_pub), sum(pt$repro))), "paper/tables/pubcs_numbers.tex")
}
