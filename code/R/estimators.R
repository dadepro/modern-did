# Core estimators for the meta-analysis (mirrors Hull 2026, Section 3 and Appendix B).
# Input: a data.frame with columns
#   id    : unit (or group) identifier
#   t     : calendar time (integer)
#   g     : first treatment period for the unit (Inf or NA for never treated)
#   y     : outcome
#   w     : analysis weight (optional, default 1)
#   cl    : cluster variable (optional, default id)
#   plus optional time-invariant covariates interacted with time FE (passed as `xt`)
# All estimates are in units of the regression-sample outcome SD when `standardize = TRUE`.
suppressPackageStartupMessages({
  library(data.table); library(fixest); library(did); library(didimputation)
})
# Fixed-effect convergence (Nov 2, team-lead): fixest's default fixef.tol = 1e-6 left TWFE and imputation estimates precise to only
# ~1e-6 to 1e-5 SD (mnsc.2022.4394 T3 imputation post 0.34624258 at the default, 0.34625224 converged), as the leverage-weight
# checks showed. 1e-10, with up to 1e5 iterations for large FE sets (mnsc.2022.01306's 386k factories, mksc.2023.1437,
# mksc.2022.1353); recorded per spec in the output column fixef_tol. did2s's first stage inherits these defaults.
FIXEF_TOL <- as.numeric(Sys.getenv("FIXEF_TOL", "1e-10")); FIXEF_ITER <- as.numeric(Sys.getenv("FIXEF_ITER", "1e5"))
fixest::setFixest_estimation(fixef.rm = "none", fixef.tol = FIXEF_TOL, fixef.iter = FIXEF_ITER)   # keep singletons: aligns residuals with rows; matches reghdfe keepsing N
# did2s computes its first-stage correction with robust_solve_XtX: Matrix::solve, falling back to an SVD pseudo-inverse. LAPACK's
# dgesdd can fail to converge on the near-singular FE cross-product ("error code 1 from Lapack routine 'dgesdd'": mnsc.2023.00900
# T5_c2, Nov 1 ~19:50), which killed the BJS SE. Same function, plus a last fallback: for the symmetric PSD X'X the eigen-
# decomposition gives the identical Moore-Penrose pseudo-inverse. Results are unchanged whenever the original succeeds.
local({
  rs <- function(X, Y) {
    if (is.vector(Y)) XtY <- Matrix::crossprod(X, Y)
    else if (nrow(Y) == nrow(X)) XtY <- Matrix::crossprod(X, Y)
    else if (nrow(Y) == ncol(X)) XtY <- Y
    else stop("Incompatible dimensions between X and Y")
    XtX <- Matrix::crossprod(X)
    tryCatch(Matrix::solve(XtX, XtY), error = function(e) {
      # Sparse step first: zero rows/columns of the symmetric PSD X'X (e.g. FE of units with no untreated rows) decouple
      # exactly, so the pseudo-inverse is the inverse of the remaining block with zeros elsewhere. This avoids did2s's dense
      # fallback, which densified a 108k x 108k matrix on mnsc.2022.02310 (Nov 1 ~20:05).
      nz <- which(Matrix::diag(XtX) > 0)
      if (length(nz) < nrow(XtX)) {
        b <- tryCatch(Matrix::solve(XtX[nz, nz], as.matrix(XtY)[nz, , drop = FALSE]), error = function(e3) NULL)
        if (!is.null(b)) {
          out <- matrix(0, nrow(XtX), ncol(as.matrix(XtY))); out[nz, ] <- as.matrix(b)
          message("did2s robust_solve_XtX: sparse solve after dropping ", nrow(XtX) - length(nz), " zero columns"); return(out)
        }
      }
      if (nrow(XtX) > 20000) stop("did2s_singular_large: X'X (", nrow(XtX), " x ", nrow(XtX), ") is singular beyond zero columns; dense pseudo-inverse infeasible")
      message("did2s robust_solve_XtX: dense pseudo-inverse (", nrow(XtX), " columns)")
      A <- as.matrix(XtX)
      pinv <- tryCatch({
        SVD <- svd(A); tol <- max(dim(A)) * .Machine$double.eps * max(SVD$d)
        SVD$v %*% diag(ifelse(SVD$d > tol, 1 / SVD$d, 0)) %*% t(SVD$u)
      }, error = function(e2) {
        E <- eigen((A + t(A)) / 2, symmetric = TRUE); tol <- max(dim(A)) * .Machine$double.eps * max(abs(E$values))
        E$vectors %*% (ifelse(E$values > tol, 1 / E$values, 0) * t(E$vectors))
      })
      pinv %*% as.matrix(XtY)
    })
  }
  loadNamespace("did2s"); environment(rs) <- asNamespace("did2s")
  utils::assignInNamespace("robust_solve_XtX", rs, ns = "did2s")
})
`%||%` <- function(a, b) if (is.null(a)) b else a
source("code/R/event_structure.R")   # event_structure (es_parse, es_legacy, es_assign; Nov 2); scripts run from the project root

# Expand time-invariant covariates for CSA's xformla. xt enter TWFE/BJS as t^xt, i.e. as CATEGORIES interacted with
# calendar time, so CSA must also treat them as categorical: 0/1 variables as is, other codes as 0/1 dummies (constant
# dummies dropped) when they have <= XT_MAX_LEVELS levels. Above the cap the covariate is dropped from CSA and flagged
# (xt_ignored_highcard), as csa_manual does for all xt. (Review fix Nov 1 ~19:30: numeric codes with > 60 levels, and since
# run_spec's integer recode also character codes, used to enter as ONE linear term, e.g. an integer county code in
# mnsc.2024.04716, which moved CSA by 0.25 SD.) Returns list(data, xf, note).
XT_MAX_LEVELS <- as.numeric(Sys.getenv("XT_MAX_LEVELS", "60"))
expand_xt <- function(dd, xt) {
  if (is.null(xt)) return(list(data = dd, xf = ~1, note = ""))
  cols <- character(0); dropped <- character(0)
  for (v in xt) {
    x <- dd[[v]]; u <- unique(x[!is.na(x)])
    if (length(u) <= 2 && all(u %in% c(0, 1))) { cols <- c(cols, v); next }
    if (length(u) > XT_MAX_LEVELS) { dropped <- c(dropped, sprintf("%s(%d)", v, length(u))); next }
    lv <- sort(u)[-1]
    for (l in lv) { nm <- paste0("xt_", v, "_", make.names(l)); dd[[nm]] <- as.integer(x == l); if (length(unique(dd[[nm]])) > 1) cols <- c(cols, nm) }
  }
  list(data = dd, xf = if (length(cols)) as.formula(paste0("~", paste(cols, collapse = "+"))) else ~1,
       note = if (length(dropped)) paste0("xt_ignored_highcard:", paste(dropped, collapse = ",")) else "")
}

# ---- Secondary analysis: time-varying controls ----------------------------------------
# ctrl = names of time-varying controls (NULL in the main analysis). TWFE and the imputation first
# stage include them as regressors; Callaway-Sant'Anna uses each control fixed at the unit's first
# observed value (ctrlb_*), i.e. a time-invariant covariate, which changes the estimand slightly.
rhs_ctrl <- function(ctrl, none = "1") if (is.null(ctrl) || !length(ctrl)) none else paste(ctrl, collapse = " + ")
plus_ctrl <- function(ctrl) if (is.null(ctrl) || !length(ctrl)) "" else paste0(" + ", paste(ctrl, collapse = " + "))
add_baseline_controls <- function(dd, ctrl) {
  if (is.null(ctrl) || !length(ctrl)) return(list(data = dd, cols = character(0)))
  dd <- copy(dd); setorder(dd, id, t); cols <- character(0)
  for (v in ctrl) { nm <- paste0("ctrlb_", v); dd[, (nm) := { x <- as.numeric(get(v)); b <- x[!is.na(x)][1]; if (is.na(b)) 0 else b }, by = id]; cols <- c(cols, nm) }
  # drop baselines that are constant across units or exactly collinear with the others (plus an intercept): att_gt cannot
  # invert a singular covariate matrix. This leaves the covariate space, and hence any estimate that already worked,
  # unchanged. Found on mnsc.2022.01760 (Nov 2): controls ln_citypop x year dummies are all 0 in the base year 1910.
  keep <- cols
  if (length(cols)) {
    ub <- dd[, lapply(.SD, function(z) z[1]), by = id, .SDcols = cols]
    keep <- cols[vapply(cols, function(cn) isTRUE(stats::sd(ub[[cn]]) > 0), logical(1))]
    if (length(keep)) { q <- qr(cbind(1, as.matrix(ub[, keep, with = FALSE]))); keep <- keep[sort(setdiff(q$pivot[seq_len(q$rank)], 1L) - 1L)] }
  }
  list(data = dd, cols = keep, dropped = setdiff(cols, keep))
}
bdrop_note <- function(bc) if (!is.null(bc) && length(bc$dropped)) paste0(";ctrl_baseline_dropped:", paste(sub("^ctrlb_", "", bc$dropped), collapse = ",")) else ""
demean_by_t <- function(dd, ctrl) {  # RC controls: within-period deviations (mirrors the year FE that absorb common covariate shifts in TWFE)
  if (is.null(ctrl) || !length(ctrl)) return(dd)
  for (v in ctrl) { set(dd, j = v, value = as.numeric(dd[[v]]))   # double first: := by group would truncate into an integer column
    dd[, (v) := { x <- get(v); x - sum(w * x, na.rm = TRUE) / sum(w[!is.na(x)]) }, by = t] }
  dd
}
merge_xf <- function(xf, cols) {
  if (!length(cols)) return(xf)
  old <- attr(terms(xf), "term.labels"); as.formula(paste0("~", paste(c(old, cols), collapse = "+")))
}

prep_panel <- function(d, standardize = TRUE) {
  d <- as.data.table(d)
  if (!"w" %in% names(d)) d[, w := 1]
  if (!"cl" %in% names(d)) d[, cl := id]
  d[is.na(g), g := Inf]
  d[, D := as.integer(is.finite(g) & t >= g)]
  d[, rel := ifelse(is.finite(g), t - g, NA_integer_)]
  if (standardize) { s <- sqrt(Hmisc_wtd_var(d$y, d$w)); d[, y := y / s] }
  d[]
}
Hmisc_wtd_var <- function(x, w) { m <- sum(w * x) / sum(w); sum(w * (x - m)^2) / sum(w) }

# ---- 1. Static TWFE -----------------------------------------------------------
twfe_static <- function(d, xt = NULL, ctrl = NULL) {
  fe <- if (is.null(xt)) "id + t" else paste0("id + t + ", paste0("t^", xt, collapse = " + "))
  m <- feols(as.formula(paste0("y ~ D", plus_ctrl(ctrl), " | ", fe)), data = d, weights = ~w, cluster = ~cl)
  list(est = unname(coef(m)["D"]), se = unname(se(m)["D"]), n = nobs(m), model = m)
}

# ---- 2. Ex post TWFE weights (Borusyak-Hull 2024): psi_j = Dtilde_j * D_j --------
twfe_weights <- function(d, xt = NULL, ctrl = NULL) {
  fe <- if (is.null(xt)) "id + t" else paste0("id + t + ", paste0("t^", xt, collapse = " + "))
  r <- feols(as.formula(paste0("D ~ ", rhs_ctrl(ctrl), " | ", fe)), data = d, weights = ~w)
  Dt <- resid(r)
  psi <- Dt * d$D * d$w
  tr <- d$D == 1
  list(share_neg_rows = mean(psi[tr] < 0),
       share_neg_abs  = -sum(pmin(psi[tr], 0)) / sum(abs(psi[tr])))
}

