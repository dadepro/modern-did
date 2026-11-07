# Run the TWFE / CSA / BJS comparison for one specification described in a JSON file.
# Spec JSON fields (written by the replication step):
#   suffix, spec_id, data_path (dta/csv/rds/parquet), id_var, time_var, y_var,
#   treat_var   : 0/1 treatment indicator (absorbing after first switch), OR
#   gvar        : first-treatment period variable (NA/0/Inf = never),
#   weight_var (optional), cluster_var (optional), xt_vars (optional, time-invariant
#   covariates interacted with time FE), sample_filter (optional R expression on the data),
#   log_y (optional: apply log(1+y) or log(y)), published_coef, published_se
# Optional fields added Nov 2 (absent = previous behaviour; PROTOCOL Nov 2 rulings (a)-(c)):
#   event_structure    : the authors' bins and reference (code/R/event_structure.R); event specs without it use es_legacy()
#   adoption_var       : column with the true first-treatment calendar date (units of time_var; NA/0 = none); overrides the
#                        date from gvar or treat_var for treated units, only across periods without rows of the unit (e.g.
#                        pre-sample adopters, units entering the panel already treated), so D and static estimates are unchanged
#   drop_e_above: k    : drop rows of treated units with rel > k for all estimators (= did's aggte max_e = k for CSA)
#   balance_e: k       : CSA uses did's aggte balance_e = k on the full sample; TWFE and imputation drop the post-adoption
#                        rows of cohorts with g + k > last period (their pre-adoption rows stay as controls)
#   csa_cells          : "pairs" = cells with units observed in both g-1 and t (Stata csdid with ivar on an unbalanced panel);
#                        "rc_csdid" = repeated cross-section cells (csdid without ivar); both weight cells by csdid's cell counts
#   csa_control_group  : "nevertreated" (csdid's default) or "notyettreated" (default)
#   csa_aggregation    : "calendar" = did's aggte(type = "calendar") for static specs; default "simple"
#   csa_weights        : "did" = did's own aggregation weights (authors who report R did / staggered); default "hull" = Hull's
#                        treated-count weights (equal in balanced panels)
# CSA_STRICT_HULL=1 (environment, the PI's option A): ignore csa_cells, csa_control_group, csa_aggregation and csa_weights and
#   use Hull's estimator; the design fields (event_structure, event_time_authors_var, drop_e_above, balance_e, sample_filter,
#   adoption_var, gvar) stay in force. TWFE and imputation do not depend on these fields.
#   event_time_authors_var : column with the authors' own event-time index; TWFE and imputation assign rows to the
#                        event_structure bins by it (calendar rel where NA); DiD-averaging keeps calendar rel = t - g
# Output goes to $OUT_DIR/specs[_controls]/ (OUT_DIR defaults to output; set it for tests).
# Usage: Rscript code/R/run_spec.R path/to/spec.json [B]
suppressPackageStartupMessages({ library(data.table); library(jsonlite); library(haven) })
args <- commandArgs(trailingOnly = TRUE)
spec <- fromJSON(args[1]); B <- if (length(args) > 1) as.integer(args[2]) else 0
# data paths are recorded as on the machine where the packages were extracted (~/did_packages); DID_PKG_ROOT points them at a mirror
if (nzchar(Sys.getenv("DID_PKG_ROOT"))) spec$data_path <- sub("^~/did_packages", Sys.getenv("DID_PKG_ROOT"), spec$data_path)
spec$data_path <- path.expand(spec$data_path)
# CSA_CELLS_CHECK=1 (Nov 4): validation harness of the cell-by-cell did replica (estimators.R csa_did_cells). For a static spec it
#   computes the replica's CSA (forced, guards ignored, composition-fixed robustness skipped), reads the spec's stored output
#   ($OUT_DIR/specs[_controls]/<suffix>__<spec_id>.csv: csa, csa_se, csa_note from did) and appends one line (suffix, spec_id, did
#   and replica estimates and SEs, absolute differences, seconds, both notes) to $OUT_DIR/csa_cells_check.csv; nothing else is
#   written. Event studies are skipped. Unset = unchanged behaviour.
# CSA_LEV_PATCH=1 (Nov 4): patch the DiD-averaging leverage with covariates (estimators.R csa_did_cells_lev, which csa_leverage
#   did not compute before Nov 4) into an existing output. Computes only that leverage for the spec's stored estimate (static or
#   event study; the stored csa must equal sum(a * y) and, for static specs, the cell replica's estimate to 1e-8 relative, else
#   nothing is written), copies the CSV to $OUT_DIR/backup_levpatch/, writes G_eff_csa, L_max_csa, lev_check_csa and drops the
#   lev_csa_na_controls / lev_csa_na_covariates token from lev_note, and appends one line (estimate, check, leverage, pass of the
#   DiD-averaging screen alone, status) to $OUT_DIR/csa_lev_patch.csv. Specs without a DiD-averaging estimate are logged and
#   left untouched. Unset = unchanged behaviour.
# CSA_GUARDS_OFF=1 (Nov 3, decision: "avoid skipping results for computational issues"): no size or memory guard, so the did
# package runs on every specification (server runs); the per-spec guard fields below are ignored. Unset = unchanged behaviour.
if (Sys.getenv("CSA_GUARDS_OFF") == "1") {
  Sys.setenv(CSA_MAX_IF = "1e18", CSA_MAX_CELLS = "1e12", CSA_MAX_OBS = "1e15")
} else {
  # per-spec override of the CSA memory guard (estimators.R CSA_MAX_IF), set only for specs measured to fit under memguard's cap
  if (!is.null(spec$csa_max_if)) Sys.setenv(CSA_MAX_IF = format(as.numeric(spec$csa_max_if), scientific = TRUE))
  # per-spec relaxed CSA size guard (the overnight relaxed-guard queue; recorded in the spec so re-runs reproduce it)
  if (!is.null(spec$csa_max_cells)) Sys.setenv(CSA_MAX_CELLS = format(as.numeric(spec$csa_max_cells), scientific = FALSE))
  if (!is.null(spec$csa_max_obs)) Sys.setenv(CSA_MAX_OBS = format(as.numeric(spec$csa_max_obs), scientific = TRUE))
}
source(file.path("code/R/estimators.R"))
OUT_DIR <- Sys.getenv("OUT_DIR", "output")
# per-spec estimator options (Nov 2): see the header; opt is passed to compare_spec / compare_spec_event
# (exact [[ ]] lookups: spec$x would partially match e.g. a documentation field "adoption_var_note")
sp <- function(k) spec[[k, exact = TRUE]]
opt <- list(balance_e = if (!is.null(sp("balance_e"))) as.integer(sp("balance_e")) else NULL, cells = sp("csa_cells") %||% "",
            control = sp("csa_control_group") %||% "notyettreated", agg = sp("csa_aggregation") %||% "simple")
