#!/usr/bin/env python3
"""Add to the frame any full-text hit whose DOI is missing from data/frame/frame.csv.
These are mostly papers whose OpenAlex publication year (online-first) falls outside the
journal window although the INFORMS site dates them inside it. Looked up one by one."""
import csv, json, sys, time, urllib.request, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from importlib import import_module
fr = import_module("01_openalex_frame")
ROOT = pathlib.Path(__file__).resolve().parents[1]
FRAME = ROOT / "data" / "frame" / "frame.csv"
MISS = ROOT / "data" / "candidates" / "hits_not_in_frame.csv"
rows = list(csv.DictReader(open(FRAME, newline="")))
have = {r["doi"].lower() for r in rows}
added = 0
for m in csv.DictReader(open(MISS, newline="")):
    doi = m["doi"]
    if doi.lower() in have:
        continue
    url = f"https://api.openalex.org/works/https://doi.org/{doi}?select={fr.FIELDS}"
    try:
        w = fr.get(url, tries=2)
    except Exception as e:
        print(f"  skip {doi}: {str(e)[:60]}", file=sys.stderr); continue
    w["abstract"] = fr.abstract_from_index(w.pop("abstract_inverted_index", None))
    w["journal_key"] = doi.split("/")[1].split(".")[0]
    flat = fr.flatten(w)
    flat["frame_note"] = "added_from_hits"
    rows.append(flat); added += 1
    time.sleep(0.1)
fields = list(rows[0].keys()) + (["frame_note"] if "frame_note" not in rows[0] else [])
with open(FRAME, "w", newline="") as f:
    wr = csv.DictWriter(f, fieldnames=fields, extrasaction="ignore"); wr.writeheader(); wr.writerows(rows)
print(f"added {added} records; frame now {len(rows)} rows", file=sys.stderr)