# ---- 3. Callaway-Sant'Anna DiD-averaging -------------------------------------------
# Size guard: att_gt runs one 2x2 regression per (cohort, period) cell; for very large panels with
# many cohorts this is infeasible in a reasonable time. Such specs return NA for CSA with a note.
CSA_FASTER <- Sys.getenv("CSA_FASTER", "1") == "1"   # did::att_gt(faster_mode); TRUE is already did 2.5.1's default, so this only makes it explicit
CSA_MAX_CELLS <- as.numeric(Sys.getenv("CSA_MAX_CELLS", "4000")); CSA_MAX_OBS <- as.numeric(Sys.getenv("CSA_MAX_OBS", "3e6"))  # env overrides for the overnight relaxed-guard queue
# Memory guard (Nov 1, after two out-of-memory crashes): did::att_gt keeps an influence function of n x (G*T) doubles
# (n = rows for repeated cross-sections, units for panels); with copies the footprint is ~3x that matrix (mksc.2022.1353:
# 193k rows x 3,496 cells = 5.4 GB -> 16 GB). Above CSA_MAX_IF elements CSA returns NA with csa_skipped_memory; TWFE and
# BJS are still computed. csa_manual (unbalanced panels) stores no such matrix and is not affected.
CSA_MAX_IF <- as.numeric(Sys.getenv("CSA_MAX_IF", "4.4e8"))
# Unbalanced panels (Nov 2, decision: follow Hull): did::att_gt(allow_unbalanced_panel = TRUE), i.e. Hull's cohort-average DiD-
# averaging (sample averages of whichever units are observed in each period), as for repeated cross-sections. The composition-
# fixed cells used until Nov 2 (csa_manual) are kept as a robustness estimate (csa_fc*); CSA_UNBALANCED=fixed restores them as main.
CSA_UNBAL <- Sys.getenv("CSA_UNBALANCED", "hull")
# did errors that the cell-by-cell replica (csa_did_cells, Nov 4) takes over: the n x cells influence-function matrix beyond the
# 2^31 sparse limit (mnsc.2022.03920) and the cells x cells covariance of all ATT(g,t) out of memory (mnsc.2025.00954 T6/T8)
CSA_CELLS_RE <- "2\\^31|cannot allocate|TsparseMatrix|vector memory"
csa_short <- function(e) sub("(.{0,60}).*", "\\1", if (is.character(e)) e else conditionMessage(e))
csa_if_guard <- function(d, G, Tn) { n_if <- as.numeric(if (anyDuplicated(d, by = c("id", "t")) > 0 || (CSA_UNBAL == "hull" && is_unbalanced(d))) nrow(d) else uniqueN(d$id)); G <- as.numeric(G); Tn <- as.numeric(Tn); if (n_if * G * Tn > CSA_MAX_IF) sprintf("csa_skipped_memory:n_if=%.0f,G=%.0f,T=%.0f,IF_GB=%.1f", n_if, G, Tn, 8 * n_if * G * Tn / 1e9) else NULL }
# Per-spec CSA options (Nov 2, PROTOCOL Nov 2 (c): where a paper reports Callaway-Sant'Anna, use the authors' settings), passed
# as opt = list(pairs, control, balance_e) from run_spec.R; absent = previous behaviour.
#   control   = "nevertreated" (csa_control_group): never-treated comparison units in every CSA path (csdid's default)
#   pairs     = TRUE (csa_cells = "pairs"): Stata csdid's cells on unbalanced panels, which use only units observed in both g-1
#               and t ("Will use observations with Pair balanced (observed at t0 and t1)"), i.e. csa_manual, as the main CSA
#   balance_e = k: did's aggte(balance_e = k) cell rule for CSA (cohorts observed through e = k, horizons <= k); TWFE and
#               imputation drop the post-adoption rows of the other cohorts (reg_rows)
#   cells     = "rc_csdid" (csa_cells = "rc_csdid"): Stata csdid without ivar, i.e. repeated cross-section cells (cohort and
#               comparison-group means at g-1 and t) on every row, each cell weighted by its cohort rows at g-1 plus at t
#   agg       = "calendar" (csa_aggregation): did's aggte(type = "calendar") for static specs (staggered_cs's calendar estimand)
#   weights   = "hull" (default) | "did" (csa_weights): cell weights in the aggregation. Hull (2026, Section 3): "the w_g,t are
#               convex weights, proportional to the number of treated observations in adoption cohort g and post-treatment period
#               t", event studies "averaged with treated-count weights", analysis weights included (fn. 8): the weighted count of
#               cohort-g observations in cell (g,t), as used in the cell's treated mean (team-lead and the PI, Nov 2). In balanced
#               panels this equals did's cohort share; in unbalanced panels and repeated cross-sections did's aggte uses a fixed
#               cohort share instead. "did" keeps did's own weights, for specs whose authors report did / staggered estimates.
# The pairs and rc_csdid weights are csdid's cell counts (meta-4's check of csdid.ado 1.81: cohort-share weights give -0.4440
# instead of -0.4310009 on mnsc.2022.4660). CSA_STRICT_HULL=1 (run_spec.R) forces Hull's estimator: cohort-average cells,
# not-yet-treated controls, simple aggregation, treated-count weights.
# Weight mode of the cell-sum paths (csa_hull_prep): "cell" (rc_csdid), "hull" (treated counts at t), "cohort" (did's shares;
# also for balanced panels, where both coincide and did's own computation is kept unchanged).
csa_wmode <- function(opt, rc, unbal) {
  if (identical(opt$cells, "rc_csdid")) return("cell")
  if (identical(opt$weights, "did") || (!rc && !unbal)) "cohort" else "hull"
}
# did's data for the covariate paths (csa_static's did fit and cell replica, csa_leverage; factored out Nov 4): gnum (pre-sample
# adopters, true index <= 0, = always-treated), expanded xt, controls. Controls: panels use each unit's first observed value
# (time-invariant covariate); repeated cross-sections pass the observation-level controls to att_gt(panel = FALSE) with
# est_method "dr" (fix flagged on mnsc.2022.03486). The RC outcome-regression estimator assumes a stationary covariate
# distribution and doubled the ATT in a simulation with a trending control (1.01 vs 0.50); the locally efficient DR estimator
# recovered it (0.515). Without controls reg = dr exactly.
csa_did_data <- function(d, xt, ctrl) {
  dd <- copy(d); dd[, gnum := ifelse(is.finite(g), pmax(g, min(t)), 0)]
  ex <- expand_xt(dd, xt); dd <- ex$data; xf <- ex$xf
  rc <- anyDuplicated(dd, by = c("id", "t")) > 0   # repeated cross-section: several rows per unit-period
  bc <- NULL
  if (rc) { dd <- demean_by_t(dd, ctrl); xf <- merge_xf(xf, ctrl %||% character(0)) } else { bc <- add_baseline_controls(dd, ctrl); dd <- bc$data; xf <- merge_xf(xf, bc$cols) }
  list(dd = dd, xf = xf, rc = rc, bc = bc, ex = ex)
}
# These options change only the DiD-averaging cells; TWFE and imputation keep the full spec sample (team-lead, Nov 2).
csa_static <- function(d, xt = NULL, control = "notyettreated", bstrap = FALSE, ctrl = NULL, opt = list(), force_cells = FALSE) {
  d <- csa_never_post(d)
  bal <- opt$balance_e; cells <- opt$cells %||% (if (isTRUE(opt$pairs)) "pairs" else "")
  plan0 <- if (identical(opt$agg, "calendar")) "calendar" else NULL   # NULL = did's "simple"
  G <- n_coh(d); Tn <- uniqueN(d$t)
  rc0 <- anyDuplicated(d, by = c("id", "t")) > 0; unbal <- !rc0 && is_unbalanced(d); wm <- csa_wmode(opt, rc0, unbal)
  hull_w <- !identical(opt$weights, "did") && (rc0 || unbal)   # Hull's treated-count weights differ from did's here
  ign <- paste0(if (!is.null(xt)) ";xt_ignored" else "", if (length(ctrl)) ";controls_ignored" else "")
  if (cells == "pairs") {
    if (rc0) return(list(est = NA_real_, se = NA_real_, note = "csa_pairs_needs_panel"))
    r <- csa_manual(d, control = control, plan = plan0, bal = bal)
    return(list(est = unname(r$est[1]), se = unname(r$se[1]), fc_est = unname(r$est[1]), fc_se = unname(r$se[1]), note = paste0("csa_cells_pairs", ign)))
  }
  if (cells == "rc_csdid") {
    r <- csa_hull_lean(d, plan0, rc = TRUE, control = control, bal = bal, wmode = "cell")
    return(list(est = unname(r$est[1]), se = unname(r$se[1]), note = paste0("csa_cells_rc_csdid", ign)))
  }
  has_cov <- !is.null(xt) || length(ctrl) > 0
  did_prep <- function() csa_did_data(d, xt, ctrl)   # did's data: gnum, expanded xt, controls (also csa_leverage, Nov 4)
  # Nov 4: did's estimator cell by cell (csa_did_cells, no n x cells influence-function matrix) where did cannot run with
  # covariates: above the size or memory guards (NA until Nov 4) and on did's own size or memory errors (CSA_CELLS_RE). The
  # note starts with the route (size_did_cells / rc_did_cells / unbalanced_did_cells / did_error_cells / did_cells) and keeps
  # the tokens of the did path (xt, dropped baselines, ";unbalanced_did", unit clustering, NA cells; the NA counts are over the
  # cells of the static summary, not all of did's cells).
  cells_path <- function(tag, p = did_prep(), fc_est = NA_real_, fc_se = NA_real_) {
    r <- csa_did_cells(p$dd, p$xf, control = control, rc = p$rc, est_method = if (p$rc && length(ctrl)) "dr" else "reg", plan = plan0, bal = bal,
                       hull = hull_w, aggte_na = is.null(bal) && !hull_w)
    list(est = r$est, se = r$se, note = paste0(tag, p$ex$note, bdrop_note(p$bc), if (unbal) ";unbalanced_did" else "", r$note), fc_est = fc_est, fc_se = fc_se)
  }
  if (!force_cells && (G * Tn > CSA_MAX_CELLS || nrow(d) > CSA_MAX_OBS)) {   # too large for did: same estimator from cell sums when no covariates (Nov 2), cell by cell with covariates (Nov 4)
    msg <- sprintf("csa_skipped_size:G=%d,T=%d,N=%d", G, Tn, nrow(d))
    if (!has_cov) {
      r <- tryCatch(csa_hull_lean(d, plan0, rc = rc0, control = control, bal = bal, wmode = wm), error = function(e) NULL)
      if (!is.null(r) && is.finite(r$est[1])) return(list(est = unname(r$est[1]), se = unname(r$se[1]), note = paste0("size_did_lean;", msg)))
      return(list(est = NA_real_, se = NA_real_, note = msg))
    }
    fc <- if (unbal) tryCatch(csa_manual(d, control = control, plan = plan0, bal = bal), error = function(e) NULL) else NULL   # robustness: composition-fixed cells, as on the did route
    return(tryCatch(cells_path(paste0("size_did_cells;", msg), fc_est = if (is.null(fc)) NA_real_ else unname(fc$est[1]), fc_se = if (is.null(fc)) NA_real_ else unname(fc$se[1])),
                    error = function(e) list(est = NA_real_, se = NA_real_, note = paste0(msg, ";did_cells_error:", csa_short(e)))))
  }
  if (unbal && CSA_UNBAL == "fixed") { r <- csa_manual(d, control = control, plan = plan0, bal = bal)
    return(list(est = unname(r$est[1]), se = unname(r$se[1]), note = paste0(r$note, if (!is.null(xt)) ";xt_ignored" else "", if (length(ctrl)) ";controls_ignored" else ""))) }
  fc <- if (unbal && !force_cells) tryCatch(csa_manual(d, control = control, plan = plan0, bal = bal), error = function(e) NULL) else NULL   # robustness: composition-fixed cells
  fc_est <- if (is.null(fc)) NA_real_ else unname(fc$est[1]); fc_se <- if (is.null(fc)) NA_real_ else unname(fc$se[1])
  if (!force_cells && !is.null(mg <- csa_if_guard(d, G, Tn))) {
    # did would not fit in memory: same estimator without the influence-function matrix (csa_hull_lean; identical to did to
    # 2e-11 on all 216 unweighted, covariate-free unbalanced specifications where did runs, Nov 2), with bootstrap SEs
    if ((unbal && CSA_UNBAL == "hull" || rc0) && !has_cov) {   # repeated cross-sections too (Nov 2, mksc.2023.1437 T6)
      r <- tryCatch(csa_hull_lean(d, plan0, rc = rc0, control = control, bal = bal, wmode = wm), error = function(e) NULL)
      if (!is.null(r)) return(list(est = unname(r$est[1]), se = unname(r$se[1]), note = paste0(if (rc0) "rc_did_lean;" else "unbalanced_did_lean;", sub(",.*", "", mg)), fc_est = fc_est, fc_se = fc_se))
    }
    if (has_cov) {   # Nov 4: with covariates, did's estimator cell by cell (analytic SE from the accumulated influence function)
      r <- tryCatch(cells_path(paste0(if (rc0) "rc_did_cells;" else if (unbal) "unbalanced_did_cells;" else "did_cells;", sub(",.*", "", mg)), fc_est = fc_est, fc_se = fc_se), error = function(e) NULL)
      if (!is.null(r)) return(r)
    }
    return(list(est = NA_real_, se = NA_real_, note = mg, fc_est = fc_est, fc_se = fc_se))
  }
  p <- did_prep(); dd <- p$dd; xf <- p$xf; rc <- p$rc; bc <- p$bc; ex <- p$ex
  if (force_cells) return(cells_path("did_cells", p, fc_est, fc_se))   # CSA_CELLS_CHECK harness (run_spec.R): the replica on a spec did can run
  # did rejects time-varying cluster variables; the point estimate does not depend on them, so refit with unit clusters
  # (mnsc.2021.03484, Nov 2) and record it in the note
  fit_a <- function(dd) if (!rc) att_gt(yname = "y", tname = "t", idname = "id", gname = "gnum", data = as.data.frame(dd),
              xformla = xf, control_group = control, weightsname = "w", clustervars = "cl",
              bstrap = bstrap, cband = FALSE, base_period = "universal",
              allow_unbalanced_panel = TRUE, est_method = "reg", faster_mode = CSA_FASTER)
       else att_gt(yname = "y", tname = "t", gname = "gnum", data = as.data.frame(dd), panel = FALSE,
              xformla = xf, control_group = control, weightsname = "w", clustervars = "cl",
              bstrap = bstrap, cband = FALSE, base_period = "universal", est_method = if (length(ctrl)) "dr" else "reg", faster_mode = CSA_FASTER)
  cl_note <- ""
  fit_c <- function(dd) tryCatch(fit_a(dd), error = function(e) if (grepl(CSA_CELLS_RE, conditionMessage(e))) structure(list(msg = conditionMessage(e)), class = "csa_did_fail") else stop(e))   # size / memory failure -> cells (Nov 4)
  a <- tryCatch(fit_c(dd), error = function(e) { if (!grepl("Time-varying cluster", conditionMessage(e))) stop(e)
    cl_note <<- ";csa_clustered_by_unit"; dd2 <- copy(dd); dd2[, cl := id]; fit_c(dd2) })
  if (inherits(a, "csa_did_fail")) return(cells_path(paste0("did_error_cells;", csa_short(a$msg)), p, fc_est, fc_se))
  if (is.null(bal) && !hull_w) { s <- aggte(a, type = if (is.null(plan0)) "simple" else "calendar", na.rm = TRUE); est <- s$overall.att; se <- s$overall.se }   # did's weights
  else { s <- csa_did_summarize(a, plan0, bal, hull = hull_w); est <- unname(s$est[1]); se <- unname(s$se[1]) }   # Hull treated-count weights and/or balance_e
  list(est = est, se = se, attgt = a, note = paste0(ex$note, bdrop_note(bc), if (unbal) ";unbalanced_did" else "", cl_note, csa_na_note(a, xf, est)),
       fc_est = fc_est, fc_se = fc_se)
}

# ---- 4. Borusyak-Jaravel-Spiess imputation -----------------------------------------
# Implemented as Gardner's two-stage estimator (did2s): stage 1 fits the FE model on untreated
# observations, stage 2 regresses the residualized outcome on D. The point estimate equals the
# imputation estimator |T|^-1 sum_j (Y_j - Yhat_j(0)) and the SE accounts for stage-1 noise.
# (didimputation::did_imputation with horizon = FALSE returned only the horizon-0 effect in
# tests, so it is not used.)
bjs_static <- function(d, xt = NULL, ctrl = NULL) {
  dd <- copy(d)
  fs <- as.formula(paste0("~ ", rhs_ctrl(ctrl, none = "0"), " | id + t", if (is.null(xt)) "" else paste0(" + ", paste0("t^", xt, collapse = " + "))))
  m <- did2s::did2s(data = as.data.frame(dd), yname = "y", first_stage = fs, second_stage = ~ i(D, ref = 0),
                    treatment = "D", cluster_var = "cl", weights = "w", verbose = FALSE)
  list(est = unname(coef(m)[1]), se = unname(fixest::se(m)[1]))
}
# manual imputation point estimate, used as a cross-check
bjs_manual <- function(d, xt = NULL) {
  fe <- if (is.null(xt)) "id + t" else paste0("id + t + ", paste0("t^", xt, collapse = " + "))
  m0 <- feols(as.formula(paste0("y ~ 1 | ", fe)), data = d[D == 0], weights = ~w, fixef.rm = "none")   # explicit: keep singletons, as did2s
  yh <- predict(m0, newdata = d)
  tr <- d$D == 1 & !is.na(yh)
  sum(d$w[tr] * (d$y[tr] - yh[tr])) / sum(d$w[tr])
}

# ---- 5. Leverage screen (Hull Appendix B, eq. 2) -----------------------------------
# a_j: influence coefficients of the estimator on y (theta = sum_j a_j y_j)
leverage_screen <- function(a, cl) {
  L <- tapply(a^2, cl, sum) / sum(a^2)
  list(G_eff = 1 / sum(L^2), L_max = max(L), pass = (1 / sum(L^2) >= 10) & (max(L) <= 0.25))
}
# TWFE influence coefficients: a = w*Dtilde / sum(w*Dtilde*D)
twfe_influence <- function(d, xt = NULL, ctrl = NULL) {
  fe <- if (is.null(xt)) "id + t" else paste0("id + t + ", paste0("t^", xt, collapse = " + "))
  Dt <- resid(feols(as.formula(paste0("D ~ ", rhs_ctrl(ctrl), " | ", fe)), data = d, weights = ~w))
  d$w * Dt / sum(d$w * Dt * d$D)
}

# ---- 6. Bayesian bootstrap for the TWFE-modern covariance ---------------------------
boot_pair <- function(d, xt = NULL, B = 199, seed = 1, modern = c("csa", "bjs"), ctrl = NULL) {
  # outer Bayesian bootstrap over clusters; all weights are drawn up front because csa_manual resets the RNG (review R1)
  set.seed(seed); modern <- match.arg(modern)
  cls <- unique(d$cl); W <- matrix(rexp(B * length(cls)), B); out <- matrix(NA_real_, B, 2)
  for (b in seq_len(B)) {
    ww <- data.table(cl = cls, bw = W[b, ])
    db <- merge(d, ww, by = "cl"); db[, w := w * bw]
    out[b, 1] <- tryCatch(twfe_static(db, xt, ctrl)$est, error = function(e) NA)
    out[b, 2] <- tryCatch(if (modern == "csa") csa_static(db, xt, ctrl = ctrl)$est else bjs_static(db, xt, ctrl)$est, error = function(e) NA)
  }
  cov(out, use = "complete.obs")
}


