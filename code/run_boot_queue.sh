#!/bin/zsh
# Joint bootstrap queue: code/run_boot_queue.sh <logname> <spec.json>...  (B from BOOT_B, default 999; pool RSLOT_POOL, default agent)
cd "$(cd "$(dirname "$0")/.." && pwd)"
LOG="logs/$1.log"; QNAME="$1"; shift; export RSLOT_POOL="${RSLOT_POOL:-agent}"; BB="${BOOT_B:-999}"
echo "boot queue started $(date) ($# specs, B=$BB)" >> "$LOG"
for f in "$@"; do
  echo "=== $(date +%H:%M:%S) $f" >> "$LOG"
  ./code/rslot.sh Rscript code/R/boot_cov.R "$f" "$BB" >> "$LOG" 2>&1 < /dev/null || { echo "FAILED $f" >> "$LOG"; echo "$(date '+%m-%d %H:%M:%S') FAILED [$QNAME] $f" >> logs/queue_events.log; }
done
echo "done $(date +%H:%M:%S)" >> "$LOG"; echo "$(date '+%m-%d %H:%M:%S') done [$QNAME] $# specs, $(grep -c '^FAILED' "$LOG") FAILED lines in $LOG" >> logs/queue_events.log
