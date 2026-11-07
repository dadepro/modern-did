#!/usr/bin/env python3
"""Slot limiter core (v2, Nov 1 2026; replaces mkdir locks, review findings B5/B6/R2/R10/R7).
Usage (via code/rslot.sh): rslot_exec.py <lockdir> <pool> <nslots> <command...>
Takes an exclusive flock on <lockdir>/<pool>.<i>.lock and exec()s the command with the lock fd inherited, so the
lock is held by the job process itself (Rscript -> R -> exec/R all exec) and released by the kernel when it exits or
is killed: no stale locks, no pid checks. Waits while all slots are busy, and while the memguard heartbeat
(~/did_packages/.memguard/status.txt) is older than 20 s, so no R job starts unguarded."""
import fcntl, os, sys, time
d, pool, n, cmd = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4:]
HB = os.path.expanduser("~/did_packages/.memguard/status.txt")
os.makedirs(d, exist_ok=True); said = set()
while True:
    try: hb_age = time.time() - os.path.getmtime(HB)
    except OSError: hb_age = 1e9
    if hb_age > 20:
        if "hb" not in said: print(f"rslot: memguard heartbeat stale ({hb_age:.0f}s); waiting (start code/memguard_keepalive.sh)", file=sys.stderr, flush=True); said.add("hb")
        time.sleep(5); continue
    for i in range(1, n + 1):
        fd = os.open(f"{d}/{pool}.{i}.lock", os.O_RDWR | os.O_CREAT, 0o644)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            os.close(fd); continue
        os.set_inheritable(fd, True)
        os.execvp(cmd[0], cmd)
    if "busy" not in said: print(f"rslot: all {n} '{pool}' slots busy; waiting", file=sys.stderr, flush=True); said.add("busy")
    time.sleep(3)