# ---- 7. One-call wrapper -------------------------------------------------------------
# Shared helpers (Nov 2). n_coh: cohorts as the modern estimators see them (adopters before the first sample period keep their
# true period index, possibly <= 0, since Nov 2 (Hull App. B), and are always-treated exactly as before). reg_rows: the TWFE /
# imputation sample; balance_e = k drops the post-adoption rows of cohorts not observed through e = k (g + k > last period),
# whose pre-adoption rows stay as not-yet-treated controls, while CSA keeps every row and applies did's cell rule. The
# outcome is standardized on the TWFE sample.
fe_str <- function(xt) if (is.null(xt)) "id + t" else paste0("id + t + ", paste0("t^", xt, collapse = " + "))
# Adopters after the last sample period keep their true index too (g > T; team-lead Nov 2): D = 0 on all their rows, they get
# lead indicators in the TWFE event study and the BJS lead regression, and DiD-averaging treats them as never-treated, as did
# does for g > max t (csa_never_post). n_cohorts and share_never count them as before (never-treated).
n_coh <- function(d) { t1 <- min(d$t); g <- d$g[is.finite(d$g) & d$g <= max(d$t)]; uniqueN(pmax(g, t1)) }
never_share <- function(d) mean(!is.finite(d$g) | d$g > max(d$t))
csa_never_post <- function(d) { tT <- max(d$t); if (!any(is.finite(d$g) & d$g > tT)) return(d); d <- copy(d); d[is.finite(g) & g > tT, g := Inf]; d }
reg_rows <- function(d, opt = list()) { k <- opt$balance_e; if (is.null(k)) return(rep(TRUE, nrow(d))); !(is.finite(d$g) & d$g + k > max(d$t) & d$t >= d$g) }
std_y <- function(d, reg) { s <- sqrt(Hmisc_wtd_var(d$y[reg], d$w[reg])); d[, y := y / s]; s }
compare_spec <- function(d, xt = NULL, B = 0, ctrl = NULL, opt = list()) {
  d <- prep_panel(d, standardize = FALSE); reg <- reg_rows(d, opt); s <- std_y(d, reg)
  dr <- if (all(reg)) d else d[reg]
  tw <- twfe_static(dr, xt, ctrl); wt <- twfe_weights(dr, xt, ctrl)
  # CSA_SKIP=1 (Nov 3): skip DiD-averaging (and its leverage) for reruns that only refresh the imputation-leverage columns of an
  # existing output (code/levpatch.py); unset = unchanged behaviour
  cs <- if (Sys.getenv("CSA_SKIP") == "1") list(est = NA, se = NA, err = "csa_skip_flag") else
    tryCatch(csa_static(d, xt, control = opt$control %||% "notyettreated", ctrl = ctrl, opt = opt), error = function(e) list(est = NA, se = NA, err = conditionMessage(e)))
  bj <- tryCatch(bjs_static(dr, xt, ctrl), error = function(e) bjs_fallback(e, dr, xt, ctrl))
  lev <- leverage_screen(twfe_influence(dr, xt, ctrl), dr$cl)
  res <- data.table(twfe = tw$est, twfe_se = tw$se, csa = cs$est, csa_se = cs$se, bjs = bj$est, bjs_se = bj$se,
                    csa_fc = cs$fc_est %||% NA_real_, csa_fc_se = cs$fc_se %||% NA_real_,
                    csa_note = cs$note %||% cs$err %||% "", bjs_note = bj$err %||% "",
                    neg_rows = wt$share_neg_rows, neg_abs = wt$share_neg_abs, G_eff = lev$G_eff, L_max = lev$L_max,
                    n = tw$n, n_units = uniqueN(dr$id), n_cohorts = n_coh(dr),
                    share_never = never_share(dr), share_always = dr[, mean(is.finite(g) & g <= min(t))])
  if (B > 0) { V <- boot_pair(dr, xt, B, ctrl = ctrl); res[, cov_twfe_csa := V[1, 2]] }
  res[, es_source := NA_character_]
  res <- cbind(res, modern_leverage(d, dr, xt, ctrl, if (identical(opt$agg, "calendar")) "calendar" else NULL, NULL, opt, cs$est, bj$est))   # Nov 2
  setattr(res, "y_sd", s)
  res[]
}

# ---- 8. Event-study comparison (Hull Section 3, fn. 10-11, Appendix B) -----------------------------
# Bins, reference set and summary bins come from the spec's event_structure (code/R/event_structure.R), or from es_legacy()
# (ref -1, single-period bins pre_min..-2 and 0..post_max, endpoint bins beyond) for specs without one (Nov 2).
# TWFE: y ~ i(ebin, ref = 0) | FE, i.e. the authors' indicators; summaries = equal-weight means of the estimated summary-bin
#       coefficients, delta-method SE from the clustered vcov.
# CSA : ATT(g,t) cells with universal base g-1; bin effect = pooled average of the cells with e in the bin with did's cohort
#       weights, minus the reference effect (csa_summarize; Hull fn. 10). SE from did's influence functions (did path) or
#       the cluster Bayesian bootstrap (lean and composition-fixed paths).
# BJS : reference -1 alone ("standard"): did2s bin coefficients (post) and the untreated-sample lead regression (pre), as
#       before. Any other reference ("explicit", Hull App. B): bin means of Y - Yhat(0), bins averaged equally, minus the
#       weighted residual mean in the reference observations (ever-treated rows with e in the reference set: treated rows
#       give their imputed effect, untreated rows their in-sample residual), from one did2s second stage with the bins and a
#       reference indicator, so the SE includes first-stage noise. The pre contrasts are then not BJS pretrend coefficients.
# Leverage of the TWFE post-window average (Hull Appendix B applied to the averaged coefficient): theta_post = a'y with
# a = W R colMeans(M[post, ]), R the FE-residualized bin dummies and M = (R'WR)^-1.
event_leverage_core <- function(dd, xt, fe, post_bins, ctrl = NULL) {
  tryCatch({
    bins <- setdiff(sort(unique(dd$ebin)), 0L); cn <- paste0("b", bins)
    Xd <- vapply(bins, function(b) as.numeric(dd$ebin == b), numeric(nrow(dd))); Xd <- matrix(Xd, nrow(dd)); colnames(Xd) <- cn
    dX <- cbind(dd[, c("id", "t", "w", "cl", xt, ctrl), with = FALSE], as.data.table(Xd))
    mr <- feols(as.formula(paste0("c(", paste(cn, collapse = ","), ") ~ ", rhs_ctrl(ctrl), " | ", fe)), data = dX, weights = ~w)
    R <- resid(mr); if (is.list(R)) R <- do.call(cbind, R); R <- as.matrix(R)
    WR <- R * dd$w; M <- solve(crossprod(R, WR))
    sel <- match(paste0("b", post_bins), cn); sel <- sel[!is.na(sel)]
    a <- as.numeric(WR %*% colMeans(M[sel, , drop = FALSE]))
    leverage_screen(a, dd$cl)
  }, error = function(e) list(G_eff = NA_real_, L_max = NA_real_, pass = NA, err = conditionMessage(e)))
}
twfe_event_leverage <- function(d, xt = NULL, pre_min = -5, post_max = 5, es = NULL, opt = list()) {
  S <- es_parse(es %||% es_legacy(pre_min, post_max))
  dd <- es_assign(prep_panel(d), S)$d; dd <- dd[reg_rows(dd, opt)]
  event_leverage_core(dd, xt, fe_str(xt), post_bins = intersect(S$post_idx, unique(dd$ebin)))
}
compare_spec_event <- function(d, xt = NULL, pre_min = -5, post_max = 5, ctrl = NULL, es = NULL, opt = list()) {
  es_source <- if (is.null(es)) "legacy" else "spec"
  S <- es_parse(es %||% es_legacy(pre_min, post_max))
  d <- es_assign(prep_panel(d, standardize = FALSE), S)$d   # rel, ebin, eref; uncovered rows dropped when uncovered = "drop"
  reg <- reg_rows(d, opt); s <- std_y(d, reg)
  dr <- if (all(reg)) d else d[reg]                         # TWFE / imputation sample; CSA uses d
  fe <- fe_str(xt)
  m <- feols(as.formula(paste0("y ~ i(ebin, ref = 0)", plus_ctrl(ctrl), " | ", fe)), data = dr, weights = ~w, cluster = ~cl)
  if (length(m$collin.var)) stop("twfe_event_collinear: ", paste(m$collin.var, collapse = ","))   # e.g. no never-treated and no endpoint rows (review R5)
  cf <- coef(m); V <- vcov(m); keep <- grepl("^ebin::", names(cf)); cf <- cf[keep]; V <- V[keep, keep, drop = FALSE]
  bn <- as.integer(sub("ebin::", "", names(cf)))
  avg <- function(idx) { if (!length(idx)) return(c(NA, NA)); a <- rep(1 / length(idx), length(idx)); c(sum(a * cf[idx]), sqrt(as.numeric(t(a) %*% V[idx, idx] %*% a))) }
  tpi <- which(bn %in% S$post_idx); tri <- which(bn %in% S$pre_idx)
  tw_post <- avg(tpi); tw_pre <- avg(tri)
  lev <- event_leverage_core(dr, xt, fe, post_bins = bn[tpi], ctrl = ctrl)
  cs <- if (Sys.getenv("CSA_SKIP") == "1") list(post = c(NA, NA), pre = c(NA, NA), err = "csa_skip_flag") else   # see compare_spec
    tryCatch(csa_event(d, xt, ctrl, S, opt), error = function(e) list(post = c(NA, NA), pre = c(NA, NA), err = conditionMessage(e)))
  bj <- tryCatch(bjs_event(dr, xt, ctrl, S, fe), error = function(e) bjs_fallback(e, dr, xt, ctrl, S))
  nbv <- function(x, k) if (is.null(x) || is.null(x[[k]])) NA_integer_ else as.integer(x[[k]])
  out <- rbind(
    data.table(window = "post", twfe = tw_post[1], twfe_se = tw_post[2], csa = cs$post[1], csa_se = cs$post[2], bjs = bj$post[1], bjs_se = bj$post[2], csa_fc = cs$fc$post[1] %||% NA_real_, csa_fc_se = cs$fc$post[2] %||% NA_real_),
    data.table(window = "pre",  twfe = tw_pre[1],  twfe_se = tw_pre[2],  csa = cs$pre[1],  csa_se = cs$pre[2],  bjs = bj$pre[1],  bjs_se = bj$pre[2], csa_fc = cs$fc$pre[1] %||% NA_real_, csa_fc_se = cs$fc$pre[2] %||% NA_real_)
  )[, `:=`(n = nrow(dr), n_units = uniqueN(dr$id), n_cohorts = n_coh(dr), share_never = never_share(dr),
           csa_note = cs$err %||% cs$note %||% "", bjs_note = bj$err %||% "", G_eff = lev$G_eff, L_max = lev$L_max)]
  # Nov 2 additions: event-structure source, available summary bins per estimator (requested: nbins_spec), reference handling
  out[, `:=`(es_source = es_source, nbins_spec = c(length(S$post_idx), length(S$pre_idx)), nbins_twfe = c(length(tpi), length(tri)),
             nbins_csa = c(nbv(cs$nb, "post"), nbv(cs$nb, "pre")), nbins_bjs = c(nbv(bj$nb, "post"), nbv(bj$nb, "pre")),
             csa_theta_ref = cs$thR %||% NA_real_, bjs_ref = bj$ref %||% NA_character_, bjs_theta_ref = bj$thR %||% NA_real_)]
  out <- cbind(out, modern_leverage(d, dr, xt, ctrl, S, S, opt, cs$post[1], bj$post[1]))   # post summary, as the TWFE screen
  setattr(out, "y_sd", s)
  out[]
}
csa_event <- function(d, xt, ctrl, S, opt) {
  d <- csa_never_post(d)
  control <- opt$control %||% "notyettreated"; bal <- opt$balance_e; cells <- opt$cells %||% (if (isTRUE(opt$pairs)) "pairs" else "")
  G <- n_coh(d); Tn <- uniqueN(d$t)
  rcx <- anyDuplicated(d, by = c("id", "t")) > 0; unbal <- !rcx && is_unbalanced(d)
  pp <- function(r) list(post = c(r$est[["post"]], r$se[["post"]]), pre = c(r$est[["pre"]], r$se[["pre"]]))
  ign <- paste0(if (!is.null(xt)) ";xt_ignored" else "", if (length(ctrl)) ";controls_ignored" else "")
  if (cells == "pairs") {   # csa_cells = "pairs": Stata csdid's pair-balanced cells are the main CSA (see csa_static)
    if (rcx) stop("csa_pairs_needs_panel")
    r <- csa_manual(d, control = control, plan = S, bal = bal)
    return(c(pp(r), list(nb = r$nb, thR = r$thR, fc = pp(r), note = paste0("csa_cells_pairs", ign))))
  }
  if (cells == "rc_csdid") {   # csdid without ivar (see csa_static)
    r <- csa_hull_lean(d, S, rc = TRUE, control = control, bal = bal, wmode = "cell")
    return(c(pp(r), list(nb = r$nb, thR = r$thR, note = paste0("csa_cells_rc_csdid", ign))))
  }
  size_big <- G * Tn > CSA_MAX_CELLS || nrow(d) > CSA_MAX_OBS
  if (size_big && !(is.null(xt) && !length(ctrl))) stop(sprintf("csa_skipped_size:G=%d,T=%d,N=%d", G, Tn, nrow(d)))
  fcw <- if (unbal) tryCatch(pp(csa_manual(d, control = control, plan = S, bal = bal)), error = function(e) NULL) else NULL   # robustness: composition-fixed
  lean_ok <- is.null(xt) && !length(ctrl) && (size_big || ((unbal && CSA_UNBAL == "hull" || rcx) && !is.null(csa_if_guard(d, G, Tn))))
  if (lean_ok) {   # did would not fit in memory: same estimator without the influence-function matrix (see csa_static)
    r <- csa_hull_lean(d, S, rc = rcx, control = control, bal = bal, wmode = csa_wmode(opt, rcx, unbal))
    return(c(pp(r), list(nb = r$nb, thR = r$thR, note = paste0(if (size_big) "size_" else "", if (rcx) "rc_did_lean" else if (unbal) "unbalanced_did_lean" else "did_lean"), fc = fcw)))
  }
  if (unbal && CSA_UNBAL == "fixed") {
    r <- csa_manual(d, control = control, plan = S, bal = bal)
    return(c(pp(r), list(nb = r$nb, thR = r$thR, note = paste0("csa_manual_balanced_cells", ign))))
  }
  if (!is.null(mg <- csa_if_guard(d, G, Tn))) stop(mg)
  de <- copy(d); de[, gnum := ifelse(is.finite(g), pmax(g, min(t)), 0)]
  ex <- expand_xt(de, xt); de <- ex$data; xf <- ex$xf
  rc <- anyDuplicated(de, by = c("id", "t")) > 0
  bc <- NULL
  if (rc) { de <- demean_by_t(de, ctrl); xf <- merge_xf(xf, ctrl %||% character(0)) } else { bc <- add_baseline_controls(de, ctrl); de <- bc$data; xf <- merge_xf(xf, bc$cols) }
  fit_a <- function(de) if (!rc) att_gt(yname = "y", tname = "t", idname = "id", gname = "gnum", data = as.data.frame(de), xformla = xf,
              control_group = control, weightsname = "w", clustervars = "cl", bstrap = FALSE, cband = FALSE,
              base_period = "universal", allow_unbalanced_panel = TRUE, est_method = "reg", faster_mode = CSA_FASTER)
       else att_gt(yname = "y", tname = "t", gname = "gnum", data = as.data.frame(de), panel = FALSE, xformla = xf,
              control_group = control, weightsname = "w", clustervars = "cl", bstrap = FALSE, cband = FALSE,
              base_period = "universal", est_method = if (length(ctrl)) "dr" else "reg", faster_mode = CSA_FASTER)
  cl_note <- ""
  a <- tryCatch(fit_a(de), error = function(e) { if (!grepl("Time-varying cluster", conditionMessage(e))) stop(e)
    cl_note <<- ";csa_clustered_by_unit"; de2 <- copy(de); de2[, cl := id]; fit_a(de2) })
  r <- csa_did_summarize(a, S, bal, hull = !identical(opt$weights, "did"))   # clustered like did's getSE (review fix Nov 1 ~19:30)
  c(pp(r), list(nb = r$nb, thR = r$thR, fc = fcw,
    note = paste0(ex$note, if (!r$clustered) ";se_unclustered" else "", bdrop_note(bc), if (unbal) ";unbalanced_did" else "", cl_note, csa_na_note(a, xf, r$est[["post"]]))))
}
bjs_event <- function(dr, xt, ctrl, S, fe) {
  fs <- as.formula(paste0("~ ", rhs_ctrl(ctrl, none = "0"), " | id + t", if (is.null(xt)) "" else paste0(" + ", paste0("t^", xt, collapse = " + "))))
  if (!any(dr$eref & dr$erel != -1)) {   # standard: the reference observations are event time -1 alone
    # no intercept in did2s's second stage, so with no reference rows (no never-treated, no rel -1) every bin can enter
    mb <- did2s::did2s(data = as.data.frame(dr), yname = "y", first_stage = fs, second_stage = if (any(dr$ebin == 0L)) ~ i(ebin, ref = 0) else ~ i(ebin),
                       treatment = "D", cluster_var = "cl", weights = "w", verbose = FALSE)
    cfb <- coef(mb); Vb <- vcov(mb); hz <- as.integer(sub("ebin::", "", names(cfb)))
    aggb <- function(idx) { if (!length(idx)) return(c(NA, NA)); a <- rep(1 / length(idx), length(idx)); c(sum(a * cfb[idx]), sqrt(as.numeric(t(a) %*% Vb[idx, idx] %*% a))) }
    pi <- which(hz %in% S$post_idx)
    # Pre-trend summary as in Hull (2026, Appendix B) / Borusyak, Jaravel and Spiess (2024): regress y on the allowed FE (and
    # controls) plus lead-bin indicators using UNTREATED observations only, and average the identified lead coefficients over
    # the pre-summary bins (reference: rel -1, never-treated). Replaces the did2s second-stage lead coefficients, which are
    # in-sample first-stage residual means (Nov 1 ~21:00).
    du <- dr[D == 0]; du[, lead := fifelse(is.finite(g) & ebin > 0L, ebin, 0L)]
    pre <- tryCatch({
      ml <- feols(as.formula(paste0("y ~ i(lead, ref = 0)", plus_ctrl(ctrl), " | ", fe)), data = du, weights = ~w, cluster = ~cl)
      cl_ <- coef(ml); Vl <- vcov(ml); lh <- as.integer(sub("lead::", "", names(cl_))); idx <- which(lh %in% S$pre_idx)
      if (!length(idx)) c(NA, NA, 0) else { a <- rep(1 / length(idx), length(idx)); c(sum(a * cl_[idx]), sqrt(as.numeric(t(a) %*% Vl[idx, idx] %*% a)), length(idx)) }
    }, error = function(e) c(NA, NA, 0))
    return(list(post = aggb(pi), pre = pre[1:2], nb = c(post = length(pi), pre = pre[3]), ref = "standard", thR = 0))
  }
  nb <- nrow(S$bins); dx <- as.data.frame(dr); dx$ebx <- ifelse(dr$eref, nb + 1L, dr$ebin)   # nb + 1 = reference observations
  mb <- did2s::did2s(data = dx, yname = "y", first_stage = fs, second_stage = if (any(dx$ebx == 0L)) ~ i(ebx, ref = 0) else ~ i(ebx),
                     treatment = "D", cluster_var = "cl", weights = "w", verbose = FALSE)
  cfb <- coef(mb); Vb <- vcov(mb); hz <- as.integer(sub("ebx::", "", names(cfb))); ri <- which(hz == nb + 1L)
  if (!length(ri)) return(list(post = c(NA, NA), pre = c(NA, NA), nb = c(post = 0L, pre = 0L), ref = "explicit", thR = NA_real_, err = "bjs_reference_unsupported"))
  con <- function(bins) { idx <- which(hz %in% bins); if (!length(idx)) return(c(NA, NA))
    a <- c(rep(1 / length(idx), length(idx)), -1); j <- c(idx, ri); c(sum(a * cfb[j]), sqrt(as.numeric(t(a) %*% Vb[j, j] %*% a))) }
  list(post = con(S$post_idx), pre = con(S$pre_idx), nb = c(post = sum(hz %in% S$post_idx), pre = sum(hz %in% S$pre_idx)), ref = "explicit", thR = unname(cfb[ri]))
}

