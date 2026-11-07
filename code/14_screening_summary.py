#!/usr/bin/env python3
"""Aggregate per-paper screening JSONs into data/screening/screened.csv and print the funnel.
Also lists eligible papers whose replication package is already extracted (ready for replication)."""
import csv, json, pathlib, collections
ROOT = pathlib.Path(__file__).resolve().parents[1]
PK = pathlib.Path.home() / "did_packages"
cand = {r["doi"].split("/")[1]: r for r in csv.DictReader(open(ROOT / "data/candidates/candidates.csv", newline=""))}
rows = []
for f in sorted((ROOT / "data/screening/by_paper").glob("*.json")):
    try:
        j = json.load(open(f))
    except Exception as e:
        print("bad json", f.name, e); continue
    suffix = f.stem; c = cand.get(suffix, {})
    specs = j.get("specs") or []
    elig = j.get("eligible") if "eligible" in j else j.get("eligible_design")
    rows.append({
        "suffix": suffix, "journal": c.get("journal", j.get("journal", "")), "year": c.get("year", j.get("year", "")),
        "tier": c.get("tier", ""), "title": (c.get("title") or j.get("title") or "")[:90],
        "eligible": elig, "n_specs": j.get("n_eligible_specs", len(specs)), "n_spec_records": len(specs),
        "reports_modern": j.get("reports_modern_estimator"), "modern_named": ";".join(j.get("modern_estimators_named") or []),
        "main_or_robustness": j.get("main_or_robustness", ""), "data_access": j.get("data_access", ""),
        "software": j.get("software", ""), "replication_feasible": j.get("replication_feasible", ""),
        "priority": j.get("priority", ""), "n_cohorts": j.get("n_adoption_cohorts", ""),
        "never_treated": j.get("never_treated_present", ""),
        "package_extracted": (PK / c.get("journal", "x") / suffix).exists(),
        "reason": (j.get("eligible_reason") or j.get("design_notes") or "")[:140],
    })
with open(ROOT / "data/screening/screened.csv", "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=list(rows[0].keys())); w.writeheader(); w.writerows(rows)
tot = len(rows); el = [r for r in rows if r["eligible"] in (True, "true", "True")]
print(f"screened {tot}; eligible {len(el)}; eligible with package extracted {sum(1 for r in el if r['package_extracted'])}")
print("by journal/tier:", dict(collections.Counter((r['journal'], r['tier'], 'elig' if r in el else 'no') for r in rows)))
print("\nEligible papers:")
for r in el:
    print(f"  {r['suffix']:22s} {r['journal']} {r['year']} t{r['tier']} specs={r['n_spec_records']:>2} modern={r['reports_modern']} data={r['data_access']:11s} pkg={'Y' if r['package_extracted'] else '-'} | {r['title'][:60]}")
