#!/bin/zsh
# Re-run every spec JSON (or those given as arguments) through run_spec.R; log to logs/run_specs.log
cd "$(cd "$(dirname "$0")/.." && pwd)"
files=("$@"); [ ${#files[@]} -eq 0 ] && files=(data/specs/*.json)
for f in "${files[@]}"; do
  echo "=== $(date +%H:%M:%S) $f" >> logs/run_specs.log
  Rscript code/R/run_spec.R "$f" >> logs/run_specs.log 2>&1 || echo "FAILED $f" >> logs/run_specs.log
done
echo "done $(date +%H:%M:%S)" >> logs/run_specs.log
