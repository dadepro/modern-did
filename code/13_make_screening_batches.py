#!/usr/bin/env python3
"""Group candidate papers that have article text and/or a replication package into
screening batches (data/screening/batches/batch_<tier>_<n>.json), 8 papers each,
skipping papers already screened (data/screening/by_paper/<suffix>.json)."""
import csv, json, pathlib
ROOT = pathlib.Path(__file__).resolve().parents[1]
PK = pathlib.Path.home() / "did_packages"
cand = list(csv.DictReader(open(ROOT / "data/candidates/candidates.csv", newline="")))
done = {p.stem for p in (ROOT / "data/screening/by_paper").glob("*.json")}
batched = set()
for b in (ROOT / "data/screening/batches").glob("*.json"):
    for p in json.load(open(b)):
        batched.add(p["suffix"])
items = []
for r in cand:
    if r["tier"] not in ("1", "2", "3"):
        continue
    suffix = r["doi"].split("/")[1]; j = r["journal"]
    txt = ROOT / "data/text" / j / f"{suffix}.txt"
    pkg = PK / j / suffix
    regs = ROOT / "data/packages" / f"{suffix}_regressions.txt"
    if not txt.exists() and not pkg.exists():
        continue
    if suffix in done or suffix in batched:
        continue
    items.append({"suffix": suffix, "doi": r["doi"], "journal": j, "year": r["year"], "tier": r["tier"],
                  "title": r["title"], "authors": r["authors"][:120],
                  "text_path": str(txt) if txt.exists() else "",
                  "package_dir": str(pkg) if pkg.exists() else "",
                  "regressions_path": str(regs) if regs.exists() else "",
                  "flags": ",".join(k for k, v in r.items() if (k.startswith("ft_") or k.startswith("cite_")) and v == "1")})
items.sort(key=lambda x: (int(x["tier"]), x["journal"]))
n_existing = len(list((ROOT / "data/screening/batches").glob("*.json")))
made = 0
for t in ("1", "2", "3"):
    its = [x for x in items if x["tier"] == t]
    for i in range(0, len(its), 8):
        n_existing += 1; made += 1
        json.dump(its[i:i + 8], open(ROOT / f"data/screening/batches/batch_t{t}_{n_existing:03d}.json", "w"), indent=1)
print(f"{len(items)} papers queued into {made} new batches; already screened {len(done)}; previously batched {len(batched)}")
