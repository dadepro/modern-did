#!/usr/bin/env python3
"""Parse the compact hit-list readout copied from the browser into raw hit JSON files.

Input format (one record per line):
  journal|query|page|count|<space-separated DOI suffixes>
where a suffix like 2023.01168 expands to 10.1287/<journal>.2023.01168.
Usage: python3 code/02b_parse_readout.py data/hits/readout_mnsc.txt
"""
import json, pathlib, re, sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
RAW = ROOT / "data" / "hits" / "raw"
RAW.mkdir(parents=True, exist_ok=True)

def main(path):
    text = pathlib.Path(path).read_text()
    n_rec, n_doi = 0, 0
    for line in text.splitlines():
        line = line.strip()
        if not line or "|" not in line:
            continue
        journal, query, page, count, dois = line.split("|", 4)
        # DOI prefix and suffix pattern by journal: INFORMS 10.1287/<j>.YYYY.NNNN ; SAGE (JMR) 10.1177/<digits>
        prefix, pat = (f"10.1287/{journal}.", r"[0-9]{2,4}\.[0-9A-Za-z.]+") if journal in ("mnsc", "mksc", "isre", "msom", "opre", "orsc") else ("10.1177/", r"[0-9A-Za-z._-]{8,}")
        if journal in ("jm", "qme"):
            # JM (SAGE, 10.1177/... and pre-2019 10.1509/jm.*) and QME (Springer, 10.1007/s11129-...): tokens are full DOIs
            prefix, pat = "", r"10\.\d{4,5}/[0-9A-Za-z._/-]+"
        suffixes = [s for s in dois.split() if re.fullmatch(pat, s)]
        bad = [s for s in dois.split() if s not in suffixes]
        if bad:
            print(f"  WARNING {journal} {query} p{page}: {len(bad)} malformed tokens: {bad[:5]}", file=sys.stderr)
        rec = {
            "journal": journal, "query": query, "page": int(page),
            "count": count.replace(",", "") if count not in ("null", "") else None,
            "dois": [f"{prefix}{s}" for s in suffixes],
        }
        safe = lambda s: re.sub(r"[^A-Za-z0-9._-]+", "_", str(s))[:60]
        fn = RAW / f"{safe(journal)}__{safe(query)}__p{int(page)}.json"
        fn.write_text(json.dumps(rec, indent=0))
        n_rec += 1; n_doi += len(rec["dois"])
        print(f"  {fn.name}: {len(rec['dois'])} dois (count={rec['count']})")
    print(f"wrote {n_rec} records, {n_doi} dois")

if __name__ == "__main__":
    main(sys.argv[1])