opt$weights <- sp("csa_weights") %||% "hull"
if (!opt$weights %in% c("hull", "did")) stop("csa_weights must be \"hull\" or \"did\" (or absent)")
CSA_STRICT <- Sys.getenv("CSA_STRICT_HULL") == "1"
if (CSA_STRICT) opt[c("cells", "control", "agg", "weights")] <- list("", "notyettreated", "simple", "hull")
opt$pairs <- identical(opt$cells, "pairs")
if (!opt$cells %in% c("", "pairs", "rc_csdid")) stop("csa_cells must be \"pairs\" or \"rc_csdid\" (or absent)")
if (!opt$agg %in% c("simple", "calendar")) stop("csa_aggregation must be \"simple\" or \"calendar\" (or absent)")
etv <- if (!is.null(sp("event_time_authors_var")) && nzchar(sp("event_time_authors_var"))) sp("event_time_authors_var") else NULL
if (!opt$control %in% c("notyettreated", "nevertreated")) stop("csa_control_group must be notyettreated or nevertreated")
drop_e_above <- if (!is.null(sp("drop_e_above"))) as.integer(sp("drop_e_above")) else NULL
adoption_var <- if (!is.null(sp("adoption_var")) && nzchar(sp("adoption_var"))) sp("adoption_var") else NULL

