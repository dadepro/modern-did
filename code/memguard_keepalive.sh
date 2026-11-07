#!/bin/zsh
# Keeps code/memguard.py running (restarts it within 2 s if it ever exits). Start: nohup ./code/memguard_keepalive.sh >/dev/null 2>&1 &
cd "$(cd "$(dirname "$0")/.." && pwd)"
while true; do
  python3 -I code/memguard.py >> logs/memguard_stderr.log 2>&1
  echo "$(date '+%Y-%m-%d %H:%M:%S') memguard exited with $?; restarting" >> logs/memguard.log
  sleep 2
done
