#!/usr/bin/env python3
"""Match JMR Dataverse deposits to JMR papers in the frame.
Output data/hits/jmr_dataverse.csv: doi, dv_doi, dv_title, public_files, restricted_files, match_score
"""
import csv, json, re, difflib, urllib.request, urllib.parse, pathlib, sys
ROOT = pathlib.Path(__file__).resolve().parents[1]
OUT = ROOT / "data" / "hits" / "jmr_dataverse.csv"
HDR = {"User-Agent": "diff-in-diff-replica (mailto:proserpi@marshall.usc.edu)"}
def get(u):
    return json.load(urllib.request.urlopen(urllib.request.Request(u, headers=HDR), timeout=90))
base = "https://dataverse.harvard.edu/api"
ds, start = [], 0
while True:
    r = get(f"{base}/search?q=*&type=dataset&subtree=jmr&per_page=100&start={start}")["data"]
    ds += r["items"]; start += 100
    if start >= r["total_count"]:
        break
def norm(t):
    t = re.sub(r"^(sample data and )?replication (data|code)( and code)? for:?\s*", "", t, flags=re.I)
    t = re.sub(r"[^a-z0-9 ]+", " ", t.lower()); return re.sub(r"\s+", " ", t).strip()
frame = [r for r in csv.DictReader(open(ROOT / "data" / "frame" / "frame.csv", newline="")) if r["journal_key"] == "jmr"]
ftitles = {r["doi"]: norm(re.sub(r"^EXPRESS:\s*", "", r["title"])) for r in frame}
rows = []
for d in ds:
    pid = d["global_id"]
    files = get(f"{base}/datasets/:persistentId/versions/:latest/files?persistentId={urllib.parse.quote(pid)}")["data"]
    restr = sum(1 for f in files if f.get("restricted") or f.get("dataFile", {}).get("restricted"))
    dvt = norm(d["name"])
    best, score = None, 0.0
    for doi, ft in ftitles.items():
        s = difflib.SequenceMatcher(None, dvt, ft).ratio()
        if ft and (dvt.startswith(ft[:40]) or ft.startswith(dvt[:40])):
            s = max(s, 0.95)
        if s > score:
            best, score = doi, s
    rows.append({"doi": best if score >= 0.6 else "", "dv_doi": pid, "dv_title": d["name"], "dv_year": d.get("published_at", "")[:4],
                 "public_files": len(files) - restr, "restricted_files": restr, "match_score": round(score, 2), "best_frame_doi": best})
with open(OUT, "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=list(rows[0].keys())); w.writeheader(); w.writerows(rows)
m = sum(1 for r in rows if r["doi"]); p = sum(1 for r in rows if r["doi"] and r["public_files"] > 0)
print(f"{len(rows)} deposits; matched to frame: {m}; matched with public files: {p}", file=sys.stderr)
for r in rows:
    if not r["doi"]:
        print(f"  unmatched (score {r['match_score']}): {r['dv_title'][:70]}", file=sys.stderr)