read_any <- function(p) {
  ext <- tolower(tools::file_ext(p))
  d <- switch(ext,
    dta = as.data.table(haven::zap_labels(haven::read_dta(p))),
    csv = fread(p), tsv = fread(p), txt = fread(p),
    rds = as.data.table(readRDS(p)),
    rdata = { e <- new.env(); load(p, envir = e); as.data.table(get(ls(e)[1], envir = e)) },
    rda = { e <- new.env(); load(p, envir = e); as.data.table(get(ls(e)[1], envir = e)) },
    parquet = as.data.table(arrow::read_parquet(p)),
    stop("unsupported data format: ", ext))
  d
}
d <- read_any(spec$data_path)
if (!is.null(spec$sample_filter) && nzchar(spec$sample_filter)) d <- d[eval(parse(text = spec$sample_filter))]
# weights, clusters and covariates are resolved on the original names before renaming
d[, w := if (!is.null(spec$weight_var) && nzchar(spec$weight_var)) get(spec$weight_var) else 1]
d[, cl := if (!is.null(spec$cluster_var) && nzchar(spec$cluster_var)) get(spec$cluster_var) else get(spec$id_var)]
xt <- if (!is.null(spec$xt_vars) && length(spec$xt_vars) && nzchar(spec$xt_vars[1])) spec$xt_vars else NULL
setnames(d, c(spec$id_var, spec$time_var, spec$y_var), c("id", "t", "y"))
# Adoption dates from a 0/1 treatment indicator are taken on the full panel, BEFORE rows with a missing outcome or weight
# are dropped; otherwise a unit whose outcome is missing in its adoption period is assigned a later cohort, which shifts
# CSA cohorts and event time (found by the controls agent on mnsc.2020.03920, Nov 1 ~18:20). Static TWFE/BJS are unaffected.
use_treat <- is.null(spec$gvar) || !nzchar(spec$gvar)
adopt_note <- ""
if (use_treat) {
  d[, D0 := as.integer(get(spec$treat_var) > 0)]
  gt <- d[!is.na(id) & !is.na(t) & !is.na(D0) & D0 == 1, .(g_cal = min(t)), by = id]
}
# rows that fixest would drop (zero/negative weight, NA cluster, NA xt) are dropped here so residual-based quantities stay
# aligned with d; NA treatment rows are dropped listwise as in Stata (review R2-R4, Nov 1; no current spec affected)
d <- d[!is.na(y) & !is.na(id) & !is.na(t) & !is.na(w) & w > 0 & !is.na(cl)]
if (length(xt)) d <- d[complete.cases(d[, ..xt])]
if (use_treat) d <- d[!is.na(D0)]
# High-cardinality characteristics (Nov 4 evening): a time-invariant characteristic with more than
# XT_MAX_LEVELS categories cannot enter the DiD-averaging estimator (every cohort-by-period cell regression is rank-deficient
# with 260 four-digit industry dummies, checked on mnsc.2020.01838), so it is dropped from ALL estimators here, which keeps the
# TWFE / DiD-averaging / imputation comparison like-with-like. Until Nov 4 it was dropped from DiD-averaging only (estimators.R
# expand_xt, note xt_ignored_highcard) while TWFE and imputation kept the authors' industry-by-year effects; in mnsc.2020.01838,
# 6 of the 9 TWFE-vs-DiD-averaging sign reversals came from that asymmetry. 0/1 indicators never count as high-cardinality.
# boot_cov.R evaluates this preamble too, so the bootstrap draws use the same covariate set.
xt_dropped_all <- character(0)
# XT_DROP_ALL=1 (environment) switches the all-estimators drop on; it is OFF by default (PROTOCOL (u), the PI, Nov 4 evening: the
# main analysis has no DiD-averaging estimate for these specifications and TWFE / imputation keep the published regression). The
# XT_DROP_ALL=1 outputs (OUT_DIR=output_xtdrop) feed the like-with-like check in analysis.R.
if (length(xt) && Sys.getenv("XT_DROP_ALL") == "1") {
  nlev <- vapply(xt, function(v) { u <- unique(d[[v]][!is.na(d[[v]])]); if (length(u) <= 2 && all(u %in% c(0, 1))) 0L else length(u) }, integer(1))
  hc <- nlev > XT_MAX_LEVELS
  if (any(hc)) { xt_dropped_all <- sprintf("%s(%d)", xt[hc], nlev[hc]); xt <- xt[!hc]; if (!length(xt)) xt <- NULL
                 message("xt dropped from all estimators (more than ", XT_MAX_LEVELS, " categories): ", paste(xt_dropped_all, collapse = ",")) }
}
if (!is.null(spec$log_y) && isTRUE(spec$log_y == "log1p")) d[, y := log1p(y)]
if (!is.null(spec$log_y) && isTRUE(spec$log_y == "log")) d[, y := log(y)]
# calendar time must be integer-valued and consecutive for the estimators
tt <- sort(unique(d$t)); d[, t := match(t, tt)]
# Adoption dates -> period indices: the first sample period at or after the date.
# Out-of-sample dates (Nov 2, Hull App. B; PROTOCOL Nov 2 (b)): with regularly spaced calendar time they keep their true index
# 1 + (date - first period) / step, below 1 for adopters before the first period (always-treated for CSA and BJS, as before,
# when they were mapped to period 1) and above T for adopters after the last period (D = 0 on all their rows, lead indicators
# in the TWFE event study and BJS lead regression; never-treated for CSA, as did treats g > max t; they used to be coded
# never-treated, g = Inf). Irregular time keeps the old mapping (g_mapping = legacy_irregular_time).
num_t <- is.numeric(tt) || inherits(tt, "Date")   # numeric or Date calendar time; anything else keeps the old comparison
tn <- if (num_t) as.numeric(tt) else NULL; stp <- if (num_t) unique(round(diff(tn), 8)) else NA
regular_t <- num_t && length(tn) >= 2 && length(stp) == 1 && isTRUE(stp > 0)
g_mapping <- if (regular_t) "true_index" else "legacy_irregular_time"
map_g <- function(gc) { if (num_t) gc <- as.numeric(gc)
  vapply(seq_along(gc), function(k) { x <- gc[k]
    if (!is.finite(x)) return(Inf)
    if (regular_t && (x < tn[1] || x > tn[length(tn)])) return(1 + ceiling((x - tn[1]) / stp - 1e-9))
    i <- which((if (num_t) tn else tt) >= x)[1]; if (is.na(i)) Inf else as.numeric(i) }, numeric(1)) }
