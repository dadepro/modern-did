#!/bin/zsh
# Global R concurrency limiter (v2, Nov 1 2026). Usage: code/rslot.sh <command...>
#   e.g. code/rslot.sh Rscript code/R/run_spec.R data/specs/x.json
# Pool from RSLOT_POOL: "heavy" (1 slot: long queue jobs) or "agent" (default, 2 slots: agents' R runs). Unknown pool = error.
# The slot is a kernel flock held by the job process itself (code/rslot_exec.py), released automatically when the job
# ends or is killed. Jobs also wait while the memguard heartbeat is stale. Exit status = the command's exit status.
POOL="${RSLOT_POOL:-agent}"
case "$POOL" in heavy) N=1 ;; agent) N=2 ;; boot) N=3 ;; *) echo "rslot: unknown pool '$POOL' (use heavy, agent or boot)" >&2; exit 2 ;; esac
exec python3 -I "$(dirname "$0")/rslot_exec.py" "$HOME/did_packages/.rslots" "$POOL" "$N" "$@"