# Imputation point estimates from the fixest first stage (Nov 2): the same quantities as did2s (static: mean of Y - Yhat(0)
# over supported treated rows; event: within-bin means of Y - Yhat(0), with the untreated-sample lead regression for the
# standard pre summary, or minus the reference observations' mean for an explicit reference). Used by boot_cov.R for every
# weighted draw (wcol = "wb") and as the main estimate when did2s is too large (bjs_fallback; SE from the bootstrap SD).
bjs_point <- function(dr, xt = NULL, ctrl = NULL, S = NULL, wcol = "w") {
  fe <- fe_str(xt); wf <- as.formula(paste0("~", wcol))
  m0 <- feols(as.formula(paste0("y ~ ", rhs_ctrl(ctrl), " | ", fe)), data = dr[D == 0], weights = wf, warn = FALSE, notes = FALSE, fixef.keep_names = TRUE)
  if (is.null(S)) { tr <- dr[D == 1]; r <- tr$y - predict(m0, newdata = tr); ok <- !is.na(r); w <- tr[[wcol]]; return(list(static = sum(w[ok] * r[ok]) / sum(w[ok]))) }
  std <- !any(dr$eref & dr$erel != -1)
  bavg <- function(v, b, idx) { i <- which(b %in% idx); if (length(i)) mean(v[i]) else NA_real_ }
  use <- dr$ebin %in% c(S$post_idx, if (!std) S$pre_idx) | (!std & dr$eref)
  x <- data.table(ebin = dr$ebin[use], eref = dr$eref[use], w = dr[[wcol]][use], r = dr$y[use] - predict(m0, newdata = dr[use]))[is.finite(r)]
  hb <- x[ebin > 0L, .(v = sum(w * r) / sum(w)), by = ebin]
  if (std) {
    pre <- tryCatch({ du <- dr[D == 0]; du[, lead := fifelse(is.finite(g) & ebin > 0L, ebin, 0L)]
      ml <- feols(as.formula(paste0("y ~ i(lead, ref = 0)", plus_ctrl(ctrl), " | ", fe)), data = du, weights = wf, warn = FALSE, notes = FALSE)
      cl_ <- coef(ml); lk <- grepl("^lead::", names(cl_)); bavg(cl_[lk], as.integer(sub("lead::", "", names(cl_)[lk])), S$pre_idx) }, error = function(e) NA_real_)
    return(list(post = bavg(hb$v, hb$ebin, S$post_idx), pre = pre))
  }
  xr <- x[eref == TRUE]; thR <- if (nrow(xr)) sum(xr$w * xr$r) / sum(xr$w) else NA_real_
  list(post = bavg(hb$v, hb$ebin, S$post_idx) - thR, pre = bavg(hb$v, hb$ebin, S$pre_idx) - thR)
}
# did2s too large (its X'X is singular beyond zero columns and too big for a dense pseudo-inverse, or memory runs out):
# point estimates from bjs_point, SE left NA and flagged "bjs_se_bootstrap" (take boot_sd_bjs from boot_cov.R). Other errors
# keep BJS = NA as before (team-lead, Nov 2).
BJS_FALLBACK_RE <- "did2s_singular_large|cannot allocate|vector memory"
bjs_fallback <- function(e, dr, xt, ctrl, S = NULL) {
  msg <- conditionMessage(e)
  na <- if (is.null(S)) list(est = NA_real_, se = NA_real_, err = msg) else list(post = c(NA, NA), pre = c(NA, NA), err = msg)
  if (!grepl(BJS_FALLBACK_RE, msg)) return(na)
  r <- tryCatch(bjs_point(dr, xt, ctrl, S), error = function(e2) NULL); if (is.null(r)) return(na)
  note <- paste0("bjs_se_bootstrap;", sub("(.{0,60}).*", "\\1", msg))
  if (is.null(S)) return(list(est = r$static, se = NA_real_, err = note))
  list(post = c(r$post, NA), pre = c(r$pre, NA), err = note, ref = if (!any(dr$eref & dr$erel != -1)) "standard" else "explicit")
}

