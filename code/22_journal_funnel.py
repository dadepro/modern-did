#!/usr/bin/env python3
"""Per-journal replication funnel (Table 3): frame -> candidates -> packages -> screened -> eligible design -> data -> re-estimated.
Writes paper/tables/journal_funnel.tex and paper/tables/journal_funnel_numbers.tex (macros).

Every count comes from code/15_tables.py (screening, eligibility, data status, re-estimation) and code/20_nearmiss_table.py
(near-misses), so Table 3 agrees with Table 2 and with the near-miss appendix by construction; see the docstring of
code/15_tables.py for the definitions. Journal of Marketing deposits are not in the frame and are reported in the text only.
Run from the project root:  python3 code/22_journal_funnel.py"""
import importlib.util
import pathlib

ROOT = pathlib.Path(__file__).resolve().parents[1]


def _load(name, fname):
    spec = importlib.util.spec_from_file_location(name, ROOT / "code" / fname)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


T = _load("tables15", "15_tables.py")
NM = _load("nearmiss20", "20_nearmiss_table.py")
J = list(T.MAIN) + list(T.EXTRA)
LAB = {"mnsc": "MS", "mksc": "MKSC", "jmr": "JMR", "isre": "ISR", "msom": "M\\&SOM", "orsc": "OrgSci", "opre": "OR"}
MAC = {"mnsc": "MS", "mksc": "MKSC", "jmr": "JMR", "isre": "ISR", "msom": "MSOM", "orsc": "OrgSci", "opre": "OR"}


def pct(a, b):
    return "--" if not b else f"{100 * a / b:.0f}"   # bare number; the text writes "percent" (review, Nov 4)


def main():
    rows = T.paper_status()
    R = T.funnel_counts(rows)
    T.check(R, rows)
    # near-misses: code/20 (flagged + keyword rule, staggered filter) for the replication journals; for the journals without an
    # archive every record is a text-screen verdict, so the screener's near-miss flag is the count
    nm_rows, _, _ = NM.classify()
    for o in nm_rows:
        if o["kept"]:
            R[o["journal"]]["nearmiss"] += 1
    for j in T.EXTRA:
        R[j]["nearmiss"] = R[j]["nm_flag"]

    # (label, key, journals for which the row is not applicable -> cell text)
    no_archive = {j: "--" for j in T.EXTRA}
    spec = [("Articles in search frame", "frame", {}),
            ("Candidates (DiD or staggered signal)", "cand", {}),
            ("\\quad of which tier 1", "tier1", {}),
            ("Replication package obtained", "pkg", {"jmr": "n/a", **{j: "n/a" for j in T.EXTRA}}),
            ("Candidates without a package", "nopkg", {"jmr": "--", **no_archive}),
            ("Papers screened", "scr", {}),
            ("\\quad of which non-candidates", "scr_noncand", no_archive),
            ("\\quad of which from the article text alone", "scr_text", {}),
            ("Candidates not screened", "notscr", {}),
            ("Eligible staggered design", "elig", {}),
            ("\\quad synthetic or disguised data", "synthetic", no_archive),
            ("\\quad analysis data not shipped", "not_shipped", no_archive),
            ("\\quad no replication package", "no_package", {}),
            ("\\quad usable data", "usable", no_archive),
            ("\\qquad re-estimated on original data", "reestimated", no_archive),
            ("\\qquad not re-estimated", "usable_not_reestimated", no_archive),
            ("midrule", None, None),
            ("Near-miss (no qualifying specification)", "nearmiss", {})]
    tex = ["\\begin{tabular}{l" + "r" * len(J) + "}", "\\toprule", " & " + " & ".join(LAB[j] for j in J) + " \\\\", "\\midrule"]
    for lab, k, na in spec:
        if k is None:
            tex.append("\\midrule")
            continue
        tex.append(f"{lab} & " + " & ".join(na.get(j) or T.fmt(R[j][k]) for j in J) + " \\\\")
    tex += ["\\midrule",
            "Usable data / eligible design & " + " & ".join(pct(R[j]["usable"], R[j]["elig"]) if j in T.MAIN else "--" for j in J) + " \\\\",
            "Re-estimated / candidates & " + " & ".join(pct(R[j]["reestimated"], R[j]["cand"]) if j in T.MAIN else "--" for j in J) + " \\\\",
            "\\bottomrule", "\\end{tabular}"]
    (ROOT / "paper/tables/journal_funnel.tex").write_text("\n".join(tex) + "\n")

    # per-journal macros (totals over the three journals are in numbers.tex; near-miss counts in near_miss_numbers.tex)
    mac = {}
    for j in T.MAIN:
        m, k = MAC[j], R[j]
        mac.update({f"fn{m}cand": k["cand"], f"fn{m}tierone": k["tier1"], f"fn{m}screened": k["scr"],
                    f"fn{m}screenedCand": k["scr_cand"], f"fn{m}noncand": k["scr_noncand"],
                    f"fn{m}design": k["elig"], f"fn{m}designNoncand": k["elig_noncand"],
                    f"fn{m}synth": k["synthetic"], f"fn{m}notshipped": k["not_shipped"], f"fn{m}nopkg": k["no_package"],
                    f"fn{m}usable": k["usable"], f"fn{m}rep": k["reestimated"], f"fn{m}notrep": k["usable_not_reestimated"],
                    f"fn{m}text": k["scr_text"], f"fn{m}notscr": k["notscr"], f"fn{m}nearmiss": k["nearmiss"],
                    f"fn{m}usablePct": pct(k["usable"], k["elig"])})
        if j != "jmr":
            mac[f"fn{m}pkg"] = k["pkg"]
    for j in T.EXTRA:
        mac.update({f"fn{MAC[j]}cand": R[j]["cand"], f"fn{MAC[j]}tierone": R[j]["tier1"], f"fn{MAC[j]}screened": R[j]["scr"],
                    f"fn{MAC[j]}notscr": R[j]["notscr"], f"fn{MAC[j]}design": R[j]["elig"], f"fn{MAC[j]}nearmiss": R[j]["nearmiss"]})
    (ROOT / "paper/tables/journal_funnel_numbers.tex").write_text(
        "".join(f"\\newcommand{{\\{k}}}{{{T.fmt(v) if isinstance(v, int) else v}}}\n" for k, v in mac.items()))
    print("\n".join(tex))
    print(mac)


if __name__ == "__main__":
    main()
