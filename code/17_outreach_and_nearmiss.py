#!/usr/bin/env python3
"""From screening records: (1) data/outreach_list.csv = eligible papers whose package lacks usable data
(proprietary / synthetic / not shipped); (2) data/screening/near_miss.csv = papers with a qualifying staggered
design excluded only because every reported column carries time-varying controls or extra treatment regressors."""
import csv, importlib.util, json, pathlib, re
ROOT = pathlib.Path(__file__).resolve().parents[1]
_spec = importlib.util.spec_from_file_location("tables15", ROOT / "code/15_tables.py")
T = importlib.util.module_from_spec(_spec); _spec.loader.exec_module(T)
cand = {r["doi"].split("/")[1]: r for r in csv.DictReader(open(ROOT / "data/candidates/candidates.csv", newline=""))}
synth = set((ROOT / "data/synthetic_packages.txt").read_text().split()) if (ROOT / "data/synthetic_packages.txt").exists() else set()
out, near = [], []
# records: data/screening/by_paper/ plus the text screens and the second opinion merged by code/15_tables.py (its docstring)
for s, j in sorted(T.load_screening().items()):
    c = cand.get(s, {})
    elig = j.get("eligible") if "eligible" in j else j.get("eligible_design")
    design = j.get("eligible_design")
    da = str(j.get("data_access", "")).lower()
    files_present = j.get("data_files_present")
    reason = (str(j.get("eligible_reason", "")) + " " + str(j.get("design_notes", ""))).lower()
    base = {"suffix": s, "journal": c.get("journal", j.get("journal", "")), "year": c.get("year", j.get("year", "")),
            "title": (c.get("title") or j.get("title") or "")[:100], "authors": (c.get("authors") or "")[:120],
            "n_specs": len(j.get("specs") or []), "data_access": j.get("data_access", "")}
    prov = str(j.get("data_provenance", "")).lower()
    if (elig in (True, "true", "True") or design in (True, "true", "True")) and len(j.get("specs") or []) > 0:
        is_synth = s in synth or "synthetic" in da or "disguised" in da or "synth" in prov or "disguis" in prov or "pseudo" in prov
        no_data = "proprietary" in da or files_present in (False, "false") or "no" == da or "not_shipped" in prov
        if is_synth or no_data:
            out.append({**base, "why": "synthetic/disguised package" if is_synth else "data not shipped / proprietary"})
    inel = j.get("ineligible_specs") or []
    inel_txt = " ".join(str(x.get("eligibility", "")) + " " + str(x.get("exclusion_reason", "")) + " " + str(x.get("reason", "")) for x in inel if isinstance(x, dict)).lower()
    stag_hint = bool(re.search(r"stagger|cohort|adoption (date|month|year)s|different (times|dates)", reason + " " + inel_txt)) or (isinstance(j.get("n_adoption_cohorts"), (int, float)) and j.get("n_adoption_cohorts", 0) >= 2)
    if elig not in (True, "true", "True") and (design in (True, "true", "True") or stag_hint) and inel_txt.strip():
        reason = reason + " " + inel_txt
    if j.get("near_miss") in (True, "true", "True") and elig not in (True, "true", "True"):
        near.append({**base, "why": str(j.get("near_miss_reason", ""))[:80] or "flagged near_miss", "reason": reason[:200]}); continue
    if elig not in (True, "true", "True") and (design in (True, "true", "True") or stag_hint):
        if re.search(r"time[- ]varying control|time-varying covariate|covariates? (vary|that vary)|controls? in every|additional treatment|second (absorbing )?treatment|extra (treatment )?regressor", reason):
            near.append({**base, "why": "time-varying controls" if "control" in reason or "covariate" in reason else "additional treatment regressor",
                         "reason": reason[:200]})
for name, rows in (("data/outreach_list.csv", out), ("data/screening/near_miss.csv", near)):
    if rows:
        with open(ROOT / name, "w", newline="") as fh:
            w = csv.DictWriter(fh, fieldnames=list(rows[0].keys())); w.writeheader(); w.writerows(rows)
print(f"outreach list: {len(out)} papers; near-miss (design ok, excluded for controls/extra regressors): {len(near)} papers")
for r in near: print("  near-miss:", r["suffix"], "|", r["title"][:60], "|", r["why"])
