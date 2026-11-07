# Audit: which specs have character unit ids (or categorical xt) with leading zeros? Writes data/leading_zero_specs.txt
suppressMessages({library(data.table); library(jsonlite)})
read_any <- function(p) { if (grepl("\\.rds$", p)) as.data.table(readRDS(p)) else if (grepl("\\.dta$", p)) as.data.table(haven::read_dta(p)) else if (grepl("\\.parquet$", p)) as.data.table(arrow::read_parquet(p)) else fread(p) }
files <- list.files("data/specs", full.names = TRUE, pattern = "json$"); cache <- list(); out <- character(0)
for (f in files) {
  j <- tryCatch(fromJSON(f), error = function(e) NULL); if (is.null(j) || is.null(j$data_path) || !file.exists(j$data_path)) next
  key <- j$data_path
  if (is.null(cache[[key]])) {
    d <- tryCatch(read_any(key), error = function(e) NULL); if (is.null(d)) { cache[[key]] <- list(err = TRUE); next }
    chk <- sapply(names(d), function(v) { x <- d[[v]]; (is.character(x) || is.factor(x)) && any(grepl("^0[0-9]", as.character(x[!is.na(x)][seq_len(min(5e4, sum(!is.na(x))))]))) })
    cache[[key]] <- list(lz = names(chk)[chk]); rm(d); gc()
  }
  lz <- cache[[key]]$lz; if (is.null(lz)) next
  vars <- c(j$id_var, unlist(j$xt_vars)); hit <- intersect(vars, lz)
  if (length(hit)) out <- c(out, sprintf("%s\t%s", f, paste(hit, collapse = ",")))
  cat(sprintf("%s: %s\n", basename(f), if (length(hit)) paste("LEADING-ZERO", paste(hit, collapse = ",")) else "ok"))
}
writeLines(out, "data/leading_zero_specs.txt"); cat(sprintf("\n%d specs affected (data/leading_zero_specs.txt)\n", length(out)))