if (!is.null(spec$gvar) && nzchar(spec$gvar)) {
  d[, g := as.numeric(get(spec$gvar))]; d[is.na(g) | g == 0, g := Inf]
  ug <- unique(d$g); d[, g := map_g(ug)[match(g, ug)]]
} else {
  # map each unit's full-panel adoption date to the first estimation-sample period at or after it
  gt[, g_full := map_g(g_cal)]
  d[, g := Inf]; d[gt, g := i.g_full, on = "id"]
  d[, g_old := if (any(D0 == 1)) as.numeric(min(t[D0 == 1])) else Inf, by = id]   # legacy rule (after the NA filter), audit only
  g_shift_units <- uniqueN(d[pmax(g, 1) != g_old, id]); d[, g_old := NULL]   # pre-sample true dates compared as period 1 (Nov 2)
  if (Sys.getenv("GSHIFT_AUDIT") == "1") { cat(sprintf("GSHIFT %s %s units_shifted=%d units=%d\n", spec$suffix, spec$spec_id, g_shift_units, uniqueN(d$id))); quit(save = "no") }
  # drop post-adoption observations where the original indicator switches back off (Hull fn 6)
  d <- d[!(is.finite(g) & t >= g & D0 == 0)]
}
if (!exists("g_shift_units")) g_shift_units <- NA_integer_
# adoption_var (Nov 2; Hull App. B: "Adoption dates were established from the original treatment-assignment history"): the
# true date replaces the gvar / treat_var date of treated units. It may only move adoption earlier across periods in which
# the unit has no rows, so D (and every static estimate) is unchanged and only event time moves; anything else stops.
# Units never treated by gvar / treat_var take the date only where it changes no observed row (e.g. an adoption after the
# last period, mnsc.2021.02026's Aug 8 group); otherwise they stay never-treated and are counted in adoption_note.
if (!is.null(adoption_var)) {
  av <- d[, .(a_cal = { x <- as.numeric(get(adoption_var)); x <- unique(x[is.finite(x) & x != 0]); if (length(x) > 1) NaN else if (length(x)) x else NA_real_ }), by = id]
  if (any(is.nan(av$a_cal))) stop("adoption_var varies within unit")
  av[, g_av := map_g(a_cal)]; d[av, g_av := i.g_av, on = "id"]
  both <- is.finite(d$g) & is.finite(d$g_av)
  if (any(both & d$g_av > d$g)) stop("adoption_var later than the gvar/treat_var adoption for ", uniqueN(d$id[both & d$g_av > d$g]), " units")
  if (any(both & d$t >= d$g_av & d$t < d$g)) stop("adoption_var would treat ", sum(both & d$t >= d$g_av & d$t < d$g), " observed untreated rows")
  nev <- !is.finite(d$g) & is.finite(d$g_av); nev_bad <- unique(d$id[nev & d$t >= d$g_av]); nev_ok <- nev & !(d$id %in% nev_bad)
  adopt_note <- sprintf("adoption_var:%d_units_earlier;%d_never_treated_dated;%d_never_treated_date_conflict", uniqueN(d$id[both & d$g_av < d$g]),
                        uniqueN(d$id[nev_ok]), length(nev_bad))
  d[both | nev_ok, g := g_av]; d[, g_av := NULL]
}
n_presample <- uniqueN(d[is.finite(g) & g < 1, id])   # adopters before the first sample period (true index <= 0)
n_postsample <- uniqueN(d[is.finite(g) & g > length(tt), id])   # adopters after the last sample period (true index > T)
# drop_e_above = k (Nov 2): rows of treated units more than k periods after adoption leave every estimator; they are never
# controls, so for CSA this equals did's aggte(max_e = k)
if (!is.null(drop_e_above)) d <- d[!(is.finite(g) & t - g > drop_e_above)]
ctrl <- as.character(unlist(spec$controls %||% list())); ctrl <- ctrl[nzchar(ctrl)]   # time-varying controls (secondary analysis only)
if (!is.null(etv)) d[, e_auth := as.numeric(get(etv))]   # authors' event-time index (event_time_authors_var; event_structure.R)
keep <- c("id", "t", "g", "y", "w", "cl", xt, ctrl, if (!is.null(etv)) "e_auth"); d <- d[, ..keep]
if (length(ctrl)) {   # controls must be numeric (PROTOCOL 5c: categorical controls are pre-expanded to dummies; review R7)
  nn <- ctrl[!vapply(d[, ..ctrl], is.numeric, logical(1))]; if (length(nn)) stop("non-numeric controls (expand to dummies): ", paste(nn, collapse = ", "))
  d[, (ctrl) := lapply(.SD, as.numeric), .SDcols = ctrl]   # doubles: integer columns would truncate the demeaned values
  d <- d[complete.cases(d[, ..ctrl])] }
