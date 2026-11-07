source("code/R/estimators.R")
data(mpdta, package = "did")   # county-level teen employment, staggered min-wage increases
d <- data.table(id = mpdta$countyreal, t = mpdta$year, g = ifelse(mpdta$first.treat == 0, Inf, mpdta$first.treat),
                y = mpdta$lemp, w = 1, cl = mpdta$countyreal)
res <- compare_spec(d, B = 0)
print(res)
