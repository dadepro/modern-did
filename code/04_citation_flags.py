#!/usr/bin/env python3
"""Citation-based candidate detection (no full text needed).
For each key DiD method paper, list works in the three journals that cite it (OpenAlex
`cites:` filter). Output data/hits/cites.csv: doi, journal, year, title, one 0/1 column per
method paper, plus cite_modern (any heterogeneity-robust estimator paper) and cite_any.
"""
import csv, json, sys, time, urllib.request, urllib.parse, pathlib, collections
ROOT = pathlib.Path(__file__).resolve().parents[1]
OUT = ROOT / "data" / "hits" / "cites.csv"
HDR = {"User-Agent": "diff-in-diff-replica (mailto:proserpi@marshall.usc.edu)"}
def _openalex_key():   # personal OpenAlex key (Nov 2, 2026): env var or ~/.did_env, never printed or logged
    import os, re, pathlib as _pl
    k = os.environ.get("OPENALEX_API_KEY")
    p = _pl.Path.home() / ".did_env"
    if not k and p.exists():
        m = re.search(r"OPENALEX_API_KEY=(\S+)", p.read_text()); k = m.group(1) if m else None
    return k
OA_KEY = _openalex_key()
def with_key(url):
    return url if not OA_KEY or "api_key=" in url or "api.openalex.org" not in url else url + ("&" if "?" in url else "?") + "api_key=" + OA_KEY
def get(u, tries=4):
    for k in range(tries):
        try:
            with urllib.request.urlopen(urllib.request.Request(with_key(u), headers=HDR), timeout=90) as r:
                return json.load(r)
        except Exception as e:
            err = e; time.sleep(2 * (k + 1))
    raise err

METHOD = {  # key: (DOI, modern-estimator flag)
    "goodman_bacon_2021": ("10.1016/j.jeconom.2021.03.014", 1),
    "callaway_santanna_2021": ("10.1016/j.jeconom.2020.12.001", 1),
    "sun_abraham_2021": ("10.1016/j.jeconom.2020.09.006", 1),
    "dcdh_2020": ("10.1257/aer.20181169", 1),
    "borusyak_jaravel_spiess_2024": ("10.1093/restud/rdae007", 1),
    "athey_imbens_2022": ("10.1016/j.jeconom.2020.10.012", 1),
    "roth_et_al_2023": ("10.1016/j.jeconom.2023.03.008", 1),
    "baker_larcker_wang_2022": ("10.1016/j.jfineco.2022.01.004", 1),
    "cengiz_et_al_2019": ("10.1093/qje/qjz014", 1),
    "bertrand_duflo_mullainathan_2004": ("10.1162/003355304772839588", 0),
    "abadie_2005": ("10.1111/0034-6527.00321", 0),
}
JOURNALS = {"mnsc": ("S33323087", 2019, 2026), "mksc": ("S163534328", 2013, 2026), "jmr": ("S119950638", 2019, 2026),
            "isre": ("S202812398", 2015, 2026), "msom": ("S81410195", 2015, 2026), "opre": ("S125775545", 2015, 2026), "orsc": ("S206124708", 2015, 2026),
            "jm": ("S142990027", 2015, 2026), "qme": ("S4210206015", 2015, 2026)}
# With journal keys as arguments only those journals are queried and their rows replace the same journals' rows in cites.csv.
ONLY = [a for a in sys.argv[1:] if a in JOURNALS]

ids = {}
for key, (doi, _) in METHOD.items():
    try:
        w = get(f"https://api.openalex.org/works/https://doi.org/{doi}?select=id,title,cited_by_count")
        ids[key] = w["id"].split("/")[-1]
        print(f"  {key:34s} {ids[key]}  cited_by={w['cited_by_count']}", file=sys.stderr)
    except Exception as e:
        print(f"  {key}: lookup failed {e}", file=sys.stderr)

rows = {}
for key, wid in ids.items():
    for j in (ONLY or list(JOURNALS)):
        sid, y0, y1 = JOURNALS[j]
        page = 1
        while True:
            flt = f"cites:{wid},primary_location.source.id:{sid},publication_year:{y0}-{y1}"
            d = get(f"https://api.openalex.org/works?filter={flt}&select=id,doi,title,publication_year,type&per-page=200&page={page}")
            for w in d["results"]:
                doi = (w.get("doi") or "").replace("https://doi.org/", "").lower()
                if not doi:
                    continue
                r = rows.setdefault(doi, {"doi": doi, "journal": j, "year": w.get("publication_year"), "title": w.get("title") or "", "type": w.get("type")})
                r["cite_" + key] = 1
            if len(d["results"]) < 200:
                break
            page += 1
        time.sleep(0.2)
for r in rows.values():
    for key in METHOD:
        r.setdefault("cite_" + key, 0)
    r["cite_modern"] = int(any(r["cite_" + k] for k, (_, m) in METHOD.items() if m))
    r["cite_any"] = 1
fields = ["doi", "journal", "year", "title", "type"] + ["cite_" + k for k in METHOD] + ["cite_modern", "cite_any"]
if ONLY and OUT.exists():
    for r in csv.DictReader(open(OUT, newline="")):
        if r["journal"] not in ONLY and r["doi"].lower() not in rows:
            rows[r["doi"].lower()] = r
with open(OUT, "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=fields, extrasaction="ignore"); w.writeheader(); w.writerows(sorted(rows.values(), key=lambda r: (r["journal"], r["doi"])))
c = collections.Counter((r["journal"], r["cite_modern"]) for r in rows.values())
print(f"wrote {len(rows)} citing works to {OUT}", file=sys.stderr)
for j in JOURNALS:
    print(f"  {j}: cite_any={c[(j,0)]+c[(j,1)]}  cite_modern={c[(j,1)]}", file=sys.stderr)
