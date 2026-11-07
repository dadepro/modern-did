#!/bin/bash
# Split one long bootstrap into K parallel chunks, merge, and hand the result to the scheduler (Nov 3).
#   nohup setsid ./code/boot_chunked.sh <spec.json> <K> [phase boot|bootA] > logs/chunk_<name>.out 2>&1 < /dev/null &
# boot_cov.R with BOOT_CHUNK=k/K runs draws of block k only (row b of the seeded weight matrix for draw b), BOOT_MERGE=K
# combines them; the result equals the single-process bootstrap (checked: max |diff| 0 on 3626 t2c1 and 4103 T3, B = 30).
# On success it writes the DONE line in logs/server_<phase>.log and then stops the single-process copy of the same bootstrap
# that the scheduler started (its FAILED line is then superseded by the DONE line).
set -u
cd /data/research/diff-in-diff-replica
export DID_PKG_ROOT=/data/research/diff-in-diff-replica/did_packages CSA_MAX_IF=1e13 OMP_THREAD_LIMIT=2 R_DATATABLE_NUM_THREADS=2
s=$1; K=$2; ph=${3:-boot}; b=$(basename "$s" .json)
case "$ph" in bootA) envA=(env CSA_STRICT_HULL=1 OUT_DIR=output_hullA) ;; *) envA=(env) ;; esac
echo "$(date '+%F %T') CHUNKED START $ph $s K=$K" >> logs/server_run3.log
pids=()
for k in $(seq 1 "$K"); do
  ( ulimit -v $((48 * 1048576)); BOOT_CHUNK=$k/$K exec "${envA[@]}" Rscript code/R/boot_cov.R "$s" 999 ) > "logs/jobs/${ph}_${b}.chunk$k.log" 2>&1 &
  pids+=($!)
done
ok=1; for p in "${pids[@]}"; do wait "$p" || ok=0; done
if [ $ok = 1 ] && BOOT_MERGE=$K "${envA[@]}" Rscript code/R/boot_cov.R "$s" 999 > "logs/jobs/${ph}_${b}.merge.log" 2>&1; then
  echo "$(date '+%F %T') DONE $s (chunked K=$K)" >> "logs/server_$ph.log"
  echo "$(date '+%F %T') CHUNKED DONE $ph $s" >> logs/server_run3.log
  for p in $(pgrep -f "boot_cov.R --args $s 999"); do
    if ! tr '\0' '\n' < /proc/$p/environ 2>/dev/null | grep -q '^BOOT_'; then
      [ "$ph" = bootA ] && ! tr '\0' '\n' < /proc/$p/environ | grep -q '^CSA_STRICT_HULL=1' && continue
      [ "$ph" = boot ] && tr '\0' '\n' < /proc/$p/environ | grep -q '^CSA_STRICT_HULL=1' && continue
      echo "$(date '+%F %T') CHUNKED stop single-process copy pid $p" >> logs/server_run3.log; kill "$p"
    fi
  done
else
  echo "$(date '+%F %T') CHUNKED FAILED $ph $s (chunks ok=$ok); the scheduler's single-process copy continues" >> logs/server_run3.log
fi
