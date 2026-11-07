#!/usr/bin/env python3
"""Automated pre-screen of replication code for staggered-DiD-like regressions.
Reads data/packages/<suffix>_regressions.txt (one regression command per line) and scores each paper:
  +3 modern DiD commands (csdid, did_imputation, did2s, did_multiplegt, eventstudyinteract, sunab, att_gt, stackedev)
  +2 panel FE regression with an interaction or post/treat/event-time indicator
  +1 any two-way FE regression (reghdfe/areg/xtreg fe/felm/feols/fixest/plm/lfe)
Writes data/packages/code_prescreen.csv (suffix, journal, score, n_regressions, flags) sorted by score.
Usage: python3 -I code/21_code_prescreen.py [--journal mksc] [--min-score 2]"""
import csv, pathlib, re, sys, collections
ROOT = pathlib.Path(__file__).resolve().parents[1]
args = sys.argv[1:]
jf = args[args.index("--journal") + 1] if "--journal" in args else None
mins = int(args[args.index("--min-score") + 1]) if "--min-score" in args else 0
MODERN = re.compile(r"\b(csdid|did_imputation|did2s|did_multiplegt|eventstudyinteract|sunab|att_gt|aggte|stackedev|jwdid|bacondecomp|did_had|fect|synth)\b", re.I)
TWFE = re.compile(r"\b(reghdfe|areg|xtreg\b.*\bfe\b|felm|feols|fepois|plm\(|lfe::|fixest::|ppmlhdfe|xtpoisson)\b", re.I)
DID = re.compile(r"(post|treat|after|event|rel_?time|lead|lag|adopt|roll ?out|open|launch|entry|ban|law|policy|regul|did|dd\b|1\.|i\.|#|\*|:)", re.I)
INTER = re.compile(r"(\w+\s*[#*:]\s*\w+|i\.\w+#|\bpost\w*\b|\btreat\w*\b|\bafter\w*\b|\bevent_?time\b|\brel\w*\b|\badopt\w*\b)", re.I)
rows = []
for f in sorted((ROOT / "data/packages").glob("*_regressions.txt")):
    suf = f.name[:-len("_regressions.txt")]; j = "jmr" if suf[0].isdigit() else suf.split(".")[0]
    if jf and j != jf: continue
    lines = [l for l in f.read_text(errors="ignore").splitlines() if "::" in l]
    score, flags = 0, collections.Counter()
    for l in lines:
        cmd = l.split("::", 1)[1]
        if MODERN.search(cmd): score = max(score, 3); flags["modern"] += 1
        if TWFE.search(cmd):
            if INTER.search(cmd): score = max(score, 2); flags["twfe_interaction"] += 1
            else: score = max(score, 1); flags["twfe"] += 1
    rows.append({"suffix": suf, "journal": j, "score": score, "n_regressions": len(lines), "flags": ";".join(f"{k}={v}" for k, v in flags.items())})
rows.sort(key=lambda r: (-r["score"], -r["n_regressions"]))
out = ROOT / "data/packages/code_prescreen.csv"
with open(out, "w", newline="") as fh:
    w = csv.DictWriter(fh, fieldnames=["suffix", "journal", "score", "n_regressions", "flags"]); w.writeheader(); w.writerows(rows)
c = collections.Counter((r["journal"], r["score"]) for r in rows)
print("papers by journal and score:", dict(sorted(c.items())))
print("\n".join(f"{r['suffix']:22s} score={r['score']} n={r['n_regressions']:4d} {r['flags']}" for r in rows if r["score"] >= mins)[:3000])
