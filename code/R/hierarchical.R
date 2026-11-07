# Gaussian precision-dependent hierarchical model for (TWFE, modern) estimate pairs,
# following Hull (2026), Section 4.3 (bivariate version of Walters 2024 / Chen 2026).
#
# Data: data.frame with columns
#   bT, sT  : TWFE estimate and SE      bM, sM : modern-DiD estimate and SE
#   cov     : estimated covariance between bT and bM (bootstrap); 0 if missing
#   paper   : paper id for clustering
# Model: theta_k | S_k ~ N(mu_k, Sigma_k),  theta_hat_k | theta_k ~ N(theta_k, S_k)
#   mu_ke = a_e + b_e Q_ke,  tau_ke = exp(c_e + d_e Q_ke),  Q_ke = demeaned log s_ke,
#   corr(theta_T, theta_M) = rho   (9 parameters)
suppressPackageStartupMessages({ library(data.table); library(numDeriv) })

hier_fit <- function(d, se_cluster = TRUE) {
  d <- as.data.table(d); if (!"cov" %in% names(d)) d[, cov := 0]
  d[, `:=`(QT = log(sT) - mean(log(sT)), QM = log(sM) - mean(log(sM)))]
  negll <- function(p, dd = d) {
    # p = (cT, dT, cM, dM, z) with rho = tanh(z); means profiled by GLS inside
    tT <- exp(p[1] + p[2] * dd$QT); tM <- exp(p[3] + p[4] * dd$QM); rho <- tanh(p[5])
    V11 <- tT^2 + dd$sT^2; V22 <- tM^2 + dd$sM^2; V12 <- rho * tT * tM + dd$cov
    det <- V11 * V22 - V12^2
    if (any(det <= 0)) return(1e12)
    # GLS for (aT, bT, aM, bM): stack as y = X beta + e with block-diagonal 2x2 V_k
    X1 <- cbind(1, dd$QT); X2 <- cbind(1, dd$QM)
    iV11 <- V22 / det; iV22 <- V11 / det; iV12 <- -V12 / det
    XtWX <- matrix(0, 4, 4); XtWy <- numeric(4)
    for (k in seq_len(nrow(dd))) {
      Xk <- rbind(c(X1[k, ], 0, 0), c(0, 0, X2[k, ])); Wk <- matrix(c(iV11[k], iV12[k], iV12[k], iV22[k]), 2)
      XtWX <- XtWX + t(Xk) %*% Wk %*% Xk; XtWy <- XtWy + t(Xk) %*% Wk %*% c(dd$bT[k], dd$bM[k])
    }
    beta <- solve(XtWX, XtWy)
    rT <- dd$bT - X1 %*% beta[1:2]; rM <- dd$bM - X2 %*% beta[3:4]
    q <- iV11 * rT^2 + 2 * iV12 * rT * rM + iV22 * rM^2
    0.5 * sum(log(det) + q) + nrow(dd) * log(2 * pi)
  }
  p0 <- c(log(sd(d$bT)), 0, log(sd(d$bM)), 0, atanh(0.8))
  o <- optim(p0, negll, method = "BFGS", control = list(maxit = 500, reltol = 1e-10))
  p <- o$par
  # recover means
  tT <- exp(p[1] + p[2] * d$QT); tM <- exp(p[3] + p[4] * d$QM); rho <- tanh(p[5])
  list(par = p, rho = rho, tauT = tT, tauM = tM, d = d, negll = o$value, conv = o$convergence,
       means = hier_means(p, d))
}
hier_means <- function(p, d) {
  tT <- exp(p[1] + p[2] * d$QT); tM <- exp(p[3] + p[4] * d$QM); rho <- tanh(p[5])
  V11 <- tT^2 + d$sT^2; V22 <- tM^2 + d$sM^2; V12 <- rho * tT * tM + d$cov; det <- V11 * V22 - V12^2
  X1 <- cbind(1, d$QT); X2 <- cbind(1, d$QM); iV11 <- V22 / det; iV22 <- V11 / det; iV12 <- -V12 / det
  XtWX <- matrix(0, 4, 4); XtWy <- numeric(4)
  for (k in seq_len(nrow(d))) {
    Xk <- rbind(c(X1[k, ], 0, 0), c(0, 0, X2[k, ])); Wk <- matrix(c(iV11[k], iV12[k], iV12[k], iV22[k]), 2)
    XtWX <- XtWX + t(Xk) %*% Wk %*% Xk; XtWy <- XtWy + t(Xk) %*% Wk %*% c(d$bT[k], d$bM[k])
  }
  beta <- solve(XtWX, XtWy); list(muT = as.vector(X1 %*% beta[1:2]), muM = as.vector(X2 %*% beta[3:4]), beta = beta)
}

# Summary statistics averaged over the empirical distribution of standard errors (Hull Table 2)
hier_summary <- function(fit, nsim = 20000, seed = 1) {
  set.seed(seed); d <- fit$d; m <- fit$means; rho <- fit$rho
  K <- nrow(d); sd_T <- sqrt(mean(fit$tauT^2 + (m$muT - mean(m$muT))^2)); sd_M <- sqrt(mean(fit$tauM^2 + (m$muM - mean(m$muM))^2))
  # prior probabilities by simulation: draw k uniformly, then theta ~ N(mu_k, Sigma_k), then TWFE estimate ~ N(theta_T, sT_k^2)
  k <- sample.int(K, nsim, replace = TRUE)
  z1 <- rnorm(nsim); z2 <- rho * z1 + sqrt(1 - rho^2) * rnorm(nsim)
  thT <- m$muT[k] + fit$tauT[k] * z1; thM <- m$muM[k] + fit$tauM[k] * z2
  bT_hat <- thT + d$sT[k] * rnorm(nsim)
  p_flip <- mean(thT * thM < 0)
  p_sig_wrong <- mean(bT_hat * thM < 0 & abs(bT_hat) > 1.96 * d$sT[k])
  # correlation of estimands (averaged over k): cov/sd
  corr <- mean(rho * fit$tauT * fit$tauM + (m$muT - mean(m$muT)) * (m$muM - mean(m$muM))) / (sd_T * sd_M)
  data.table(sd_twfe = sd_T, sd_modern = sd_M, corr_estimands = corr, p_sign_reversal = p_flip,
             p_sig_wrong_sign = p_sig_wrong, n = K, papers = uniqueN(d$paper))
}

# Paper-clustered bootstrap for standard errors of the summary statistics
hier_boot <- function(d, B = 100, seed = 2) {
  set.seed(seed); d <- as.data.table(d); papers <- unique(d$paper); out <- list()
  for (b in seq_len(B)) {
    ps <- sample(papers, replace = TRUE)
    db <- rbindlist(lapply(seq_along(ps), function(i) { x <- d[paper == ps[i]]; x[, paper := paste0(ps[i], "_", i)]; x }))
    out[[b]] <- tryCatch(hier_summary(hier_fit(db), nsim = 5000, seed = b), error = function(e) NULL)
  }
  rbindlist(out)[, lapply(.SD, sd), .SDcols = 1:5]
}
