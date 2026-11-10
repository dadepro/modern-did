#!/usr/bin/env python3
"""Merge full-text search hits (data/hits/raw/*.json), citation flags (data/hits/cites.csv)
and JMR Dataverse matches (data/hits/jmr_dataverse.csv) with the OpenAlex frame
(data/frame/frame.csv) into a candidate table with one row per paper.

Output: data/candidates/candidates.csv, data/candidates/hits_not_in_frame.csv,
        data/candidates/summary.txt
"""
import csv, json, pathlib, re, collections

ROOT = pathlib.Path(__file__).resolve().parents[1]
RAW = ROOT / "data" / "hits" / "raw"
CITES = ROOT / "data" / "hits" / "cites.csv"
DV = ROOT / "data" / "hits" / "jmr_dataverse.csv"
FRAME = ROOT / "data" / "frame" / "frame.csv"
OUT = ROOT / "data" / "candidates"
OUT.mkdir(parents=True, exist_ok=True)

def slug(q):
    return "ft_" + re.sub(r"[^a-z0-9]+", "_", q.lower()).strip("_")

# ---- 1. full-text hits -------------------------------------------------------
hits = collections.defaultdict(dict)      # doi -> {flag: 1}
counts, pages = {}, collections.Counter()
for fn in sorted(RAW.glob("*.json")):
    d = json.loads(fn.read_text())
    if d["journal"] == "test":
        continue
    key = (d["journal"], d["query"])
    counts[key] = d.get("count"); pages[key] += 1
    for doi in d["dois"]:
        hits[doi.lower()][slug(d["query"])] = 1
ft_flags = sorted({f for v in hits.values() for f in v})

# ---- 2. citation flags and Dataverse matches ----------------------------------
cites = {}
if CITES.exists():
    for r in csv.DictReader(open(CITES, newline="")):
        cites[r["doi"].lower()] = r
cite_cols = [c for c in (next(iter(cites.values())).keys() if cites else []) if c.startswith("cite_")]
dv = {}
if DV.exists():
    for r in csv.DictReader(open(DV, newline="")):
        if r["doi"]:
            dv[r["doi"].lower()] = r

# ---- 3. frame + abstract flags ----------------------------------------------
ABS_TERMS = {
    "abs_did": r"difference[s]?[- ]in[- ]difference[s]?|diff[- ]in[- ]diff|\bDiD\b|\bDD\b",
    "abs_staggered": r"stagger",
    "abs_event_study": r"event[- ]stud",
    "abs_natural_exp": r"natural experiment|quasi[- ]?experiment|quasi[- ]natural",
    "abs_twfe": r"two[- ]way fixed effects|\bTWFE\b",
}
frame = {}
for r in csv.DictReader(open(FRAME, newline="")):
    if r["type"] != "article" or not r["doi"]:
        continue
    text = r["title"] + " " + r["abstract"]
    for k, pat in ABS_TERMS.items():
        r[k] = int(bool(re.search(pat, text, flags=re.I)))
    frame[r["doi"].lower()] = r

# ---- 4. merge ----------------------------------------------------------------
CORE = ("ft_difference_in_differences", "ft_difference_in_difference", "ft_differences_in_differences",
        "ft_diff_in_diff", "ft_two_way_fixed_effects")
MODERN = ("ft_callaway", "ft_goodman_bacon", "ft_borusyak", "ft_sun_and_abraham", "ft_de_chaisemartin")
rows, missing = [], []
for doi, r in frame.items():
    h = hits.get(doi, {}); c = cites.get(doi, {}); d = dv.get(doi, {})
    row = {
        "journal": r["journal_key"], "doi": r["doi"], "year": r["year"], "title": r["title"],
        "authors": r["authors"], "cited_by": r["cited_by"], "is_oa": r["is_oa"],
        "oa_url": r["oa_url"], "oa_pdf_url": r["oa_pdf_url"], "topic": r["topic"],
    }
    for fl in ft_flags:
        row[fl] = h.get(fl, 0)
    for cc in cite_cols:
        row[cc] = int(c.get(cc, 0) or 0)
    for k in ABS_TERMS:
        row[k] = r[k]
    row["dv_doi"] = d.get("dv_doi", "")
    row["dv_public_files"] = d.get("public_files", "")
    row["dv_restricted_files"] = d.get("restricted_files", "")
    row["n_ft_flags"] = sum(h.values())
    core = any(h.get(f) for f in CORE) or bool(int(c.get("cite_any", 0) or 0))
    modern = any(h.get(f) for f in MODERN) or bool(int(c.get("cite_modern", 0) or 0))
    stag = bool(h.get("ft_staggered", 0)) or bool(r["abs_staggered"])
    if (core and stag) or modern:
        row["tier"] = 1          # DiD language/citation + staggered or modern-estimator signal
    elif core or stag:
        row["tier"] = 2          # DiD or staggered signal only
    elif r["abs_did"] or r["abs_natural_exp"] or r["abs_event_study"] or r["abs_twfe"]:
        row["tier"] = 3          # abstract-only signal
    else:
        row["tier"] = 9
    row["signal_source"] = "+".join(s for s, v in (("fulltext", bool(h)), ("citation", bool(c)), ("abstract", any(r[k] for k in ABS_TERMS))) if v)
    rows.append(row)
for doi, h in hits.items():
    if doi not in frame:
        missing.append({"doi": doi, **h})

rows.sort(key=lambda x: (x["tier"], x["journal"], -int(x["cited_by"] or 0)))
with open(OUT / "candidates.csv", "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=list(rows[0].keys())); w.writeheader(); w.writerows(rows)
with open(OUT / "hits_not_in_frame.csv", "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=["doi"] + ft_flags, extrasaction="ignore"); w.writeheader(); w.writerows(missing)

# ---- 5. summary --------------------------------------------------------------
lines = ["Full-text queries collected (journal, query): pages, reported total, unique DOIs"]
for (j, q), cnt in sorted(counts.items()):
    n = sum(1 for d_, h in hits.items() if slug(q) in h and frame.get(d_, {}).get("journal_key") == j)
    lines.append(f"  {j:5s} {q:32s} pages={pages[(j,q)]} total={cnt} dois={n}")
lines.append(f"\nCitation flags: {len(cites)} citing works; JMR Dataverse matches: {len(dv)}")
lines.append("\nCandidates by journal and tier (1 = DiD + staggered/modern signal; 2 = DiD or staggered only; 3 = abstract only)")
tab = collections.Counter((r["journal"], r["tier"]) for r in rows)
for j in ("mnsc", "mksc", "jmr", "isre", "msom", "opre", "orsc", "jm", "qme"):
    lines.append(f"  {j}: " + ", ".join(f"tier{t}={tab[(j,t)]}" for t in (1, 2, 3, 9)))
lines.append(f"\nFull-text hits not matched to the frame: {len(missing)}")
(OUT / "summary.txt").write_text("\n".join(lines))
print("\n".join(lines[-6:]))
