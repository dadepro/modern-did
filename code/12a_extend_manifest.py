#!/usr/bin/env python3
"""Append candidate papers (tiers 1-3) from INFORMS journals not yet in package_manifest.csv.
Ordering within the appended block: tier, then staggered/modern signal, then citations."""
import csv, pathlib
ROOT = pathlib.Path(__file__).resolve().parents[1]
MAN = ROOT / "data/candidates/package_manifest.csv"; CAND = ROOT / "data/candidates/candidates.csv"
INFORMS = {"mnsc", "mksc", "isre", "msom", "opre", "orsc"}
man = list(csv.DictReader(open(MAN, newline=""))); have = {r["suffix"] for r in man}
cand = [r for r in csv.DictReader(open(CAND, newline="")) if r["journal"] in INFORMS and r["tier"] in ("1", "2", "3")]
def score(r):
    sig = int(r.get("ft_staggered", 0) or 0) + int(r.get("cite_modern", 0) or 0) + sum(int(r.get(k, 0) or 0) for k in ("ft_callaway", "ft_goodman_bacon", "ft_borusyak", "ft_sun_and_abraham", "ft_de_chaisemartin"))
    return (int(r["tier"]), -sig, -int(r["cited_by"] or 0))
new = sorted([r for r in cand if r["doi"].split("/")[-1] not in have], key=score)
order = max(int(r["order"]) for r in man) if man else 0
for r in new:
    order += 1; suf = r["doi"].split("/")[-1]
    man.append({"order": order, "journal": r["journal"], "doi": r["doi"], "suffix": suf, "tier": r["tier"], "year": r["year"],
                "form_url": f"https://services.informs.org/dataset/{r['journal']}/download.php?doi={suf}", "status": "", "size_mb": ""})
with open(MAN, "w", newline="") as fh:
    w = csv.DictWriter(fh, fieldnames=["order", "journal", "doi", "suffix", "tier", "year", "form_url", "status", "size_mb"]); w.writeheader(); w.writerows(man)
import collections; print(f"appended {len(new)} rows; manifest now {len(man)} rows:", dict(collections.Counter(r['journal'] for r in man)))
