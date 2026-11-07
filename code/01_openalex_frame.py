#!/usr/bin/env python3
"""Pull the bibliographic frame for Management Science, Marketing Science and JMR from OpenAlex.

Windows follow each journal's replication-archive start (Hull 2026 logic):
  Management Science : 2019-2026 (Code & Data Disclosure Policy effective June 1, 2019)
  Marketing Science  : 2013-2026 (Replication policy, Jan-Feb 2013 editorial)
  JMR                : 2019-2026 (transparency policy July 2023; Dataverse mostly restricted)
Output: data/frame/<journal>.jsonl and data/frame/frame.csv
"""
import json, sys, time, csv, urllib.request, urllib.parse, pathlib

ROOT = pathlib.Path(__file__).resolve().parents[1]
OUT = ROOT / "data" / "frame"
OUT.mkdir(parents=True, exist_ok=True)
HDR = {"User-Agent": "diff-in-diff-replica (mailto:proserpi@marshall.usc.edu)"}
BASE = "https://api.openalex.org/works"

JOURNALS = {
    "mnsc": ("Management Science", "S33323087", 2019, 2026),
    "mksc": ("Marketing Science", "S163534328", 2013, 2026),
    "jmr":  ("Journal of Marketing Research", "S119950638", 2019, 2026),
    # added Nov 1, 2026 (not in Hull 2026): other INFORMS journals with the same replication-file form
    "isre": ("Information Systems Research", "S202812398", 2015, 2026),
    "msom": ("Manufacturing & Service Operations Management", "S81410195", 2015, 2026),
    "opre": ("Operations Research", "S125775545", 2015, 2026),
    "orsc": ("Organization Science", "S206124708", 2015, 2026),
}
FIELDS = ",".join([
    "id","doi","title","publication_year","publication_date","type","biblio",
    "authorships","cited_by_count","open_access","best_oa_location","primary_location",
    "locations","primary_topic","keywords","abstract_inverted_index","is_retracted",
])

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
def get(url, tries=5):
    for k in range(tries):
        try:
            with urllib.request.urlopen(urllib.request.Request(with_key(url), headers=HDR), timeout=90) as r:
                return json.load(r)
        except Exception as e:
            time.sleep(2 * (k + 1))
            err = e
    raise err

def abstract_from_index(idx):
    if not idx:
        return ""
    pos = {}
    for w, ps in idx.items():
        for p in ps:
            pos[p] = w
    return " ".join(pos[k] for k in sorted(pos))

def pull(key, name, sid, y0, y1):
    # Page-based paging (cursor paging requires an OpenAlex API key as of 2026).
    # Pull year by year so each query stays far below the 10,000-result page limit.
    rows, n = [], 0
    for yr in range(y0, y1 + 1):
        page = 1
        while True:
            flt = f"primary_location.source.id:{sid},publication_year:{yr}"
            url = f"{BASE}?filter={flt}&select={FIELDS}&per-page=200&page={page}"
            d = get(url)
            for w in d["results"]:
                w["abstract"] = abstract_from_index(w.pop("abstract_inverted_index", None))
                w["journal_key"] = key
                rows.append(w)
            n += len(d["results"])
            if len(d["results"]) < 200:
                break
            page += 1
        print(f"  {name} {yr}: cumulative {n}", file=sys.stderr)
    with open(OUT / f"{key}.jsonl", "w") as f:
        for w in rows:
            f.write(json.dumps(w) + "\n")
    return rows

def flatten(w):
    doi = (w.get("doi") or "").replace("https://doi.org/", "")
    auth = w.get("authorships") or []
    oa = w.get("best_oa_location") or {}
    pl = w.get("primary_location") or {}
    oa_srcs = sorted({(l.get("source") or {}).get("display_name", "") for l in (w.get("locations") or []) if l.get("is_oa")} - {""})
    return {
        "journal_key": w["journal_key"],
        "openalex_id": w["id"].split("/")[-1],
        "doi": doi,
        "year": w.get("publication_year"),
        "date": w.get("publication_date"),
        "type": w.get("type"),
        "volume": (w.get("biblio") or {}).get("volume"),
        "issue": (w.get("biblio") or {}).get("issue"),
        "first_page": (w.get("biblio") or {}).get("first_page"),
        "title": w.get("title") or "",
        "n_authors": len(auth),
        "authors": "; ".join((a.get("author") or {}).get("display_name", "") for a in auth),
        "institutions": "; ".join(sorted({i.get("display_name", "") for a in auth for i in (a.get("institutions") or [])} - {""})),
        "cited_by": w.get("cited_by_count"),
        "is_oa": (w.get("open_access") or {}).get("is_oa"),
        "oa_url": (w.get("open_access") or {}).get("oa_url") or "",
        "oa_pdf_url": oa.get("pdf_url") or "",
        "oa_sources": "; ".join(oa_srcs),
        "landing_url": pl.get("landing_page_url") or "",
        "topic": (w.get("primary_topic") or {}).get("display_name", ""),
        "subfield": ((w.get("primary_topic") or {}).get("subfield") or {}).get("display_name", ""),
        "abstract_len": len(w.get("abstract") or ""),
        "abstract": w.get("abstract") or "",
    }

if __name__ == "__main__":
    allrows = []
    for key, (name, sid, y0, y1) in JOURNALS.items():
        allrows += pull(key, name, sid, y0, y1)
    flat = [flatten(w) for w in allrows]
    with open(OUT / "frame.csv", "w", newline="") as f:
        wr = csv.DictWriter(f, fieldnames=list(flat[0].keys()))
        wr.writeheader(); wr.writerows(flat)
    print(f"wrote {len(flat)} records to {OUT/'frame.csv'}", file=sys.stderr)