# Recode unit ids and categorical covariates to integer codes. did2s builds its first-stage FE matrix through
# fixest::sparse_model_matrix, which strips leading zeros from character FE levels ("001001" -> "1001"); with
# zero-padded ids (gvkey, FIPS, zip) the unit-FE columns then fail to match and the BJS SE is corrupted (found on
# mnsc.2020.01838, Nov 1). Integer codes are safe for every estimator used here; cl is left as is.
id_leading_zero <- is.character(d$id) && any(grepl("^0[0-9]", d$id))
d[, id := as.integer(factor(id))]
# categorical xt -> "x<k>" labels: no leading zeros for did2s, but still character (integer codes made did2s's SVD fail on
# mnsc.2023.00900 T5_c2, Nov 1 ~19:45); numeric xt are left as is
if (length(xt)) d[, (xt) := lapply(.SD, function(v) if (is.character(v) || is.factor(v)) paste0("x", as.integer(factor(v))) else v), .SDcols = xt]
y_sd_w <- sqrt(sum(d$w * (d$y - sum(d$w * d$y) / sum(d$w))^2) / sum(d$w))  # weighted SD of the estimation sample (after drops/transforms)
is_event <- !is.null(spec$static_or_event) && grepl("event", spec$static_or_event)
es_spec <- if (is_event && !is.null(sp("event_structure"))) es_parse(sp("event_structure")) else NULL   # Nov 2; NULL = es_legacy()
if (Sys.getenv("LEVERAGE_ONLY") == "1") {  # patch G_eff/L_max into an existing event-spec output without re-estimating
  outf <- file.path(OUT_DIR, "specs", paste0(spec$suffix, "__", spec$spec_id, ".csv"))
  stopifnot(is_event, file.exists(outf)); if (length(ctrl)) stop("LEVERAGE_ONLY is not implemented for controls specs (review R6)")
  pre_min <- as.integer(spec$event_pre_min %||% -5L); post_max <- as.integer(spec$event_post_max %||% 5L)
  lev <- twfe_event_leverage(d, xt = xt, pre_min = pre_min, post_max = post_max, es = es_spec, opt = opt)
  old <- fread(outf, colClasses = list(character = c("suffix", "spec_id")))
  old[, `:=`(G_eff = lev$G_eff, L_max = lev$L_max)]
  fwrite(old, outf); cat(sprintf("leverage patched: G_eff=%s L_max=%s %s\n", format(lev$G_eff), format(lev$L_max), lev$err %||% "")); quit(save = "no")
}
if (Sys.getenv("CSA_CELLS_CHECK") == "1") {   # validation of the cell-by-cell did replica against this spec's stored did estimate (Nov 4; header)
  if (is_event) { cat("CSA_CELLS_CHECK: event study, skipped\n"); quit(save = "no") }
  base <- paste0(spec$suffix, "__", spec$spec_id)
  old <- fread(file.path(OUT_DIR, if (length(ctrl)) "specs_controls" else "specs", paste0(base, ".csv")), colClasses = list(character = c("suffix", "spec_id", "csa_note")))
  dc <- prep_panel(copy(d), standardize = FALSE); std_y(dc, reg_rows(dc, opt)); t0 <- proc.time()[["elapsed"]]
  r <- tryCatch(csa_static(dc, xt = xt, control = opt$control, ctrl = if (length(ctrl)) ctrl else NULL, opt = opt, force_cells = TRUE),
                error = function(e) list(est = NA_real_, se = NA_real_, note = paste0("error:", conditionMessage(e))))
  line <- data.table(suffix = spec$suffix, spec_id = spec$spec_id, csa_did = as.numeric(old$csa[1]), csa_se_did = as.numeric(old$csa_se[1]), csa_cells = r$est, csa_se_cells = r$se,
                     d_est = abs(r$est - as.numeric(old$csa[1])), d_se = abs(r$se - as.numeric(old$csa_se[1])), seconds = round(proc.time()[["elapsed"]] - t0, 1),
                     note_did = old$csa_note[1], note_cells = r$note)
  ck <- file.path(OUT_DIR, "csa_cells_check.csv"); fwrite(line, ck, append = file.exists(ck)); print(line); quit(save = "no")
}
if (Sys.getenv("CSA_LEV_PATCH") == "1") {   # DiD-averaging leverage with covariates patched into the stored output (Nov 4; header)
  base <- paste0(spec$suffix, "__", spec$spec_id); outf <- file.path(OUT_DIR, if (length(ctrl)) "specs_controls" else "specs", paste0(base, ".csv"))
  chr <- intersect(c("suffix", "spec_id", "csa_note", "bjs_note", "lev_note", "window"), names(fread(outf, nrows = 0)))
  old <- fread(outf, colClasses = list(character = chr)); csa0 <- as.numeric(old$csa[1]); est <- NA_real_
  rec <- function(status, lev = list()) {
    line <- data.table(suffix = spec$suffix, spec_id = spec$spec_id, window = old$window[1] %||% NA_character_, csa = csa0, est_cells = est, check = lev$check %||% NA_real_,
                       G_eff_csa = lev$G_eff %||% NA_real_, L_max_csa = lev$L_max %||% NA_real_, status = status)
    line[, pass_csa_screen := is.finite(G_eff_csa) & is.finite(L_max_csa) & G_eff_csa >= 10 & L_max_csa <= 0.25]
    lg <- file.path(OUT_DIR, "csa_lev_patch.csv"); fwrite(line, lg, append = file.exists(lg)); print(line); quit(save = "no")
  }
  if (!isTRUE(is.finite(csa0))) rec("no_csa_estimate")
  if (is_event) { S <- es_parse(es_spec %||% es_legacy(as.integer(spec$event_pre_min %||% -5L), as.integer(spec$event_post_max %||% 5L)))
    dc <- es_assign(prep_panel(copy(d), standardize = FALSE), S)$d; plan <- S }
  else { dc <- prep_panel(copy(d), standardize = FALSE); plan <- if (identical(opt$agg, "calendar")) "calendar" else NULL }
  std_y(dc, reg_rows(dc, opt)); ctl <- if (length(ctrl)) ctrl else NULL; tol <- 1e-8 * max(1, abs(csa0))
  lev <- tryCatch(csa_leverage(dc, xt, ctl, plan, opt), error = function(e) list(note = paste0("lev_csa_error:", substr(conditionMessage(e), 1, 60))))
  if (is.null(lev)) rec("lev_csa_no_cells"); if (!is.null(lev$note)) rec(lev$note, lev)
  if (!is_event) { est <- tryCatch(csa_static(dc, xt = xt, control = opt$control, ctrl = ctl, opt = opt, force_cells = TRUE)$est, error = function(e) NA_real_)
    if (!isTRUE(abs(est - csa0) <= tol)) rec("estimate_mismatch", lev) }
  if (!isTRUE(abs(lev$check - csa0) <= tol)) rec("check_mismatch", lev)
  bak <- file.path(OUT_DIR, "backup_levpatch"); dir.create(bak, recursive = TRUE, showWarnings = FALSE); file.copy(outf, file.path(bak, basename(outf)), overwrite = FALSE)
  for (v in c("G_eff_csa", "L_max_csa", "lev_check_csa")) if (v %in% names(old)) set(old, j = v, value = as.numeric(old[[v]]))   # all-NA columns are read as logical; := would coerce the leverage to TRUE
  old[, `:=`(G_eff_csa = lev$G_eff, L_max_csa = lev$L_max, lev_check_csa = lev$check - csa0)]
  if ("lev_note" %in% names(old)) old[, lev_note := gsub("^;+|;+$", "", gsub(";{2,}", ";", gsub("lev_csa_na_controls|lev_csa_na_covariates", "", lev_note)))]
  fwrite(old, outf); rec("patched", lev)
}
if (is_event) {
  pre_min <- as.integer(spec$event_pre_min %||% -5L); post_max <- as.integer(spec$event_post_max %||% 5L)
  res <- compare_spec_event(d, xt = xt, pre_min = pre_min, post_max = post_max, ctrl = if (length(ctrl)) ctrl else NULL, es = es_spec, opt = opt)
  res[, `:=`(event_pre_min = pre_min, event_post_max = post_max)]
} else {
  res <- compare_spec(d, xt = xt, B = B, ctrl = if (length(ctrl)) ctrl else NULL, opt = opt)
  res[, window := "static"]
}
y_sd_w <- attr(res, "y_sd") %||% y_sd_w   # the estimators standardize on the TWFE sample (differs from d only under balance_e)
res[!is.na(csa) & is.na(csa_se), csa_note := paste0(csa_note, if (nzchar(csa_note)) ";" else "", "csa_se_na")]   # e.g. clusters = cells (mnsc.2023.4816)
# high-cardinality characteristics dropped from all estimators (Nov 4, see the preamble): recorded in csa_note (analysis.R counts
# these comparisons and reports the results without them) and in their own column
res[, xt_dropped_all_highcard := paste(xt_dropped_all, collapse = ",")]
if (length(xt_dropped_all)) res[, csa_note := paste0(csa_note, fifelse(nzchar(csa_note), ";", ""), "xt_dropped_all_highcard:", paste(xt_dropped_all, collapse = ","))]   # res has two rows for event studies
res[, id_recoded_from_leading_zero := id_leading_zero]
res[, g_shift_units := g_shift_units]   # units whose cohort moved under the full-panel adoption rule (0 = unaffected)
# Nov 2: adoption-date mapping and per-spec options in force
res[, `:=`(g_mapping = g_mapping, n_presample_adopters = n_presample, n_postsample_adopters = n_postsample, adoption_note = adopt_note,
           opt_drop_e_above = drop_e_above %||% NA_integer_, opt_balance_e = opt$balance_e %||% NA_integer_,
           opt_csa_cells = opt$cells, opt_csa_control = opt$control, opt_csa_aggregation = opt$agg, opt_csa_weights = opt$weights,
           csa_strict_hull = CSA_STRICT, event_time_authors_var = etv %||% "")]
if (is_event && opt$agg != "simple") res[, csa_note := paste0(csa_note, ";csa_aggregation_ignored_event")]   # calendar is a static aggregation
res[, `:=`(controls = paste(ctrl, collapse = ";"), analysis_set = if (length(ctrl)) "controls" else "main")]
res[, `:=`(suffix = spec$suffix, spec_id = spec$spec_id, published_coef = spec$published_coef %||% NA_real_,
           published_se = spec$published_se %||% NA_real_,
           y_sd_regsample = y_sd_w)]
res[, `:=`(csa_max_cells = CSA_MAX_CELLS, csa_max_obs = CSA_MAX_OBS, csa_max_if = CSA_MAX_IF, xt_max_levels = XT_MAX_LEVELS, fixef_tol = FIXEF_TOL)]   # guards and fixest tolerance in force
out <- file.path(OUT_DIR, if (length(ctrl)) "specs_controls" else "specs"); dir.create(out, recursive = TRUE, showWarnings = FALSE)
fwrite(res, file.path(out, paste0(spec$suffix, "__", spec$spec_id, ".csv")))
print(res)
