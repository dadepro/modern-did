#!/usr/bin/env python3
"""High-cardinality characteristics check (Nov 4 2026, PI decision (b)): numbers behind the Section 3 paragraph.

Since Nov 4 a time-invariant characteristic with more than XT_MAX_LEVELS (60) categories is dropped from ALL estimators of a
specification (run_spec.R preamble, note xt_dropped_all_highcard), because the DiD-averaging cell regressions are not identified
with that many indicators. Before, it was dropped from DiD-averaging only, so TWFE and imputation kept the authors' industry-by-
year effects while DiD-averaging omitted them. This script quantifies what that asymmetry did in the paper that accounts for most
of these comparisons, and summarizes the two alternatives tried on that paper's Table 2 (scratchpad diagnostic copied to
output/xt_check/specs/: *_xtA = all 260 four-digit dummies in DiD-averaging, *_xtB = two-digit sectors, *_xtC = no industry
effects in any estimator).

Inputs:  output/xt_check/specs/*.csv (the diagnostic variants). The sign-reversal counts of the asymmetric and like-with-like
         comparisons come from analysis.R (macros *XtAsym, *XtLike), not from here.
Output:  paper/tables/xt_check_numbers.tex (macros) and a printout. Run from the project root after analysis.R:
         python3 code/24_xt_check.py"""
import collections
import csv
import pathlib
import re
import statistics

ROOT = pathlib.Path(__file__).resolve().parents[1]


def num(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def main():
    paper = "mnsc.2020.01838"   # the paper that accounts for most high-cardinality comparisons (analysis.R reports the counts)
    # diagnostic variants on the paper's Table 2 (Panel A)
    var = collections.defaultdict(dict)
    for f in (ROOT / "output/xt_check/specs").glob(f"{paper}__*_xt[ABC].csv"):
        m = re.match(r"(.*)_xt([ABC])$", f.stem.split("__", 1)[1])
        if not m:
            continue
        base, v = m.groups()
        rows = [r for r in csv.DictReader(open(f)) if r.get("window") != "pre"]
        if rows:
            var[base][v] = rows[0]
    full_rankdef = sum(1 for d in var.values() if "A" in d and "covariate_cells_rank_deficient" in (d["A"].get("csa_note") or "") and num(d["A"].get("csa")) is None)
    n_full = sum(1 for d in var.values() if "A" in d)
    ratios = [num(d["B"]["csa_se"]) / num(d["C"]["csa_se"]) for d in var.values()
              if "B" in d and "C" in d and num(d["B"].get("csa_se")) and num(d["C"].get("csa_se"))]
    se_ratio = statistics.median(ratios) if ratios else float("nan")
    # two-digit variant: cells the did package could not estimate (csa_note "csa_na_cells:<na>/<total>"), most common value
    cells = collections.Counter()
    for d in var.values():
        mm = re.search(r"csa_na_cells:(\d+)/(\d+)", (d.get("B") or {}).get("csa_note") or "")
        if mm:
            cells[(int(mm.group(2)) - int(mm.group(1)), int(mm.group(2)))] += 1
    used, tot = cells.most_common(1)[0][0] if cells else (float("nan"), float("nan"))
    mac = {"xtFullRankDef": full_rankdef, "xtFullTried": n_full, "xtTwoDigitCellsUsed": used, "xtTwoDigitCells": tot,
           "xtTwoDigitSeRatio": f"{se_ratio:.1f}", "xtTwoDigitN": len(ratios)}
    (ROOT / "paper/tables/xt_check_numbers.tex").write_text("".join(f"\\newcommand{{\\{k}}}{{{v}}}\n" for k, v in mac.items()))
    print(f"full four-digit dummies: {full_rankdef} of {n_full} Table 2 specs with every cell rank-deficient; two-digit sectors: median SE ratio {se_ratio:.2f} over {len(ratios)} specs")
    print(mac)


if __name__ == "__main__":
    main()