# ---- 8b. DiD-averaging aggregation shared by every CSA path (Nov 2; Hull Section 3, fn. 10, App. B) -------------------------
# e, g: per-cell event time and cohort; A, P: per-cell ATT(g,t) and weight (did's cohort weight pg, or treated count in the
# composition-fixed cells), vectors or (cells x draws) matrices. plan NULL = static: pooled average over e >= 0 (did's aggte
# "simple"). plan = parsed event structure: bin effect = pooled average of the cells with e in the bin (a single-period bin
# equals did's dynamic effect at e), reference effect theta_R = the same over the reference set (omitted bins plus pooled
# uncovered times; the zero cells at e = -1 count with their weight; 0 by construction when the reference is -1 alone),
# contrast = bin effect - theta_R ("the modern estimates subtract the estimated reference effect", fn. 10), summaries =
# equal-weight means of the available summary-bin contrasts; unsupported bins stay unavailable (never zero-filled).
# bal = list(k, Tmax, Tmin): did's aggte(balance_e = k) rule (cohorts with Tmax - g >= k, event times k - Tmax + Tmin..k).
# Returns list(est = draws x summaries matrix, nb = available bins per summary (first draw), thR = reference effect by draw).
csa_cell_sets <- function(e, g, plan = NULL, bal = NULL) {
  keep <- rep(TRUE, length(e))
  if (!is.null(bal)) keep <- (bal$Tmax - g >= bal$k) & (e <= bal$k) & (e >= bal$k - bal$Tmax + bal$Tmin)
  if (is.null(plan)) return(list(static = which(keep & e >= 0)))
  if (identical(plan, "calendar")) { k <- which(keep & e >= 0); return(list(cal = split(k, (g + e)[k]))) }   # post cells by calendar t
  bi <- es_which(e, plan$bins)
  list(bins = lapply(seq_len(nrow(plan$bins)), function(b) which(keep & !is.na(bi) & bi == b)), R = which(keep & es_inref(e, plan)),
       ref_m1 = !is.na(es_which(-1, plan$ref)) || es_inref(-1, plan))
}
csa_summarize <- function(e, g, A, P, plan = NULL, bal = NULL, cs = NULL) {
  A <- as.matrix(A); P <- if (is.matrix(P)) P else matrix(P, nrow(A), ncol(A))
  ok <- is.finite(A) & is.finite(P); A[!ok] <- 0; P[!ok] <- 0
  cs <- cs %||% csa_cell_sets(e, g, plan, bal)
  pool <- function(k) { if (!length(k)) return(rep(NA_real_, ncol(A))); den <- colSums(P[k, , drop = FALSE])
    v <- colSums(A[k, , drop = FALSE] * P[k, , drop = FALSE]) / den; v[!(den > 0)] <- NA_real_; v }
  if (is.null(plan)) { v <- pool(cs$static); return(list(est = matrix(v, ncol = 1, dimnames = list(NULL, "static")), nb = c(static = as.integer(is.finite(v[1]))), thR = rep(NA_real_, ncol(A)))) }
  if (identical(plan, "calendar")) {   # did's aggte(type = "calendar"): pooled post cells within each calendar t, then t averaged equally
    V <- matrix(vapply(cs$cal, pool, numeric(ncol(A))), ncol(A)); v <- rowMeans(V, na.rm = TRUE); v[is.nan(v)] <- NA_real_
    return(list(est = matrix(v, ncol = 1, dimnames = list(NULL, "static")), nb = c(static = sum(is.finite(V[1, ]))), thR = rep(NA_real_, ncol(A)))) }
  thR <- if (length(cs$R) && any(e[cs$R] != -1)) pool(cs$R) else if (cs$ref_m1) rep(0, ncol(A)) else rep(NA_real_, ncol(A))
  C <- vapply(cs$bins, pool, numeric(ncol(A))); C <- matrix(C, ncol(A)) - thR   # draws x bins contrasts
  summ <- function(idx) { if (!length(idx)) return(rep(NA_real_, ncol(A))); v <- rowMeans(C[, idx, drop = FALSE], na.rm = TRUE); v[is.nan(v)] <- NA_real_; v }
  list(est = cbind(post = summ(plan$post_idx), pre = summ(plan$pre_idx)),
       nb = c(post = sum(is.finite(C[1, plan$post_idx])), pre = sum(is.finite(C[1, plan$pre_idx]))), thR = thR)
}
# Zero cells at e = -1 are needed when -1 is used (a reported bin or part of a pooled reference) and the reference is not -1
# alone (then theta_R = 0 by construction and the legacy cluster order, hence the draws, stays untouched)
csa_need_zero <- function(plan) is.list(plan) && !plan$ref_std && es_needed(-1, plan)
# Event times whose cells a plan uses (summary bins and the reference set)
es_needed <- function(e, plan) {
  sb <- plan$bins[c(plan$post_idx, plan$pre_idx), , drop = FALSE]
  !is.na(es_which(e, sb)) | es_inref(e, plan)
}
# The did path: same aggregation on att_gt's cells with did's own cohort weights and influence functions. pg, the unit weights
# and the unit cohorts are built exactly as in did 2.5.1's compute.aggte (read from the source, Nov 2); the IF of a pooled cell
# set is did's get_agg_inf_func with the weight-estimation term wif, written in O(n) form (algebraically identical to
# did:::wif %*% att). Point estimates and IFs of single-period bins equal aggte(type = "dynamic")'s.
did_pg_parts <- function(a) {
  dp <- a$DIDparams; gname <- dp$gname; tname <- dp$tname; idname <- dp$idname; fm <- isTRUE(dp$faster_mode)
  long <- function() { x <- as.data.frame(dp$data); if (fm) x[x[, gname] == Inf, gname] <- 0; x }
  if (dp$panel) {
    if (fm && !is.null(dp$time_invariant_data)) { dta <- as.data.frame(dp$time_invariant_data); dta[dta[, gname] == Inf, gname] <- 0 }
    else { x <- long(); tl <- if (fm) dp$time_periods else dp$tlist; dta <- x[x[, tname] == tl[1], ] }
    wi <- if (".w" %in% names(dta)) dta$.w else if (fm) dta$weights else dta$.w
    return(list(wi = wi, gvar = dta[[gname]]))
  }
  # unbalanced panels (unit ids) and repeated cross-sections (.rowid): aggte averages the rows of each id (stats::aggregate)
  x <- as.data.table(long()); wcol <- if (".w" %in% names(x)) ".w" else "weights"
  u <- x[, .(wi = mean(get(wcol)), gv = mean(get(gname))), by = c(idname)]
  list(wi = u$wi, gvar = u$gv)
}
# Precise note when did's cells are NA (team-lead, Nov 3; mnsc.2021.03484 F2: 57 sic2 dummies in did's outcome regression are
# rank-deficient in 70 of 77 cells): "csa_unsupported:<reason>(k/n)" when no reported summary is supported, else "csa_na_cells:k/n".
# The estimate stays NA (Hull: estimator-specific support; covariates are not dropped selectively).
csa_na_note <- function(a, xf, est) csa_na_note0(sum(is.na(a$att)), length(a$att), length(attr(terms(xf), "term.labels")) > 0, est)
csa_na_note0 <- function(nna, n, cov_used, est) {   # also for the cell-by-cell replica (Nov 4), counted over the static cells
  if (!isTRUE(is.finite(est))) sprintf(";csa_unsupported:%s(%d/%d)", if (cov_used && nna) "covariate_cells_rank_deficient" else "no_valid_cells", nna, n)
  else if (nna) sprintf(";csa_na_cells:%d/%d", nna, n) else ""
}
# Hull's treated-count weights on the did path (hull = TRUE; unbalanced panels and repeated cross-sections, Nov 2): p_c = mean over
# the IF rows of x_ic, the analysis weight of row/unit i if it is a cohort-g_c observation in period t_c (X below). The weight-
# estimation term of the IF of a pooled set K is sum_c (att_c - theta) x_ic / sum_K p_c, which with x_ic = w_i 1(G_i = g_c) is
# exactly did's wif (algebra checked; numerically identical on the toy panels).
did_hull_x <- function(a, group, tt) {
  dp <- a$DIDparams; gname <- dp$gname; tname <- dp$tname; idname <- dp$idname
  x <- as.data.frame(dp$data); if (isTRUE(dp$faster_mode)) x[x[, gname] == Inf, gname] <- 0
  w <- if (".w" %in% names(x)) x$.w else x$weights
  ids <- unique(x[, idname]); ci <- match(paste(x[, gname], x[, tname]), paste(group, tt)); k <- which(!is.na(ci))
  Matrix::sparseMatrix(i = match(x[, idname], ids)[k], j = ci[k], x = w[k], dims = c(length(ids), length(group)))
}
csa_did_summarize <- function(a, plan = NULL, bal = NULL, hull = FALSE) {
  ok <- !is.na(a$att); att <- a$att[ok]; group <- a$group[ok]; tt <- a$t[ok]; inf <- a$inffunc[, ok, drop = FALSE]
  glist <- sort(unique(group))
  if (hull && !isTRUE(a$DIDparams$panel)) {   # balanced panels (panel = TRUE): treated counts = did's cohort sizes, kept as did's
    X <- did_hull_x(a, group, tt); if (nrow(X) != nrow(inf)) stop("csa_hull_weights: influence-function rows do not match did's data")
    pg <- Matrix::colMeans(X)
    wif_of <- function(k, est, Spg) as.numeric(X[, k, drop = FALSE] %*% (att[k] - est)) / Spg
  } else {
    pp <- did_pg_parts(a)
    pg <- vapply(glist, function(gg) mean(pp$wi * (pp$gvar == gg)), numeric(1))[match(group, glist)]
    wif_of <- function(k, est, Spg) {   # did's wif %*% att in O(n) form
      spa <- sum(pg[k] * att[k])
      ag <- rowsum(att[k], group[k]); aG <- ag[match(pp$gvar, as.numeric(rownames(ag)))]; aG[is.na(aG)] <- 0
      nG <- tabulate(match(group[k], glist), length(glist))[match(pp$gvar, glist)]; nG[is.na(nG)] <- 0
      (pp$wi * aG - spa) / Spg - (pp$wi * nG - Spg) * spa / Spg^2
    }
  }
  e <- tt - group
  if (!is.null(bal)) { tl <- if (isTRUE(a$DIDparams$faster_mode)) a$DIDparams$time_periods else a$DIDparams$tlist; bal <- list(k = bal, Tmax = max(tt), Tmin = min(c(tl, glist))) }
  cs <- csa_cell_sets(e, group, plan, bal)
  agg1 <- function(k) {   # pooled cell set k, as did's per-e dynamic aggregation
    if (!length(k)) return(NULL)
    Spg <- sum(pg[k]); pge <- pg[k] / Spg; est <- sum(att[k] * pge)
    list(est = est, inf = as.numeric(inf[, k, drop = FALSE] %*% pge) + wif_of(k, est, Spg))
  }
  cv <- a$DIDparams$cluster_vector; n <- nrow(inf)
  se_of <- function(v) if (length(cv) == length(v)) sqrt(sum(rowsum(v, cv)^2)) / length(v) else sqrt(sum(v^2)) / length(v)
  if (is.null(plan)) { r <- agg1(cs$static); if (is.null(r)) return(list(est = c(static = NA_real_), se = c(static = NA_real_), nb = c(static = 0L), clustered = length(cv) == n))
    return(list(est = c(static = r$est), se = c(static = se_of(r$inf)), nb = c(static = 1L), clustered = length(cv) == n)) }
  if (identical(plan, "calendar")) { Bt <- Filter(Negate(is.null), lapply(cs$cal, agg1))   # per calendar t, then equal weights (aggte calendar)
    if (!length(Bt)) return(list(est = c(static = NA_real_), se = c(static = NA_real_), nb = c(static = 0L), clustered = length(cv) == n))
    v <- Reduce(`+`, lapply(Bt, `[[`, "inf")) / length(Bt)
    return(list(est = c(static = mean(vapply(Bt, `[[`, numeric(1), "est"))), se = c(static = se_of(v)), nb = c(static = length(Bt)), clustered = length(cv) == n)) }
  B <- lapply(cs$bins, agg1)
  R <- if (length(cs$R) && any(e[cs$R] != -1)) agg1(cs$R) else if (cs$ref_m1) list(est = 0, inf = 0) else NULL
  summ <- function(idx) {
    av <- idx[!vapply(B[idx], is.null, logical(1))]
    if (!length(av) || is.null(R)) return(c(NA_real_, NA_real_, 0))
    v <- Reduce(`+`, lapply(av, function(b) B[[b]]$inf - R$inf)) / length(av)
    c(mean(vapply(av, function(b) B[[b]]$est - R$est, numeric(1))), se_of(v), length(av))
  }
  po <- summ(plan$post_idx); pr <- summ(plan$pre_idx)
  list(est = c(post = po[1], pre = pr[1]), se = c(post = po[2], pre = pr[2]), nb = c(post = po[3], pre = pr[3]),
       thR = if (is.null(R)) NA_real_ else R$est, clustered = length(cv) == n)
}

# ---- 9. Composition-fixed Callaway-Sant'Anna cells for UNBALANCED panels -------------------
# did::att_gt with allow_unbalanced_panel = TRUE treats each (g,t) cell as a repeated cross-section,
# so units that enter or exit the panel change the control composition between g-1 and t. The
# cells below use only units observed in BOTH g-1 and t (within-unit long differences), with
# not-yet-treated (g > t) or never-treated controls, weights proportional to treated units per cell,
# and a Bayesian bootstrap over clusters for the SE. Covariates (xt) are not adjusted for here.
# These are Stata csdid's cells on unbalanced panels ("pair balanced"); csa_cells = "pairs" makes them the main CSA (Nov 2).
# Memory-lean implementation (Nov 1 2026, after two out-of-memory kernel panics): the earlier version stacked every
# (g,t) cell at the unit level (G x T x N rows; 13.5M rows for mksc.2022.1353) and copied that table, with a string-
# keyed cluster lookup, in each of the B bootstrap draws (~33 GB and ~45 min per spec). Every quantity csa_aggregate
# needs is linear in the cluster multipliers, so cells are stored as per-(g, t, cluster) sums, only for the event
# times the requested window uses (static: e >= 0). Cluster order of first appearance over ALL cells is kept, so the
# rexp() bootstrap draws, the point estimate and the SE match the stacked version up to floating-point summation order.
# ekeep (Nov 2): function(e) selecting the stored event times (default: window, or e >= 0). zero_ref: also store the zero
# cells at e = -1 (treated units observed at g-1, ATT 0) for an explicit reference set; they are added after all other cells,
# so the cluster order, and hence the draws, of the other cells is unchanged.
csa_cells <- function(d, control = "notyettreated", window = NULL, ekeep = NULL, zero_ref = FALSE) {
  periods <- sort(unique(d$t)); cohorts <- sort(unique(d[is.finite(g), g]))
  keep_e <- ekeep %||% (if (is.null(window)) function(e) e >= 0 else function(e) e >= window[1] & e <= window[2])
  out <- vector("list", 0); seen <- character(0); ncl_all <- uniqueN(d$cl); n_all <- 0L
  for (gg in cohorts) {
    base <- gg - 1; if (!(base %in% periods)) next
    db <- d[t == base, .(id, cl, g, y0 = y, w0 = w)]
    for (tt in periods[periods != base]) {
      e <- tt - gg
      keep <- keep_e(e)
      if (!keep && length(seen) >= ncl_all) next          # cell not used and cannot add a new cluster
      dt <- d[t == tt, .(id, y1 = y)]
      m <- merge(db, dt, by = "id"); if (!nrow(m)) next
      trm <- m$g == gg
      com <- if (control == "notyettreated") (!is.finite(m$g) | m$g > max(tt, gg)) else !is.finite(m$g)
      if (!any(trm) || !any(com)) next
      n_all <- n_all + 1L
      if (length(seen) < ncl_all) { u <- unique(as.character(c(m$cl[trm], m$cl[com]))); seen <- c(seen, u[!u %chin% seen]) }
      if (!keep) next
      x <- data.table(cl = c(m$cl[trm], m$cl[com]), dy = c(m$y1[trm] - m$y0[trm], m$y1[com] - m$y0[com]),
                      w0 = c(m$w0[trm], m$w0[com]), treated = c(rep(1L, sum(trm)), rep(0L, sum(com))))
      x <- x[, .(s1 = sum(w0 * dy * treated), s2 = sum(w0 * treated), s3 = sum(w0 * dy * (1 - treated)), s4 = sum(w0 * (1 - treated))), by = cl]
      x[, `:=`(g = gg, t = tt, e = e)]
      out[[length(out) + 1]] <- x
    }
  }
  if (zero_ref) for (gg in cohorts) {
    base <- gg - 1; if (!(base %in% periods)) next
    db <- d[t == base & g == gg, .(cl, w0 = w)]; if (!nrow(db)) next
    x <- db[, .(s1 = 0, s2 = sum(w0), s3 = 0, s4 = sum(w0)), by = cl][, `:=`(g = gg, t = base, e = -1)]
    u <- unique(as.character(x$cl)); seen <- c(seen, u[!u %chin% seen])
    out[[length(out) + 1]] <- x
  }
  cells <- rbindlist(out)
  if (nrow(cells)) { cells[, cli := match(as.character(cl), seen)]; cells[, cl := NULL] }
  list(cells = cells, cls = seen, n_all = n_all, Tmax = max(periods), Tmin = min(periods))
}
csa_aggregate <- function(cells, mult = NULL, plan = NULL, bal = NULL) {
  # cells: per-(g,t,e,cluster) sums from csa_cells; mult: cluster multipliers in csa_cells()$cls order (bootstrap);
  # plan / bal as in csa_summarize (cells weighted by their treated count). Returns csa_summarize's list.
  if (!nrow(cells)) return(NULL)
  set(cells, j = "m_", value = if (is.null(mult)) 1 else mult[cells$cli])
  att <- cells[, .(att = sum(m_ * s1) / sum(m_ * s2) - sum(m_ * s3) / sum(m_ * s4), ntr = sum(m_ * s2)), by = .(g, t, e)]
  csa_summarize(att$e, att$g, att$att, att$ntr, plan, bal)
}
CSA_MANUAL_B <- as.numeric(Sys.getenv("CSA_MANUAL_B", "999"))   # Bayesian bootstrap draws for the composition-fixed CSA SE (Hull: 999)
# All draws at once: cell sums are linear in the cluster multipliers, so the B draws are sparse (cells x clusters) times dense
# (clusters x B) products. The draws are rexp() in the same order as a sequential loop (column b = draw b), so results equal
# the loop version up to floating-point summation order. Returns a B x summaries matrix.
csa_aggregate_many <- function(cells, W, plan = NULL, bal = NULL) {
  ns <- if (is.list(plan)) 2L else 1L
  if (!nrow(cells)) return(matrix(NA_real_, ncol(W), ns))
  gt <- paste(cells$g, cells$t); k <- match(gt, unique(gt)); ku <- unique(data.table(k = k, g = cells$g, e = cells$e))[order(k)]
  M <- function(x) Matrix::sparseMatrix(i = k, j = cells$cli, x = x, dims = c(max(k), nrow(W)))
  A1 <- as.matrix(M(cells$s1) %*% W); A2 <- as.matrix(M(cells$s2) %*% W); A3 <- as.matrix(M(cells$s3) %*% W); A4 <- as.matrix(M(cells$s4) %*% W)
  csa_summarize(ku$e, ku$g, A1 / A2 - A3 / A4, A2, plan, bal)$est
}
csa_manual <- function(d, control = "notyettreated", plan = NULL, B = CSA_MANUAL_B, seed = 1, bal = NULL) {
  nm <- if (is.list(plan)) c("post", "pre") else "static"; na <- setNames(rep(NA_real_, length(nm)), nm)
  ek <- if (is.list(plan)) function(e) es_needed(e, plan) else function(e) e >= 0
  cc <- csa_cells(d, control, ekeep = ek, zero_ref = csa_need_zero(plan))
  if (!cc$n_all || !nrow(cc$cells)) return(list(est = na, se = na, nb = setNames(rep(0L, length(nm)), nm), thR = NA_real_, note = "csa_manual:no_cells"))
  bb <- if (is.null(bal)) NULL else list(k = bal, Tmax = cc$Tmax, Tmin = cc$Tmin)
  r0 <- csa_aggregate(cc$cells, plan = plan, bal = bb)
  set.seed(seed); W <- matrix(rexp(B * length(cc$cls)), length(cc$cls), B)
  bs <- csa_aggregate_many(cc$cells, W, plan, bb)
  list(est = setNames(r0$est[1, ], nm), se = setNames(apply(bs, 2, sd, na.rm = TRUE), nm), nb = r0$nb, thR = r0$thR[1], note = "csa_manual_balanced_cells")
}
is_unbalanced <- function(d) { Tn <- uniqueN(d$t); any(d[, .N, by = id]$N != Tn) }

