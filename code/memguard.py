#!/usr/bin/env python3
"""Memory guard + resource monitor, v2 (Nov 1 2026; v1 written after two watchdog kernel panics caused by R jobs
holding 33-205 GB on this 32 GB machine; v2 fixes the review findings B3/B4/R5/R6/R7).

Every second it reads the physical footprint (includes compressed memory) of every PIPELINE R process: the R
interpreter (.../exec/R) started with --file= (Rscript), excluding VS Code language-server helpers. Interactive R
sessions, RStudio and other apps are never killed and are not counted. Rules (SIGKILL at once, no sleep in the loop):
  1. a pipeline R process exceeds R_CAP_GB, or is projected past 1.25 x cap within one poll          -> kill it
  2. pipeline R processes together exceed R_TOTAL_GB                                                -> kill the largest
  3. kern.memorystatus_level (free memory %) < LEVEL_MIN                                             -> kill the largest (> 1 GB)
Rule 1 is never rate-limited; rules 2-3 wait COOL seconds after a kill. Already-signalled pids are excluded.
No forks in the poll loop (libproc + sysctl through ctypes). Every log write is guarded so the loop never dies;
code/memguard_keepalive.sh restarts it if it does. Heartbeat/status: ~/did_packages/.memguard/status.txt (outside
Dropbox; code/rslot.sh refuses to start R jobs while the heartbeat is stale). Logs: logs/memguard.log,
logs/memguard_kills.log. Env overrides: R_CAP_GB, R_TOTAL_GB, LEVEL_MIN, MEMGUARD_DRY=1 (log only, never kill).
"""
import ctypes, ctypes.util, os, signal, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOG, KLOG = f"{ROOT}/logs/memguard.log", f"{ROOT}/logs/memguard_kills.log"
HB_DIR = os.path.expanduser("~/did_packages/.memguard"); STATUS = f"{HB_DIR}/status.txt"
R_CAP_GB = float(os.environ.get("R_CAP_GB", "12")); R_TOTAL_GB = float(os.environ.get("R_TOTAL_GB", "18"))
LEVEL_MIN = int(os.environ.get("LEVEL_MIN", "12")); DRY = os.environ.get("MEMGUARD_DRY") == "1"
POLL, COOL, LOG_EVERY, GB = 1.0, 3.0, 30, 1024 ** 3

libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
class RUsageV2(ctypes.Structure):
    _fields_ = [("uuid", ctypes.c_uint8 * 16)] + [(n, ctypes.c_uint64) for n in (
        "user_time", "system_time", "pkg_idle_wkups", "interrupt_wkups", "pageins", "wired_size",
        "resident_size", "phys_footprint", "proc_start_abstime", "proc_exit_abstime", "child_user_time",
        "child_system_time", "child_pkg_idle_wkups", "child_interrupt_wkups", "child_pageins",
        "child_elapsed_abstime", "diskio_bytesread", "diskio_byteswritten")]
class XswUsage(ctypes.Structure):
    _fields_ = [("total", ctypes.c_uint64), ("avail", ctypes.c_uint64), ("used", ctypes.c_uint64),
                ("pagesize", ctypes.c_uint32), ("encrypted", ctypes.c_int32)]

def rusage(pid):
    ru = RUsageV2()
    return (ru.phys_footprint, ru.proc_start_abstime) if libproc.proc_pid_rusage(pid, 2, ctypes.byref(ru)) == 0 else (0, 0)

def all_pids():
    n = libproc.proc_listallpids(None, 0)
    buf = (ctypes.c_int * (n + 64))()
    n = libproc.proc_listallpids(buf, ctypes.sizeof(buf))
    return [p for p in buf[:max(n, 0)] if p > 0]

_pb = ctypes.create_string_buffer(4096)
def pid_path(pid):
    return _pb.value.decode(errors="replace") if libproc.proc_pidpath(pid, _pb, 4096) > 0 else ""

_argmax = ctypes.c_int(0); _sz = ctypes.c_size_t(ctypes.sizeof(_argmax))
libc.sysctlbyname(b"kern.argmax", ctypes.byref(_argmax), ctypes.byref(_sz), None, 0)
def pid_args(pid):  # KERN_PROCARGS2: argc, exec path, padding, argv...
    mib = (ctypes.c_int * 3)(1, 49, pid); size = ctypes.c_size_t(_argmax.value or 1048576)
    buf = ctypes.create_string_buffer(size.value)
    if libc.sysctl(mib, 3, buf, ctypes.byref(size), None, 0) != 0: return ""
    raw = buf.raw[:size.value]; argc = int.from_bytes(raw[:4], "little")
    parts = [p for p in raw[4:].split(b"\0") if p]
    return " ".join(x.decode(errors="replace") for x in parts[1:1 + argc])

def sysctl_int(name):
    v = ctypes.c_int(-1); s = ctypes.c_size_t(ctypes.sizeof(v))
    return v.value if libc.sysctlbyname(name.encode(), ctypes.byref(v), ctypes.byref(s), None, 0) == 0 else -1

