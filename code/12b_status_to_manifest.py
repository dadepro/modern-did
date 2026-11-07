#!/usr/bin/env python3
"""Fold per-paper status files (data/packages/status/*.txt) back into package_manifest.csv."""
import csv, os, pathlib
ROOT = pathlib.Path(__file__).resolve().parents[1]
MAN = ROOT / "data/candidates/package_manifest.csv"
man = list(csv.DictReader(open(MAN, newline="")))
for r in man:
    f = ROOT / "data/packages/status" / f"{r['suffix']}.txt"
    if f.exists():
        parts = f.read_text().split("\t"); r["status"] = parts[0]
        if len(parts) > 1 and parts[1].isdigit(): r["size_mb"] = round(int(parts[1]) / 1e6, 1)
tmp = MAN.with_name(MAN.name + ".tmp")   # atomic replace (review R3)
with open(tmp, "w", newline="") as fh:
    w = csv.DictWriter(fh, fieldnames=list(man[0].keys())); w.writeheader(); w.writerows(man); fh.flush(); os.fsync(fh.fileno())
os.replace(tmp, MAN)
import collections; print(dict(collections.Counter(r["status"] or "pending" for r in man)))