# ---- Hull / did cohort-average DiD-averaging for unbalanced panels, without the influence-function matrix ---------------
# Replicates did::att_gt(allow_unbalanced_panel = TRUE, control_group = "notyettreated", base_period = "universal",
# est_method = "reg", no covariates) followed by aggte (simple, or dynamic averaged over an event window), using the unit and
# period rules of did 2.5.1's pre_process_did (read from the source, Nov 2): adopters after the last period are never-treated;
# with no never-treated units, periods from the last cohort's adoption on are dropped and that cohort is only a control; units
# treated in the first period are dropped. Cells are differences of cohort and comparison-group sample means (all observed
# rows); cohorts are weighted by their number of units (unit weight = mean of the unit's row weights, as aggte's
# stats::aggregate(mean); Nov 2, was the first row's weight, which differs only with time-varying weights, e.g. the frequency
# weights of mnsc.2023.4968 and 01423, where it caused draw-0 gaps of 2e-7). Used for specifications whose did influence
# function would not fit in memory (SE from a cluster Bayesian bootstrap) and by boot_cov.R for the bootstrap draws.
# Nov 2: control = "nevertreated" (never-treated comparison group only); zero cells at e = -1 (did's universal-base reference
# cells, ATT 0, cohort weight) for the reference effect; aggregation by csa_summarize (event structure, balance_e).
# wmode = "cell" (csa_cells = "rc_csdid", Nov 2): each cell is weighted by the (multiplier-weighted) rows of its cohort at g-1
# and at t, as Stata csdid's simple ATT without ivar, instead of did's cohort weight pg. wmode = "hull": by the cohort's rows at
# t (Hull's treated-count weights; csa_wmode).
csa_hull_prep <- function(d, cls = NULL, rc = FALSE, control = "notyettreated", wmode = "cohort") {   # rc = TRUE: repeated cross-section (did weights cohorts by rows)
  x <- as.data.table(d)[, .(id, t, g, y, w, cl)]
  if (is.null(cls)) cls <- unique(x$cl)
  tl <- sort(unique(x$t)); x[is.finite(g) & g > max(tl), g := Inf]
  if (control == "nevertreated" && all(is.finite(x$g))) stop("csa_nevertreated: no never-treated units")
  latest <- NA_real_
  if (all(is.finite(x$g))) { latest <- max(x$g); x <- x[t < latest] }
  fp <- min(x$t); x <- x[!(is.finite(g) & g <= fp)]
  per <- sort(unique(x$t)); gvals <- sort(unique(x[is.finite(g), g])); gi_all <- c(gvals, Inf)
  coh <- gvals[gvals > fp]; if (!is.na(latest)) coh <- coh[coh < latest]
  x[, k := match(cl, cls)]
  S <- x[, .(sy = sum(w * y), sw = sum(w), sw2 = sum(w^2)), by = .(gi = match(g, gi_all), p = match(t, per), k)]   # sw2: leverage
  CE <- CJ(ci = match(coh, gi_all), ti = seq_along(per))[, `:=`(g = gi_all[ci], t = per[ti])][, e := t - g][, bi := match(g - 1, per)][!is.na(bi) & t != g - 1]
  CE[, thr := pmax(t, g)][, k1 := vapply(thr, function(z) { i <- which(gi_all > z)[1]; if (is.na(i)) length(gi_all) + 1L else i }, integer(1))]
  if (control == "nevertreated") CE[, k1 := length(gi_all)]   # suffix sum from the never-treated row alone
  Z <- data.table(ci = match(coh, gi_all))[, g := gi_all[ci]][, bi := match(g - 1, per)][!is.na(bi)]
  PU <- if (rc) x[, .(w1 = w, k = k, gi = match(g, gi_all))] else x[, .(w1 = mean(w), k = k[1], gi = match(g[1], gi_all)), by = id]
  list(S = S, CE = CE, Z = Z, PU = PU, ngi = length(gi_all), nper = length(per), cls = cls, Tmax = max(per), Tmin = min(per), wmode = wmode)
}
csa_hull_eval <- function(o, m, plan = NULL, bal = NULL, cs = NULL) {
  CE <- o$CE; SY <- matrix(0, o$ngi + 1, o$nper); SW <- SY
  a <- o$S[, .(sy = sum(m[k] * sy), sw = sum(m[k] * sw)), by = .(gi, p)]
  SY[cbind(a$gi, a$p)] <- a$sy; SW[cbind(a$gi, a$p)] <- a$sw
  CY <- apply(SY, 2, function(z) rev(cumsum(rev(z)))); CW <- apply(SW, 2, function(z) rev(cumsum(rev(z))))   # suffix sums: later cohorts + never
  att <- (SY[cbind(CE$ci, CE$ti)] / SW[cbind(CE$ci, CE$ti)] - SY[cbind(CE$ci, CE$bi)] / SW[cbind(CE$ci, CE$bi)]) -
         (CY[cbind(CE$k1, CE$ti)] / CW[cbind(CE$k1, CE$ti)] - CY[cbind(CE$k1, CE$bi)] / CW[cbind(CE$k1, CE$bi)])
  nz <- nrow(o$Z)
  if (identical(o$wmode, "cell")) { pg <- SW[cbind(CE$ci, CE$ti)] + SW[cbind(CE$ci, CE$bi)]; pz <- 2 * SW[cbind(o$Z$ci, o$Z$bi)] }
  else if (identical(o$wmode, "hull")) { pg <- SW[cbind(CE$ci, CE$ti)]; pz <- SW[cbind(o$Z$ci, o$Z$bi)] }   # treated counts at t (zero cells: at g-1)
  else { pu <- o$PU[, .(s = sum(m[k] * w1)), by = gi]; v <- numeric(o$ngi + 1); v[pu$gi] <- pu$s; pg <- v[CE$ci]; pz <- v[o$Z$ci] }
  r <- csa_summarize(c(CE$e, rep(-1, nz)), c(CE$g, o$Z$g), c(att, rep(0, nz)), c(pg, pz), plan,
                     if (is.null(bal)) NULL else list(k = bal, Tmax = o$Tmax, Tmin = o$Tmin), cs = cs)
  list(est = r$est[1, ], nb = r$nb, thR = r$thR[1])
}
csa_hull_cs <- function(o, plan = NULL, bal = NULL)   # cell sets for csa_hull_eval, computed once for all bootstrap draws
  csa_cell_sets(c(o$CE$e, rep(-1, nrow(o$Z))), c(o$CE$g, o$Z$g), plan, if (is.null(bal)) NULL else list(k = bal, Tmax = o$Tmax, Tmin = o$Tmin))
csa_hull_lean <- function(d, plan = NULL, B = CSA_MANUAL_B, seed = 1, rc = FALSE, control = "notyettreated", bal = NULL, wmode = "cohort") {   # point estimates and cluster Bayesian bootstrap SEs
  o <- csa_hull_prep(d, rc = rc, control = control, wmode = wmode); nc <- length(o$cls); cs <- csa_hull_cs(o, plan, bal)
  r0 <- csa_hull_eval(o, rep(1, nc), plan, bal, cs)
  set.seed(seed); bs <- t(vapply(seq_len(B), function(b) csa_hull_eval(o, rexp(nc), plan, bal, cs)$est, numeric(length(r0$est))))
  if (length(r0$est) == 1) bs <- matrix(bs, ncol = 1)
  list(est = r0$est, se = setNames(apply(bs, 2, function(z) sd(z[is.finite(z)])), names(r0$est)), nb = r0$nb, thR = r0$thR)
}