def swap_used_gb():
    x = XswUsage(); s = ctypes.c_size_t(ctypes.sizeof(x))
    return x.used / GB if libc.sysctlbyname(b"vm.swapusage", ctypes.byref(x), ctypes.byref(s), None, 0) == 0 else -1.0

def log(path, msg):
    try:
        with open(path, "a") as f: f.write(time.strftime("%Y-%m-%d %H:%M:%S ") + msg + "\n")
    except Exception:
        pass

meta = {}      # (pid, start) -> (is_pipeline_R, args, exec_path)
signalled = {} # (pid, start) -> time signalled
prev_fp = {}
def classify(pid, start):
    # re-classify when the executable changes: exec() keeps pid and start time, so a job that waited in rslot_exec.py (python)
    # and then exec'd into R was cached as non-pipeline and escaped the caps (mnsc.2021.4209 bootstrap, Nov 2 ~04:00-06:10)
    key = (pid, start); path = pid_path(pid); m = meta.get(key)
    if m is None or m[2] != path:
        if not path.endswith("/exec/R"): m = (False, "", path)
        else:
            a = pid_args(pid)
            m = (("--file=" in a) and (".vscode/extensions" not in a), a, path)
        meta[key] = m
    return m[0], m[1]

def kill(pid, start, fp, why):
    key = (pid, start)
    if not DRY:
        try:
            if rusage(pid)[1] == start: os.kill(pid, signal.SIGKILL)   # same process instance (no pid reuse)
        except ProcessLookupError:
            pass
    signalled[key] = time.time()
    a = meta.get(key, (False, ""))[1]
    log(KLOG, f"KILL{' (DRY)' if DRY else ''} pid={pid} footprint={fp / GB:.1f}GB reason={why} args={a[:400]}")
    log(LOG, f"KILL{' (DRY)' if DRY else ''} pid={pid} {fp / GB:.1f}GB {why}")

os.makedirs(HB_DIR, exist_ok=True)
log(LOG, f"memguard v2 start pid={os.getpid()}: R_CAP_GB={R_CAP_GB} R_TOTAL_GB={R_TOTAL_GB} LEVEL_MIN={LEVEL_MIN} DRY={DRY}")
last_log, cool_until, tick = 0.0, 0.0, 0
while True:
    try:
        tick += 1; now = time.time()
        pids = all_pids(); rs = []; others = []
        for pid in pids:
            fp, start = rusage(pid)
            if not start: continue
            pipe, _ = classify(pid, start)
            if pipe and (pid, start) not in signalled: rs.append((pid, start, fp))
            elif fp > GB: others.append((pid, fp))
        live = {(p, s) for p, s, _ in rs}
        for k in [k for k in signalled if now - signalled[k] > 60]: signalled.pop(k, None)
        if len(meta) > 20000: meta.clear()
        rs.sort(key=lambda x: -x[2]); rtot = sum(x[2] for x in rs)
        level = sysctl_int("kern.memorystatus_level")
        # rule 1: per-process cap, including a one-poll growth projection; never rate-limited
        for pid, start, fp in rs:
            grow = max(0, fp - prev_fp.get((pid, start), fp))
            if fp > R_CAP_GB * GB or fp + grow > 1.25 * R_CAP_GB * GB:   # projection only for extreme growth (> cap + 25% within a poll)
                kill(pid, start, fp, f"per_process_cap>{R_CAP_GB}GB (fp {fp / GB:.1f}, +{grow / GB:.1f}/poll)")
                rtot -= fp; cool_until = now + COOL
        rs = [x for x in rs if (x[0], x[1]) not in signalled]
        if rs and now >= cool_until:
            if rtot > R_TOTAL_GB * GB:
                pid, start, fp = rs[0]; kill(pid, start, fp, f"R_total {rtot / GB:.1f}GB>{R_TOTAL_GB}GB"); cool_until = now + COOL
            elif 0 <= level < LEVEL_MIN and rs[0][2] > GB:
                pid, start, fp = rs[0]; kill(pid, start, fp, f"memory_level {level}%<{LEVEL_MIN}%"); cool_until = now + COOL
        prev_fp = {(p, s): fp for p, s, fp in rs}
        if tick % 3 == 0 or now - last_log >= LOG_EVERY:
            others.sort(key=lambda x: -x[1])
            snap = (f"free_level={level}% swap_used={swap_used_gb():.1f}GB pipeline_R_n={len(rs)} pipeline_R_total={rtot / GB:.1f}GB"
                    f" | other>1GB: " + " ; ".join(f"{os.path.basename(pid_path(p))[:24]}({p})={f / GB:.1f}" for p, f in others[:5]))
            try:
                tmp = STATUS + ".tmp"
                with open(tmp, "w") as f:
                    f.write(time.strftime("%Y-%m-%d %H:%M:%S ") + snap + "\n")
                    for pid, start, fp in rs: f.write(f"  R {pid} {fp / GB:.2f}GB {meta[(pid, start)][1][:220]}\n")
                os.replace(tmp, STATUS)
            except Exception:
                pass
            if now - last_log >= LOG_EVERY: log(LOG, snap); last_log = now
    except Exception as e:
        log(LOG, f"memguard error: {e!r}")
    time.sleep(POLL)
