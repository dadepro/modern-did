#!/usr/bin/env python3
"""Mark screening records ineligible after replication-stage verification.
Usage: python3 code/18_mark_ineligible.py <suffix> "<reason>" [near_miss_reason]"""
import json, sys, pathlib
ROOT = pathlib.Path(__file__).resolve().parents[1]
suffix, reason = sys.argv[1], sys.argv[2]
nm = sys.argv[3] if len(sys.argv) > 3 else ""
p = ROOT / "data/screening/by_paper" / f"{suffix}.json"
j = json.load(open(p))
j.setdefault("ineligible_specs", [])
if j.get("specs"):
    j["ineligible_specs"] = (j.get("ineligible_specs") or []) + j["specs"]
j["specs"] = []; j["n_eligible_specs"] = 0; j["eligible"] = False
j["eligible_design"] = True if nm else j.get("eligible_design")
j["near_miss"] = bool(nm); j["near_miss_reason"] = nm
j["eligible_reason"] = f"Replication-stage verification ({'data/replication_logs/' + suffix + '.md'}): {reason}"
j["replication_feasible"] = "no"; j["priority"] = 3
json.dump(j, open(p, "w"), indent=1); print("marked ineligible:", suffix)