# ---- did's Callaway-Sant'Anna WITH covariates, cell by cell, without the n x cells influence-function matrix (Nov 4) --------
# Replicates did::att_gt(faster_mode = TRUE) exactly as csa_static calls it (universal base period, est_method "reg" for panels
# and "dr" for repeated cross-sections with controls, allow_unbalanced_panel = TRUE, weights w, clusters cl) followed by the
# static summary of csa_did_summarize (Hull's treated-count weights) or aggte(type = "simple" / "calendar") (did's cohort
# shares), for specifications whose did run fails on size (influence function n x cells beyond the 2^31 sparse-matrix limit:
# mnsc.2022.03920, 205k rows x 16k cells) or memory (did's cells x cells covariance of all ATT(g,t): mnsc.2025.00954 T6/T8,
# ~60k cells). The rules are did 2.5.1's did_standardization, get_did_cohort_index, run_att_gt_estimation and run_DRDID (print
# with did:::name): rows with non-finite outcome, weight or covariates dropped; weights normalized to mean 1; cohorts after
# the last period are never-treated; with no never-treated units the periods from the last cohort's adoption on are dropped
# and that cohort is only a control (coerced to never-treated when control = "nevertreated"); units treated in the first
# period are dropped; a panel that is balanced AFTER these drops takes did's panel path (reg_did_panel on the long difference
# y_t - y_{g-1}, weights and covariates of the base period), otherwise every cell is a repeated cross-section of the rows at t
# and g-1 (reg_did_rc / drdid_rc, each row with its own weight and covariates); not-yet-treated controls are the never-
# treated plus the cohorts G > t. Per cell the same DRDID function is called with did's arguments and guards (overlap and
# rcond checks, estimator errors -> NA cell, as run_att_gt_estimation's tryCatch), and its influence function, scaled by
# n / n_cell and summed to the unit level for unbalanced panels as run_DRDID does, is accumulated into ONE length-n vector
# (n = did's units, or rows of a repeated cross-section) with the aggregation weights (treated analysis-weight counts at t,
# or did's cohort shares) plus the weight-estimation term, exactly as csa_did_summarize / compute.aggte. Only the cells of
# the static summary are computed (e >= 0; the balance_e rule; calendar = per-period pooling averaged equally). SE = sqrt of
# the sum of squared cluster sums of the influence function / n, did's getSE. Validated on 65 static controls specifications
# where did ran (output/csa_cells_check.csv, CSA_CELLS_CHECK=1 in run_spec.R): estimates and SEs agree with did's to 3e-12
# (7e-12 relative), including the NA-cell pattern; the did path itself is unchanged (identical to 15 digits on toy data).
# csa_did_prep: did_standardization and get_did_tensors for the cell routines (shared by the estimator csa_did_cells and the
# leverage csa_did_cells_lev, Nov 4). x is did's data after its drops; n = influence-function rows (units, or rows of a repeated
# cross-section); gu / cv = cohort and cluster per row of the influence function; MM = did's covariate matrix (intercept + xformla).
csa_did_prep <- function(dd, xf, control = "notyettreated", rc = FALSE) {
  x <- as.data.table(dd); xv <- all.vars(xf); cl_note <- ""
  if (!rc && x[, uniqueN(cl), by = id][, any(V1 > 1)]) { x <- copy(x); x[, cl := id]; cl_note <- ";csa_clustered_by_unit" }   # did's validate_args error; csa_static refits with unit clusters
  keep <- unique(c(if (!rc) "id", "t", "gnum", "y", "w", "cl", xv, if (".rid" %in% names(x)) ".rid")); x <- x[, ..keep]   # .rid: caller's row id (leverage checks)
  ok <- Reduce(`&`, lapply(setdiff(keep, "gnum"), function(v) { z <- x[[v]]; if (is.numeric(z)) is.finite(z) else !is.na(z) })); x <- x[ok]   # complete_finite_cases
  x[, .w := w / mean(w)]
  tl <- sort(unique(x$t)); x[gnum == 0 | gnum > max(tl), gnum := Inf]
  gl <- sort(unique(x$gnum)); latest <- NA_real_
  if (!any(is.infinite(gl))) {   # no never-treated units
    latest <- max(gl); x <- x[t < latest]; if (control == "nevertreated") x[gnum == latest, gnum := Inf]
    tl <- sort(unique(x$t)); gl <- sort(unique(x$gnum)); if (control != "nevertreated") gl <- gl[gl < latest]
  }
  fp <- tl[1]; gl <- gl[is.finite(gl) & gl > fp]
  tfp <- is.finite(x$gnum) & x$gnum <= fp
  if (any(tfp)) { x <- x[!tfp]; tl <- sort(unique(x$t)); gl <- sort(unique(x$gnum)); fp <- tl[1]; gl <- gl[is.finite(gl) & gl > fp]
    if (control != "nevertreated" && !any(is.infinite(x$gnum))) gl <- gl[gl < latest] }
  if (!length(gl)) stop("No valid groups. The variable in 'gname' should be expressed as the time a unit is first treated (0 if never-treated).")
  small <- x[, .N / length(tl), by = gnum][V1 < length(xv) + 5, gnum]
  if (control == "nevertreated" && Inf %in% small) stop("The never-treated group is too small to serve as a reliable control. Try setting `control_group = 'notyettreated'` to include not-yet-treated units as controls.")
  panel <- !rc && nrow(x) == uniqueN(x$id) * length(tl)   # check_balance after did's drops: did's panel path (2-period long differences)
  if (panel) setorder(x, t, gnum, id) else setorder(x, t, gnum)
  N <- nrow(x); ui <- if (rc) seq_len(N) else match(x$id, unique(x$id)); n <- if (rc) N else max(ui); first <- match(seq_len(n), ui)
  ti <- match(x$t, tl); cv <- x$cl[first]; gu <- x$gnum[first]   # cluster and cohort of each influence-function row (unit / row)
  MM <- if (length(xv)) model.matrix(xf, data = x) else NULL   # did's covariates_matrix / covariates_tensor (intercept + covariates)
  wi <- if (panel) x$.w[first] else as.numeric(rowsum(x$.w, ui)[, 1] / tabulate(ui, n))   # did's unit weight: first period, or the row mean (aggte's aggregate)
  pgc <- vapply(gl, function(g) mean(wi * (gu == g)), numeric(1))   # did's cohort shares
  pret <- vapply(gl, function(g) { i <- which(tl < g); if (length(i)) i[length(i)] else NA_integer_ }, integer(1))   # universal base period
  Y <- W <- R <- NULL
  if (panel) { Y <- matrix(NA_real_, n, length(tl)); Y[cbind(ui, ti)] <- x$y; W <- Y; W[cbind(ui, ti)] <- x$.w; R <- Y; R[cbind(ui, ti)] <- seq_len(N) }
  rows <- split(seq_len(N), factor(ti, levels = seq_along(tl)))
  list(x = x, xv = xv, tl = tl, gl = gl, pret = pret, panel = panel, N = N, ui = ui, n = n, cv = cv, gu = gu, MM = MM, wi = wi, pgc = pgc,
       rows = rows, Y = Y, W = W, R = R, cl_note = cl_note, control = control)
}
# One cell of did: run_att_gt_estimation + run_DRDID for cohort gl[gi] at period index k (NULL = NA cell). what = "if": did's
# estimate and influence function (ix: influence-function rows, fx: values, summed per unit for unbalanced panels; trt / trw:
# rows and weights of the cohort at k, the treated-count weight). what = "coef": the cell's coefficients on y (cix: rows of o$x,
# cval: values; the panel path's long difference puts +c on the row at k and -c on the row at the base period), from
# did_cell_coef without calling DRDID; the caller checks sum(cval * y) against the cell's estimate.
csa_did_cell <- function(o, gi, k, est_method = "reg", what = "if") {
  x <- o$x; g <- o$gl[gi]; p <- o$pret[gi]; cut <- o$tl[max(k, p)]; io <- is.null(o$MM); n <- o$n
  ctl <- function(gv) if (o$control == "nevertreated") is.infinite(gv) else gv > cut   # never-treated (Inf) included
  if (o$panel) {
    tr <- o$gu == g; co <- ctl(o$gu); v <- which(tr | co); if (!any(tr) || !any(co)) return(NULL)
    D <- as.integer(tr[v]); m <- min(p, k); X <- if (io) matrix(1, length(v), 1) else o$MM[o$R[v, m], , drop = FALSE]; w <- o$W[v, m]
    if (what == "coef") { cf <- did_cell_coef(est_method, D, X, w, panel = TRUE); return(list(cix = list(o$R[v, k], o$R[v, p]), cval = list(cf, -cf))) }
    if (est_method == "dr" && did:::overlap_check_fail(X, D, io)) return(NULL)
    if (did:::rcond_check_fail(X, D, io)) return(NULL)
    fn <- if (est_method == "reg") DRDID::reg_did_panel else DRDID::drdid_panel
    r <- tryCatch(fn(y1 = o$Y[v, k], y0 = o$Y[v, p], D = D, covariates = X, i.weights = w, boot = FALSE, inffunc = TRUE), error = function(e) NULL)
    if (is.null(r) || !is.finite(r$ATT)) return(NULL)
    return(list(att = r$ATT, ix = list(v), fx = list(as.numeric(r$att.inf.func) * n / length(v)), trt = v[tr[v]], trw = o$W[v[tr[v]], k]))
  }
  rp <- o$rows[[p]]; rt <- o$rows[[k]]; gp <- x$gnum[rp]; gt <- x$gnum[rt]
  sp <- rp[gp == g | ctl(gp)]; st <- rt[gt == g | ctl(gt)]; v <- c(sp, st)   # did's row order: base period first
  D <- as.integer(x$gnum[v] == g); post <- rep(c(0L, 1L), c(length(sp), length(st)))
  if (!any(D == 1) || !any(D == 0) || !sum(D * post) || !sum(D * (1 - post)) || !sum((1 - D) * post) || !sum((1 - D) * (1 - post))) return(NULL)
  X <- if (io) matrix(1, length(v), 1) else o$MM[v, , drop = FALSE]; w <- x$.w[v]
  if (what == "coef") return(list(cix = list(v), cval = list(did_cell_coef(est_method, D, X, w, panel = FALSE, post = post))))
  if (est_method == "dr" && did:::overlap_check_fail(X, D, io)) return(NULL)
  if (did:::rcond_check_fail(X, D, io)) return(NULL)
  fn <- if (est_method == "reg") DRDID::reg_did_rc else DRDID::drdid_rc
  r <- tryCatch(fn(y = x$y[v], post = post, D = D, covariates = X, i.weights = w, boot = FALSE, inffunc = TRUE), error = function(e) NULL)
  if (is.null(r) || !is.finite(r$ATT)) return(NULL)
  f <- as.numeric(r$att.inf.func) * n / length(v); np <- length(sp); tt <- st[gt[gt == g | ctl(gt)] == g]
  list(att = r$ATT, ix = list(o$ui[sp], o$ui[st]), fx = list(f[seq_len(np)], f[np + seq_len(length(st))]), trt = o$ui[tt], trw = x$.w[tt])   # unit sums: one row per unit and period
}
# The y-coefficients of one DRDID cell estimate (Hull's leverage, Nov 4): given X, D, post and the weights every estimate is
# c'y. Read from DRDID 1.3.0's sources (DRDID:::reg_did_panel, reg_did_rc, drdid_rc): the direct terms are weighted means of y
# over a subgroup; an outcome-regression term q'beta with beta = (X_S'W_S X_S)^-1 X_S'W_S y over subgroup S gives row j of S the
# coefficient w_j x_j'(X_S'W_S X_S)^-1 q. reg_did_panel: ATT = mean_w(dY | D=1) - q'beta_0 on the long difference dY, q the
# treated weighted mean of x. reg_did_rc: eta.treat.post - eta.treat.pre - q'(beta_01 - beta_00) (controls at t and at the base
# period), q over treated rows of both periods. drdid_rc: the propensity score (logit of D on X, DRDID's fastglm_fit) and its
# trimming do not depend on y; the four regressions (controls / treated at the base period / at t) enter with
# Q_c1 = q_cp - q_d, Q_c0 = q_d - q_cpre, Q_t1 = q_d - q_tp, Q_t0 = q_tpre - q_d (q_* = the normalized weighted means of x with
# DRDID's w.treat.*, w.cont.* and w.d weights), and the direct terms are the normalized w.treat.post, -w.treat.pre, -w.cont.post
# and +w.cont.pre weights. Weight scaling cancels everywhere, so did's .w are used as they are.
did_cell_coef <- function(est_method, D, X, w, panel = FALSE, post = NULL) {
  proj <- function(S, Q) { XS <- X[S, , drop = FALSE]; wS <- w[S]; as.numeric(XS %*% solve(crossprod(XS * wS, XS), Q)) * wS }
  cf <- numeric(length(D)); tr <- D == 1
  if (panel) {   # reg_did_panel (drdid_panel is not used by csa_static)
    if (est_method != "reg") stop("did_cell_coef: panel cells support est_method = reg only")
    q <- colSums(X[tr, , drop = FALSE] * w[tr]) / sum(w[tr]); cf[tr] <- w[tr] / sum(w[tr]); cf[!tr] <- -proj(!tr, q); return(cf)
  }
  Tp <- tr & post == 1; T0 <- tr & post == 0; Cp <- !tr & post == 1; C0 <- !tr & post == 0
  if (est_method == "reg") {   # reg_did_rc
    q <- colSums(X[tr, , drop = FALSE] * w[tr]) / sum(w[tr])
    cf[Tp] <- w[Tp] / sum(w[Tp]); cf[T0] <- -w[T0] / sum(w[T0]); cf[Cp] <- -proj(Cp, q); cf[C0] <- proj(C0, q); return(cf)
  }
  ps <- DRDID:::fastglm_fit(X, D, stats::binomial(), w / mean(w), method = 3)$fitted.values; ps <- pmin(ps, 1 - 1e-6)   # drdid_rc
  trim <- rep(TRUE, length(D)); trim[!tr] <- ps[!tr] < 0.995
  wtp <- trim * w * Tp; wt0 <- trim * w * T0; wcp <- trim * w * ps * Cp / (1 - ps); wc0 <- trim * w * ps * C0 / (1 - ps); wd <- trim * w * tr
  qm <- function(ww) colSums(X * ww) / sum(ww)
  q_tp <- qm(wtp); q_t0 <- qm(wt0); q_cp <- qm(wcp); q_c0 <- qm(wc0); q_d <- qm(wd)
  cf <- wtp / sum(wtp) - wt0 / sum(wt0) - wcp / sum(wcp) + wc0 / sum(wc0)
  cf[Cp] <- cf[Cp] + proj(Cp, q_cp - q_d); cf[C0] <- cf[C0] + proj(C0, q_d - q_c0); cf[Tp] <- cf[Tp] + proj(Tp, q_d - q_tp); cf[T0] <- cf[T0] + proj(T0, q_t0 - q_d)
  cf
}
csa_did_cells <- function(dd, xf, control = "notyettreated", rc = FALSE, est_method = "reg", plan = NULL, bal = NULL, hull = TRUE, aggte_na = FALSE) {
  if (!is.null(plan) && !identical(plan, "calendar")) stop("csa_did_cells: static summaries only (simple or calendar)")
  if (!est_method %in% c("reg", "dr")) stop("csa_did_cells: est_method must be reg or dr")
  o <- csa_did_prep(dd, xf, control, rc); tl <- o$tl; gl <- o$gl; n <- o$n; gu <- o$gu; wi <- o$wi; pgc <- o$pgc; cv <- o$cv
  wmode <- if (hull && !o$panel) "hull" else "cohort"   # csa_did_summarize: treated counts unless did's panel path
  bb <- if (is.null(bal)) NULL else list(k = bal, Tmax = max(tl), Tmin = tl[1])   # csa_did_summarize's balance_e rule (Tmax = last period)
  u <- numeric(n); z <- u; s <- u; catt <- numeric(0); cg <- integer(0); cpg <- numeric(0); nc <- 0L; nna <- 0L; last_ok <- FALSE
  fin <- function() {   # pooled set of the accumulated cells: csa_did_summarize's agg1 / compute.aggte's simple
    if (!length(catt)) return(NULL)
    Spg <- sum(cpg); spa <- sum(cpg * catt); est <- spa / Spg
    wif <- if (wmode == "hull") (z - est * s) / Spg else {   # did's wif %*% att in O(n) form
      aG <- numeric(length(gl)); a1 <- rowsum(catt, cg); aG[as.integer(rownames(a1))] <- a1[, 1]; nG <- tabulate(cg, length(gl))
      gi_u <- match(gu, gl); aGu <- aG[gi_u]; aGu[is.na(aGu)] <- 0; nGu <- nG[gi_u]; nGu[is.na(nGu)] <- 0
      (wi * aGu - spa) / Spg - (wi * nGu - Spg) * spa / Spg^2 }
    list(est = est, v = u / Spg + wif)
  }
  Vs <- numeric(n); Es <- 0; nT <- 0L
  for (k in seq_along(tl)) {
    for (gi in seq_along(gl)) {
      g <- gl[gi]; e <- tl[k] - g; if (e < 0 || is.na(o$pret[gi])) next
      if (!is.null(bb) && !((bb$Tmax - g >= bb$k) && e <= bb$k && e >= bb$k - bb$Tmax + bb$Tmin)) next
      nc <- nc + 1L; r <- csa_did_cell(o, gi, k, est_method)
      if (is.null(r)) { nna <- nna + 1L; next }
      if (k == length(tl)) last_ok <- TRUE
      pg <- if (wmode == "hull") sum(r$trw) / n else pgc[gi]
      for (j in seq_along(r$ix)) u[r$ix[[j]]] <- u[r$ix[[j]]] + pg * r$fx[[j]]
      if (wmode == "hull") { z[r$trt] <- z[r$trt] + r$att * r$trw; s[r$trt] <- s[r$trt] + r$trw }
      catt <- c(catt, r$att); cg <- c(cg, gi); cpg <- c(cpg, pg)
    }
    if (identical(plan, "calendar")) { f <- fin(); if (!is.null(f)) { Vs <- Vs + f$v; Es <- Es + f$est; nT <- nT + 1L }
      u[] <- 0; z[] <- 0; s[] <- 0; catt <- numeric(0); cg <- integer(0); cpg <- numeric(0) }
  }
  if (!is.null(bb) && !last_ok) stop("csa_did_cells: balance_e with no valid cell in the last period (did's Tmax would differ)")
  f <- if (identical(plan, "calendar")) { if (nT) list(est = Es / nT, v = Vs / nT) else NULL } else fin()
  est <- NA_real_; se <- NA_real_
  if (!is.null(f)) { est <- f$est; se <- sqrt(sum(rowsum(f$v, cv)[, 1]^2)) / n   # did's getSE, clustered by cl
    if (aggte_na && isTRUE(se <= sqrt(.Machine$double.eps) * 10)) se <- NA_real_ }   # aggte's small-SE rule on the did-weights route
  list(est = est, se = se, note = paste0(o$cl_note, csa_na_note0(nna, nc, length(o$xv) > 0, est)), n = n, panel = o$panel, ncells = nc, nna = nna)
}
# Hull's leverage of did's covariate estimator (Nov 4; csa_leverage): theta = sum_j a_j y_j with a = sum_c lambda_c c_c, c_c the
# cell's y-coefficients (did_cell_coef) on the rows of did's data and lambda_c the cell's weight in the reported summary
# (csa_cell_lambda: pooled static / calendar / event bins minus the reference, with the same pg as the estimator: treated
# counts at t for Hull's weights, did's cohort shares on did's panel path). Two passes: the cells the plan needs (zero cells at
# the base period included, with their weight and no coefficients) give the estimates, the NA pattern and lambda; then the
# coefficients of the cells with lambda != 0, each checked against its estimate (sum(c_c y) = ATT_c to 1e-8). Returns G_eff,
# L_max (leverage_screen on did's rows and clusters; dropped rows carry a = 0) and check = sum(a y), equal to the estimate.
csa_did_cells_lev <- function(dd, xf, control = "notyettreated", rc = FALSE, est_method = "reg", plan = NULL, bal = NULL, hull = TRUE, keep_a = FALSE) {
  o <- csa_did_prep(dd, xf, control, rc); tl <- o$tl; gl <- o$gl; n <- o$n; x <- o$x
  wmode <- if (hull && !o$panel) "hull" else "cohort"
  need <- if (is.list(plan)) function(e) es_needed(e, plan) else function(e) e >= 0
  bb <- if (is.null(bal)) NULL else list(k = bal, Tmax = max(tl), Tmin = tl[1])
  ce <- numeric(0); cg <- numeric(0); ca <- numeric(0); cp <- numeric(0); cgi <- integer(0); ck <- integer(0); last_ok <- FALSE
  for (k in seq_along(tl)) for (gi in seq_along(gl)) {   # pass 1: did's cells the summary uses
    g <- gl[gi]; p <- o$pret[gi]; if (is.na(p)) next
    e <- tl[k] - g; if (!need(e)) next
    if (!is.null(bb) && !((bb$Tmax - g >= bb$k) && e <= bb$k && e >= bb$k - bb$Tmax + bb$Tmin)) next
    if (k == p) {   # did's base-period cell: estimate 0, no influence on y, its weight counts in pooled sets (zero cells)
      att <- 0; pg <- if (wmode == "hull") { r0 <- o$rows[[p]]; sum(x$.w[r0[x$gnum[r0] == g]]) / n } else o$pgc[gi]
    } else {
      r <- csa_did_cell(o, gi, k, est_method)
      att <- if (is.null(r)) NA_real_ else r$att; pg <- if (is.null(r)) NA_real_ else if (wmode == "hull") sum(r$trw) / n else o$pgc[gi]
      if (!is.null(r) && k == length(tl)) last_ok <- TRUE
    }
    ce <- c(ce, e); cg <- c(cg, g); ca <- c(ca, att); cp <- c(cp, pg); cgi <- c(cgi, gi); ck <- c(ck, k)
  }
  if (!is.null(bb) && !last_ok) stop("csa_did_cells_lev: balance_e with no valid cell in the last period (did's Tmax would differ)")
  lam <- csa_cell_lambda(ce, cg, ca, cp, plan, bb); if (is.null(lam)) return(NULL)
  a <- numeric(o$N)
  for (i in which(lam != 0 & is.finite(ca) & ck != o$pret[cgi])) {   # pass 2: coefficients of the cells in the summary
    r <- csa_did_cell(o, cgi[i], ck[i], est_method, what = "coef")
    s <- sum(vapply(seq_along(r$cix), function(j) sum(r$cval[[j]] * x$y[r$cix[[j]]]), numeric(1)))
    if (!isTRUE(abs(s - ca[i]) <= 1e-8 * (1 + abs(ca[i])))) stop(sprintf("csa_did_cells_lev: cell (%s, %s) coefficients give %.10g, did %.10g", cg[i], tl[ck[i]], s, ca[i]))
    for (j in seq_along(r$cix)) a[r$cix[[j]]] <- a[r$cix[[j]]] + lam[i] * r$cval[[j]]
  }
  c(leverage_screen(a, x$cl)[c("G_eff", "L_max")], list(check = sum(a * x$y)), if (keep_a) list(a = data.table(rid = x$.rid %||% NA_real_, a = a)))   # keep_a: per-row weights (finite-difference checks)
}

