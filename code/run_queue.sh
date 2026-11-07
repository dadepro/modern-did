#!/bin/zsh
# Generic spec runner: code/run_queue.sh <logname> <spec.json>...  (logs to logs/<logname>.log)
# Env vars (e.g. CSA_MAX_CELLS, CSA_MAX_OBS) pass through to run_spec.R.
# Each R job takes a slot from code/rslot.sh (pool RSLOT_POOL, default "heavy" = one job at a time across all queues);
# code/memguard.py kills any R job that exceeds its memory cap (logged as FAILED here, details in logs/memguard_kills.log).
cd "$(cd "$(dirname "$0")/.." && pwd)"
LOG="logs/$1.log"; QNAME="$1"; shift
export RSLOT_POOL="${RSLOT_POOL:-heavy}"
echo "queue started $(date) ($# specs)" >> "$LOG"
for f in "$@"; do
  echo "=== $(date +%H:%M:%S) $f" >> "$LOG"
  ./code/rslot.sh Rscript code/R/run_spec.R "$f" >> "$LOG" 2>&1 < /dev/null || { echo "FAILED $f" >> "$LOG"; echo "$(date '+%m-%d %H:%M:%S') FAILED [$QNAME] $f" >> logs/queue_events.log; }
done
echo "done $(date +%H:%M:%S)" >> "$LOG"; echo "$(date '+%m-%d %H:%M:%S') done [$QNAME] $# specs, $(grep -c '^FAILED' "$LOG") FAILED lines in $LOG" >> logs/queue_events.log
