# Event-study structure of a published specification (Nov 2). Hull (2026, fn. 10 and App. B) preserves each specification's
# original bins and reference-period normalization; the spec JSON records them in `event_structure`:
#   "event_structure": {
#     "bins":         [[-8,-8], ..., [-2,-2], [0,0], [1,4], [5,null]],  one indicator per bin in the published regression;
#                                                                        null = open end (e.g. [5,null] is "5 and later")
#     "ref":          [[-1,-1]],         omitted bin(s); several intervals are pooled into one reference
#     "uncovered":    "ref" | "drop",    relative times of ever-treated units in no bin and no ref: pooled with the reference
#                                        (all indicators zero, as when the authors code dummies only inside a window) or
#                                        dropped from the sample for all estimators (as when the authors trim the window)
#     "post_summary": [[0,0], [1,4]],    bins averaged with equal weight for the post-treatment summary (Hull: available
#                                        post-treatment coefficients over the common supported window); subset of bins
#     "pre_summary":  [[-8,-8], ...],    likewise for the pretreatment summary ([] if none)
#     "source":       authors' code file and line, and how they define event time
#     "verified":     what was reproduced (e.g. "fixest reproduces the 11 published coefficients, max abs diff 4.7e-08")
#   }
# Relative time is rel = t - g in the pipeline's period index (0 = first treated period); never-treated units have no rel
# and all indicators zero. Optional spec field event_time_authors_var (Nov 2): a data column with the authors' own event-time
# index (e.g. mnsc.2022.4394's row count j that skips panel gaps); when present (column e_auth in d), rows of ever-treated
# units are assigned to bins and ref by it (calendar rel where it is NA). TWFE, imputation and leverage use this row coding
# (erel); DiD-averaging keeps calendar rel = t - g, because its cells are (g,t) cells, with the same bin boundaries.
# Specs without event_structure keep the legacy rule (ref -1, single-period bins in
# [pre_min, post_max], endpoint bins beyond), returned by es_legacy().
# Internal value uncovered = "legacy" (Nov 2, es_legacy() with pre_min >= 0 only): the legacy coding put every pre-period in
# the TWFE reference (relb = max(rel, -1)) while DiD-averaging and imputation kept -1 as their only reference. Uncovered
# times then have all TWFE indicators zero but are not part of the modern estimators' reference set.
`%||%` <- function(a, b) if (is.null(a)) b else a

es_mat <- function(x) {
  if (is.null(x) || length(x) == 0) return(matrix(numeric(0), ncol = 2))
  m <- if (is.matrix(x)) x else do.call(rbind, lapply(x, function(v) as.numeric(vapply(v, function(z) if (is.null(z)) NA_real_ else as.numeric(z), numeric(1)))))
  m <- matrix(as.numeric(m), ncol = 2); m[is.na(m[, 1]), 1] <- -Inf; m[is.na(m[, 2]), 2] <- Inf
  if (any(m[, 1] > m[, 2])) stop("event_structure: interval with lo > hi")
  m
}
es_parse <- function(es) {
  if (is.list(es) && !is.null(es$post_idx)) return(es)   # already parsed
  S <- list(bins = es_mat(es$bins), ref = es_mat(es$ref), uncovered = es$uncovered %||% "ref",
            post = es_mat(es$post_summary), pre = es_mat(es$pre_summary))
  if (!S$uncovered %in% c("ref", "drop", "legacy")) stop("event_structure$uncovered must be 'ref' or 'drop'")
  if (!nrow(S$bins) || !nrow(S$ref)) stop("event_structure needs bins and ref")
  ov <- function(a, b) a[1] <= b[2] && b[1] <= a[2]
  all_iv <- rbind(S$bins, S$ref)
  for (i in seq_len(nrow(all_iv))) for (j in seq_len(nrow(all_iv))) if (i < j && ov(all_iv[i, ], all_iv[j, ])) stop("event_structure: overlapping intervals")
  key <- function(m) paste(m[, 1], m[, 2])
  S$post_idx <- match(key(S$post), key(S$bins)); S$pre_idx <- match(key(S$pre), key(S$bins))
  if (anyNA(S$post_idx) || anyNA(S$pre_idx)) stop("event_structure: summary intervals must be bins")
  # TRUE when the modern estimators' reference set is -1 alone (Hull fn. 10: no reference effect to subtract): ref is [-1,-1]
  # and no relative time can be uncovered-and-pooled (uncovered != "ref", or bins and ref cover every integer)
  S$ref_std <- nrow(S$ref) == 1 && all(S$ref[1, ] == -1) && (S$uncovered != "ref" || es_covers_all(all_iv))
  S
}
es_covers_all <- function(m) {   # do the intervals cover every integer?
  m <- m[order(m[, 1]), , drop = FALSE]
  if (m[1, 1] != -Inf) return(FALSE)
  hi <- m[1, 2]
  for (i in seq_len(nrow(m))[-1]) { if (m[i, 1] > hi + 1) return(FALSE); hi <- max(hi, m[i, 2]) }
  hi == Inf
}
es_legacy <- function(pre_min = -5L, post_max = 5L) {
  pre <- if (pre_min <= -2) lapply(seq(pre_min, -2), function(k) c(k, k)) else list()
  post <- lapply(seq(0, post_max), function(k) c(k, k))
  lo <- if (pre_min - 1 <= -2) list(c(NA, pre_min - 1)) else list()   # lower endpoint bin; none when pre_min >= 0 (see above)
  list(bins = c(lo, pre, post, list(c(post_max + 1, NA))), ref = list(c(-1, -1)), uncovered = if (length(lo)) "ref" else "legacy",
       post_summary = post, pre_summary = pre)
}
es_which <- function(rel, m) {
  out <- rep(NA_integer_, length(rel))
  for (k in seq_len(nrow(m))) out[is.na(out) & !is.na(rel) & rel >= m[k, 1] & rel <= m[k, 2]] <- k
  out
}
# Reference-set membership of event times (cells or rows): omitted intervals, plus uncovered times when uncovered = "ref"
es_inref <- function(rel, S) {
  b <- es_which(rel, S$bins); r <- es_which(rel, S$ref)
  !is.na(rel) & (!is.na(r) | (S$uncovered == "ref" & is.na(b)))
}
# Adds `rel` (calendar t - g; NA for never-treated), `erel` (the row's event time for bin assignment: the authors' e_auth
# where given, else rel), `ebin` (bin index; 0 = reference: omitted bins, pooled uncovered times and never-treated) and `eref`
# (TRUE for ever-treated rows in the modern estimators' reference set, i.e. omitted bins plus pooled uncovered times); drops
# uncovered rows when uncovered = "drop". Returns list(d = ..., S = parsed structure).
es_assign <- function(d, es) {
  S <- es_parse(es)
  d <- data.table::copy(data.table::as.data.table(d))
  d[, rel := data.table::fifelse(is.finite(g), t - g, NA_real_)]
  if ("e_auth" %in% names(d)) d[, erel := data.table::fifelse(is.finite(g) & !is.na(e_auth), as.numeric(e_auth), rel)] else d[, erel := rel]
  b <- es_which(d$erel, S$bins); r <- es_which(d$erel, S$ref)
  unc <- is.finite(d$g) & is.na(b) & is.na(r)
  d[, `:=`(ebin = data.table::fifelse(is.na(b), 0L, b), eref = is.finite(g) & is.na(b) & (!is.na(r) | S$uncovered == "ref"))]
  if (S$uncovered == "drop") d <- d[!unc]
  list(d = d, S = S)
}