# ---- 10. Leverage of the modern estimators (Hull App. B, eq. 2; team-lead Nov 2) ------------------------------------------
# Hull retains a TWFE-modern pair only if BOTH estimators have G_eff >= 10 and L_max <= 0.25. Each estimate (static, or the
# post summary of an event study, as for TWFE) is written as theta = sum_j a_j Y_j with the estimator's own weights held fixed
# (cohort shares, cell counts, analysis weights). lev_check_* = sum_j a_j Y_j - estimate verifies the weights (outcome-SD units).
# CSA with covariates (did's outcome regression with xt or controls): csa_did_cells_lev since Nov 4 (was NA, noted).
# Cell weights lambda_c: the coefficient of each cell ATT in the reported summary, from the same cell sets as csa_summarize
# (bins pooled with their weights, minus theta_R, available bins averaged equally; simple; calendar). Zero cells carry no Y.
csa_cell_lambda <- function(e, g, A, P, plan = NULL, bal = NULL, cs = NULL) {
  ok <- is.finite(A) & is.finite(P) & P > 0; lam <- numeric(length(e)); cs <- cs %||% csa_cell_sets(e, g, plan, bal)
  addpool <- function(k, s) { k <- k[ok[k]]; if (length(k)) lam[k] <<- lam[k] + s * P[k] / sum(P[k]); length(k) > 0 }
  if (is.null(plan)) return(if (addpool(cs$static, 1)) lam else NULL)
  if (identical(plan, "calendar")) { av <- Filter(function(k) any(ok[k]), cs$cal); if (!length(av)) return(NULL); for (k in av) addpool(k, 1 / length(av)); return(lam) }
  av <- Filter(function(b) any(ok[cs$bins[[b]]]), plan$post_idx); if (!length(av)) return(NULL)
  for (b in av) addpool(cs$bins[[b]], 1 / length(av))
  if (length(cs$R) && any(e[cs$R] != -1) && !addpool(cs$R, -1)) return(NULL)   # minus theta_R (0 by construction for -1 alone)
  lam
}
# Did's cohort-average cells (unbalanced and RC did paths, lean replica, rc_csdid, balanced did with time-invariant weights):
# ATT(g,t) = Ybar(g,t) - Ybar(g,g-1) - [Ybar(C,t) - Ybar(C,g-1)], so every row in cohort-period (gi, p) has a_j = w_j F[gi, p].
# Cluster sums of a_j^2 follow from the per-(gi, p, cluster) sums of w^2 without materializing rows.
csa_hull_lev <- function(o, plan = NULL, bal = NULL) {
  CE <- o$CE; nz <- nrow(o$Z); m <- rep(1, length(o$cls)); SY <- matrix(0, o$ngi + 1, o$nper); SW <- SY
  a <- o$S[, .(sy = sum(m[k] * sy), sw = sum(m[k] * sw)), by = .(gi, p)]; SY[cbind(a$gi, a$p)] <- a$sy; SW[cbind(a$gi, a$p)] <- a$sw
  CY <- apply(SY, 2, function(z) rev(cumsum(rev(z)))); CW <- apply(SW, 2, function(z) rev(cumsum(rev(z))))
  att <- (SY[cbind(CE$ci, CE$ti)] / SW[cbind(CE$ci, CE$ti)] - SY[cbind(CE$ci, CE$bi)] / SW[cbind(CE$ci, CE$bi)]) -
         (CY[cbind(CE$k1, CE$ti)] / CW[cbind(CE$k1, CE$ti)] - CY[cbind(CE$k1, CE$bi)] / CW[cbind(CE$k1, CE$bi)])
  if (identical(o$wmode, "cell")) { pg <- SW[cbind(CE$ci, CE$ti)] + SW[cbind(CE$ci, CE$bi)]; pz <- 2 * SW[cbind(o$Z$ci, o$Z$bi)] }
  else if (identical(o$wmode, "hull")) { pg <- SW[cbind(CE$ci, CE$ti)]; pz <- SW[cbind(o$Z$ci, o$Z$bi)] }
  else { pu <- o$PU[, .(s = sum(w1)), by = gi]; v <- numeric(o$ngi + 1); v[pu$gi] <- pu$s; pg <- v[CE$ci]; pz <- v[o$Z$ci] }
  bb <- if (is.null(bal)) NULL else list(k = bal, Tmax = o$Tmax, Tmin = o$Tmin)
  lam <- csa_cell_lambda(c(CE$e, rep(-1, nz)), c(CE$g, o$Z$g), c(att, rep(0, nz)), c(pg, pz), plan, bb)
  if (is.null(lam)) return(NULL)
  lam <- lam[seq_len(nrow(CE))]; u <- which(lam != 0 & is.finite(att))
  acc <- function(M, i, j, x) { z <- data.table(i = i, j = j, x = x)[, .(x = sum(x)), by = .(i, j)]; M[cbind(z$i, z$j)] <- M[cbind(z$i, z$j)] + z$x; M }
  F <- matrix(0, o$ngi + 1, o$nper)
  F <- acc(F, CE$ci[u], CE$ti[u], lam[u] / SW[cbind(CE$ci[u], CE$ti[u])]); F <- acc(F, CE$ci[u], CE$bi[u], -lam[u] / SW[cbind(CE$ci[u], CE$bi[u])])
  G <- matrix(0, o$ngi + 1, o$nper)   # comparison group of a cell = cohorts from k1 on (later cohorts and never-treated)
  G <- acc(G, CE$k1[u], CE$ti[u], -lam[u] / CW[cbind(CE$k1[u], CE$ti[u])]); G <- acc(G, CE$k1[u], CE$bi[u], lam[u] / CW[cbind(CE$k1[u], CE$bi[u])])
  F <- F + apply(G, 2, cumsum)
  f <- F[cbind(o$S$gi, o$S$p)]; L <- tapply(f^2 * o$S$sw2, o$S$k, sum); L <- L / sum(L)
  list(G_eff = 1 / sum(L^2), L_max = max(L), check = sum(f * o$S$sy))
}
# Composition-fixed (pairs) cells: unit long differences, so a_j accumulates over the cells each unit enters.
csa_pairs_lev <- function(d, control = "notyettreated", plan = NULL, bal = NULL) {
  ek <- if (is.list(plan)) function(e) es_needed(e, plan) else function(e) e >= 0
  cc <- csa_cells(d, control, ekeep = ek, zero_ref = csa_need_zero(plan)); if (!nrow(cc$cells)) return(NULL)
  at <- cc$cells[, .(att = sum(s1) / sum(s2) - sum(s3) / sum(s4), ntr = sum(s2)), by = .(g, t, e)]
  lam <- csa_cell_lambda(at$e, at$g, at$att, at$ntr, plan, if (is.null(bal)) NULL else list(k = bal, Tmax = cc$Tmax, Tmin = cc$Tmin))
  if (is.null(lam)) return(NULL)
  di <- data.table(id = d$id, t = d$t, g = d$g, w = d$w, row = seq_len(nrow(d))); a <- numeric(nrow(d))
  for (r in which(lam != 0 & at$t != at$g - 1 & is.finite(at$att))) {   # real cells only (t != g - 1)
    gg <- at$g[r]; tt <- at$t[r]
    m <- merge(di[t == gg - 1, .(id, g, w0 = w, rb = row)], di[t == tt, .(id, rt = row)], by = "id")
    trm <- m$g == gg; com <- if (control == "notyettreated") (!is.finite(m$g) | m$g > max(tt, gg)) else !is.finite(m$g)
    x1 <- lam[r] * m$w0[trm] / sum(m$w0[trm]); x0 <- lam[r] * m$w0[com] / sum(m$w0[com])
    a[m$rt[trm]] <- a[m$rt[trm]] + x1; a[m$rb[trm]] <- a[m$rb[trm]] - x1; a[m$rt[com]] <- a[m$rt[com]] - x0; a[m$rb[com]] <- a[m$rb[com]] + x0
  }
  c(leverage_screen(a, d$cl)[c("G_eff", "L_max")], list(check = sum(a * d$y)))
}
csa_leverage <- function(d, xt = NULL, ctrl = NULL, plan = NULL, opt = list()) {
  d <- csa_never_post(d); control <- opt$control %||% "notyettreated"; bal <- opt$balance_e
  cells <- opt$cells %||% (if (isTRUE(opt$pairs)) "pairs" else ""); rcx <- anyDuplicated(d, by = c("id", "t")) > 0; unbal <- !rcx && is_unbalanced(d)
  if (cells == "pairs" || (cells == "" && !rcx && CSA_UNBAL == "fixed" && is_unbalanced(d))) return(csa_pairs_lev(d, control, plan, bal))
  if (cells == "rc_csdid") return(csa_hull_lev(csa_hull_prep(d, rc = TRUE, control = control, wmode = "cell"), plan, bal))
  if (length(ctrl) || (!is.null(xt) && length(attr(terms(expand_xt(copy(d), xt)$xf), "term.labels")))) {   # did's covariate estimator, cell by cell (Nov 4; was NA: lev_csa_na_controls / lev_csa_na_covariates)
    p <- csa_did_data(d, xt, ctrl)
    hull <- !identical(opt$weights, "did") && (is.list(plan) || rcx || unbal)   # csa_event: treated counts unless did's weights; csa_static: only off did's panel path
    return(csa_did_cells_lev(p$dd, p$xf, control, rc = p$rc, est_method = if (p$rc && length(ctrl)) "dr" else "reg", plan = plan, bal = bal, hull = hull))
  }
  csa_hull_lev(csa_hull_prep(d, rc = rcx, control = control, wmode = csa_wmode(opt, rcx, unbal)), plan, bal)
}
# Imputation weights (BJS 2024): theta = sum_U omega_j (Y_j - Yhat_j(0)) over the supported rows U that the reported summary
# averages (treated rows: static, or the post bins averaged equally; an explicit reference adds its rows with weight -1/W_R).
# With Yhat(0) = x'beta_hat from the untreated-sample regression, a_j = omega_j + v_j with v_i = -w_i x_i'gamma on untreated
# rows and (X0'W0X0) gamma = X_U'omega. The system is solved by conjugate gradient with a Jacobi preconditioner, matrix-free
# over the fixed-effect dimensions (id, t, t^xt) and the controls, with sparse level sums: no FE matrix is formed (mnsc.2025.03238's
# 218k FE columns stay sparse). (Block coordinate descent, the plain alternating projections, stalled at 1e-5 on poorly
# connected designs and did not converge with controls, Nov 2.)
# Tolerance 1e-10 (was 1e-14 until Nov 3: unattainable in double precision on large designs; CG reached ~1e-9 and then diverged,
# p'Ap < 0 -> NaN -> lev_bjs_error, so 80 of 361 imputation comparisons fell back to the TWFE-only screen; code review, Nov 3).
# A non-positive or non-finite curvature now stops the iteration with conv = FALSE instead of producing NaN.
BJS_LEV_TOL <- as.numeric(Sys.getenv("BJS_LEV_TOL", "1e-10")); BJS_LEV_MAXIT <- as.numeric(Sys.getenv("BJS_LEV_MAXIT", "3000"))   # converges in < 100 iterations when consistent
bjs_leverage <- function(dr, xt = NULL, ctrl = NULL, S = NULL, tol = BJS_LEV_TOL, maxit = BJS_LEV_MAXIT) {
  m0 <- feols(as.formula(paste0("y ~ ", rhs_ctrl(ctrl), " | ", fe_str(xt))), data = dr[D == 0], weights = ~w, warn = FALSE, notes = FALSE, fixef.keep_names = TRUE)
  sup <- is.finite(predict(m0, newdata = dr)); w <- dr$w; om <- numeric(nrow(dr))
  if (is.null(S)) { k <- which(dr$D == 1 & sup); if (!length(k)) return(NULL); om[k] <- w[k] / sum(w[k]) }
  else {
    av <- Filter(function(b) any(dr$ebin == b & sup), S$post_idx); if (!length(av)) return(NULL)
    for (b in av) { k <- which(dr$ebin == b & sup); om[k] <- om[k] + w[k] / sum(w[k]) / length(av) }
    if (any(dr$eref & dr$erel != -1)) { k <- which(dr$eref & sup); if (!length(k)) return(NULL); om[k] <- om[k] - w[k] / sum(w[k]) }
  }
  i0 <- which(dr$D == 0); w0 <- w[i0]; n0 <- length(i0); nzr <- which(om != 0)
  fl <- c(list(dr$id, dr$t), lapply(xt, function(v) paste(dr$t, dr[[v]]))); fl <- lapply(fl, function(f) match(f, unique(f)))
  f0 <- lapply(fl, function(f) f[i0]); nl <- vapply(fl, max, numeric(1))
  M <- lapply(seq_along(fl), function(k) Matrix::sparseMatrix(i = f0[[k]], j = seq_len(n0), x = w0, dims = c(nl[k], n0)))   # weighted level sums
  C0 <- if (length(ctrl)) as.matrix(dr[i0, ..ctrl]) else matrix(0, n0, 0)
  bvec <- c(unlist(lapply(fl, function(f) { v <- numeric(max(f)); s <- rowsum(om[nzr], f[nzr]); v[as.integer(rownames(s))] <- s; v })),
            if (ncol(C0)) colSums(as.matrix(dr[nzr, ..ctrl]) * om[nzr]) else numeric(0))
  idx <- split(seq_len(sum(nl)), rep(seq_along(nl), nl)); ic <- sum(nl) + seq_len(ncol(C0))
  Xv <- function(x) { f <- if (ncol(C0)) as.numeric(C0 %*% x[ic]) else numeric(n0); for (k in seq_along(fl)) f <- f + x[idx[[k]]][f0[[k]]]; f }
  Atv <- function(f) c(unlist(lapply(M, function(Mk) as.numeric(Mk %*% f))), if (ncol(C0)) as.numeric(crossprod(C0, w0 * f)) else numeric(0))
  dg <- c(unlist(lapply(M, function(Mk) as.numeric(Matrix::rowSums(Mk)))), if (ncol(C0)) colSums(C0^2 * w0) else numeric(0))
  act <- dg > 0; pinv <- ifelse(act, 1 / dg, 0); bvec[!act] <- 0   # levels without untreated rows carry no weight
  x <- numeric(length(bvec)); r <- bvec; z <- pinv * r; p <- z; rz <- sum(r * z); bn <- max(abs(bvec)); conv <- FALSE; it <- 0
  while (it < maxit) {
    it <- it + 1; Ap <- Atv(Xv(p)); Ap[!act] <- 0; pAp <- sum(p * Ap)
    if (!is.finite(pAp) || pAp <= 0) break   # loss of positive curvature: stop (conv stays FALSE) rather than divide into NaN
    al <- rz / pAp; x <- x + al * p; r <- r - al * Ap
    if (max(abs(r)) <= tol * bn) { conv <- TRUE; break }
    z <- pinv * r; rz1 <- sum(r * z); p <- z + (rz1 / rz) * p; rz <- rz1
  }
  a <- om; a[i0] <- a[i0] - w0 * Xv(x)
  c(leverage_screen(a, dr$cl)[c("G_eff", "L_max")], list(check = sum(a * dr$y), iter = it, conv = conv))
}
# Columns G_eff_csa, L_max_csa, G_eff_bjs, L_max_bjs, lev_check_csa, lev_check_bjs, lev_note (MODERN_LEVERAGE=0 skips them)
modern_leverage <- function(d, dr, xt, ctrl, plan, S, opt, est_csa, est_bjs) {
  if (Sys.getenv("MODERN_LEVERAGE", "1") != "1") return(data.table(lev_note = "lev_skipped"))
  err <- function(tag) function(e) list(note = paste0(tag, ":", substr(conditionMessage(e), 1, 60)))
  lc <- if (isTRUE(is.finite(est_csa))) tryCatch(csa_leverage(d, xt, ctrl, plan, opt), error = err("lev_csa_error")) else list(note = "lev_csa_na_estimate")
  lb <- if (isTRUE(is.finite(est_bjs))) tryCatch(bjs_leverage(dr, xt, ctrl, S), error = err("lev_bjs_error")) else list(note = "lev_bjs_na_estimate")
  if (is.null(lc)) lc <- list(note = "lev_csa_no_cells"); if (is.null(lb)) lb <- list(note = "lev_bjs_no_rows")
  # no convergence = inconsistent system: some imputed Y(0) are not identified by the untreated rows (e.g. a repeated cross-section
  # whose t^xt cells are not connected, mnsc.2024.04716 F2A) and depend on fixest's FE normalization; the weights are left NA
  if (isFALSE(lb$conv)) lb <- list(note = sprintf("lev_bjs_inconsistent:%d_iter", lb$iter))
  data.table(G_eff_csa = lc$G_eff %||% NA_real_, L_max_csa = lc$L_max %||% NA_real_, G_eff_bjs = lb$G_eff %||% NA_real_, L_max_bjs = lb$L_max %||% NA_real_,
             lev_check_csa = (lc$check %||% NA_real_) - est_csa, lev_check_bjs = (lb$check %||% NA_real_) - est_bjs,
             lev_bjs_iter = lb$iter %||% NA_integer_, lev_note = paste(c(lc$note, lb$note), collapse = ";"))
}
