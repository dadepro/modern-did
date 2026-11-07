#!/usr/bin/env python3
"""Sample-construction counts: the single source of every count in Tables 1-3 and in the text macros.

Writes paper/tables/candidates.tex (Table 1), paper/tables/funnel.tex (Table 2), paper/tables/numbers.tex (macros) and
output/tables/funnel_paper_status.csv (one row per paper with the status behind every count). code/22_journal_funnel.py
(Table 3) and code/20_nearmiss_table.py (near-miss appendix) import the functions below, so all three scripts use one
definition of each count. Run from the project root:  python3 code/15_tables.py

Definitions (source in brackets)
  frame        research articles (type == "article") in the journal window                [data/frame/frame.csv]
  candidate    frame article with tier 1, 2 or 3 (DiD language or citation, or abstract signal)
                                                                                         [data/candidates/candidates.csv]
  tier 1       candidate with tier == 1                                                   [same]
  package      candidate whose replication package was downloaded (status "downloaded")
                                                                                         [data/candidates/package_manifest.csv]
  screened     paper with a completed screening record: data/screening/by_paper/<suffix>.json (not "_stale*") with
               eligible_design true or false. A record with eligible_design null could not be assessed (wrong or unreadable
               file) and counts as not screened. A paper can be screened without being a candidate: Management Science
               full-text search hits missing from the OpenAlex frame (data/candidates/hits_not_in_frame.csv) and Marketing
               Science packages screened beyond the candidate list. Journal of Marketing deposits (DOI prefix 00222429) are
               outside the frame and reported in the text only.
               Text screens (Nov 5): candidates without a package, and every candidate of the four journals without an
               archive, were screened from the article text alone; the verdicts are in data/screening/other_journals/*.json
               (one list per journal, plus mnsc_nopackage_screen_nov5.json). load_screening() converts each verdict to a
               record (text_screen_record) for suffixes without a by_paper record, so they count as screened here and in
               code/17, code/20 and code/22. The Marketing Science second opinion (data/screening/second_opinion/
               mksc_rescreen_nov5.json, PROTOCOL ruling (x)) adds a near-miss flag to first-screen records it relabels
               "near-miss" and supplies records for candidates the first screen never reached; its two "eligible"
               relabels of first-screen near-misses await a ruling and are not applied.
  text only    screened record that came from a text screen (screened_from == "article_text")
  eligible     screened paper with eligible_design true AND n_eligible_specs >= 1: at least one main-text specification
               meets every design rule, whatever the data (PROTOCOL.md coding rule of Nov 1). Records coded before that
               rule also set eligible_design = true for staggered designs with no qualifying column; the n_eligible_specs
               condition excludes them. The "eligible" field of the records (and of screened.csv) is not used: in some
               records it also encodes data availability.
  data status  of an eligible paper; mutually exclusive, assigned in this order:
    re-estimated            >= 1 current specification on original data: spec JSON in data/specs/ (not
                            data/specs_excluded/) with output in output/specs/, paper not in data/synthetic_packages.txt,
                            JSON data_provenance not synthetic/disguised/pseudo/simulated/scrambled/fuzzed. This is the
                            analysis sample of code/R/analysis.R.
    synthetic               paper in data/synthetic_packages.txt; or the screening record's data_provenance or data_access
                            labels the package data synthetic, disguised, pseudo, simulated, scrambled or fuzzed; or every
                            current spec JSON of the paper is synthetic
    no package              eligible design screened from the article text alone: no replication package was obtained
                            (none on the server, or the server advertises data files it does not return; see
                            data/packages/advertised_but_missing_nov5.json). The journals without an archive fall here.
    not shipped             data_files_present false, or data_provenance "not shipped"
    usable, not re-estimated the rest (the package ships the data but no specification is re-estimated, for example
                            because every specification was excluded when the package did not reproduce the published
                            estimate)
    usable = re-estimated + usable, not re-estimated
"""
import collections
import csv
import json
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parents[1]
OUT = ROOT / "paper" / "tables"
MAIN = ("mnsc", "mksc", "jmr")              # replication journals (Tables 1-2)
EXTRA = ("isre", "msom", "orsc", "opre")    # frame-only journals (Table 3)
LONG = {"mnsc": r"\emph{Management Science}, 2019--2026", "mksc": r"\emph{Marketing Science}, 2013--2026",
        "jmr": r"\emph{Journal of Marketing Research}, 2019--2026"}
SPEC_SYN = re.compile(r"synth|disguis|pseudo|simulat|scrambl|fuzz", re.I)
SYN_LABEL = re.compile(r"\s*(?:partial_)?(?:synth|disguis|pseudo|simulat|scrambl|fuzz)", re.I)   # leading label only
SYN_DATA = re.compile(r"\b(?:pseudo|synthetic|disguised|simulated|scrambled|fuzzed)[- ]data", re.I)  # "ships ... pseudo-data"
DATA_STATUSES = ("reestimated", "usable_not_reestimated", "synthetic", "not_shipped", "no_package")
TEXT_SCREENS = "data/screening/other_journals/*.json"                       # first-pass text screens (one list per journal)
SECOND_OPINION = "data/screening/second_opinion/mksc_rescreen_nov5.json"    # Marketing Science second opinion (Fable)
TEXT_ONLY = "article_text"                                                  # screened_from value of a text-screen record


def truthy(v):
    return v in (True, "true", "True", 1)


def fmt(n):
    return f"{n:,}"


def journal_of(suffix):
    if suffix.startswith("00222437"):
        return "jmr"
    if suffix.startswith("00222429"):
        return "jm"            # Journal of Marketing: outside the frame, text only
    return suffix.split(".")[0]


def read_csv(p):
    return list(csv.DictReader(open(p, newline="", encoding="utf-8")))


def load_frame():
    return collections.Counter(r["journal_key"] for r in read_csv(ROOT / "data/frame/frame.csv") if r["type"] == "article")


def load_candidates():
    return {r["doi"].split("/")[-1]: r for r in read_csv(ROOT / "data/candidates/candidates.csv") if r["tier"] in ("1", "2", "3")}


def load_packages():
    p = ROOT / "data/candidates/package_manifest.csv"
    return {r["suffix"]: r.get("status", "") for r in read_csv(p)} if p.exists() else {}


def text_screen_record(v):
    """A text-screen verdict ({suffix, verdict, reason, design, qualifying_specs, data_statement, ...}) in the by_paper record
    schema. The paper has no replication package, so data_files_present is false and the data status is "no package"."""
    nq = len(v.get("qualifying_specs") or []) if v.get("verdict") == "eligible" else 0
    return {"suffix": v["suffix"], "journal": v.get("journal") or journal_of(v["suffix"]), "screened_from": TEXT_ONLY,
            "eligible_design": v.get("verdict") == "eligible", "n_eligible_specs": nq, "specs": v.get("qualifying_specs") or [],
            "near_miss": v.get("verdict") == "near-miss", "near_miss_reason": v.get("reason", "") if v.get("verdict") == "near-miss" else "",
            "eligible_reason": v.get("reason", ""), "design_notes": v.get("design", ""), "confidence": v.get("confidence"),
            "data_access": v.get("data_statement", ""), "data_files_present": False, "data_provenance": "no package",
            "text_screen_source": v.get("source", "")}


def load_text_screens():
    out = []
    for f in sorted(ROOT.glob(TEXT_SCREENS)):
        out += json.load(open(f, encoding="utf-8"))
    return out


def load_screening(with_text_screens=True):
    recs = {}
    for f in sorted((ROOT / "data/screening/by_paper").glob("*.json")):
        if f.name.startswith("_stale"):
            continue
        try:
            recs[f.stem] = json.load(open(f, encoding="utf-8"))
        except Exception as e:  # noqa: BLE001
            print("unreadable screening record", f.name, e)
    if not with_text_screens:
        return recs
    for v in load_text_screens():                      # candidates never screened from a package
        if v["suffix"] not in recs:
            recs[v["suffix"]] = text_screen_record(v)
    so = ROOT / SECOND_OPINION
    for v in (json.load(open(so, encoding="utf-8")) if so.exists() else []):
        rec = recs.get(v["suffix"])
        if rec is None:                                # first screen never reached the paper (no package)
            recs[v["suffix"]] = text_screen_record(v)
        elif v["verdict"] == "near-miss" and not is_eligible(rec) and not truthy(rec.get("near_miss")):
            rec.update(near_miss=True, near_miss_reason=v.get("reason", ""), second_opinion="near-miss")
        # second-opinion "eligible" on a first-screen near-miss (mksc.2017.1043, mksc.2019.1176): ruled near-miss (Nov 5), not applied
    return recs


def is_screened(rec):
    return rec is not None and rec.get("eligible_design") is not None


def n_qualifying(rec):
    n = rec.get("n_eligible_specs")
    if n is None:
        n = len(rec.get("specs") or [])
    try:
        return int(n)
    except (TypeError, ValueError):
        return 0


def is_eligible(rec):
    return is_screened(rec) and truthy(rec.get("eligible_design")) and n_qualifying(rec) > 0


def synthetic_list():
    p = ROOT / "data/synthetic_packages.txt"
    return set(p.read_text().split()) if p.exists() else set()


def spec_sets():
    """Current specifications: a spec JSON in data/specs/ and its output in output/specs/ (output files of excluded
    specifications are ignored, as in analysis.R). Returns (all current, current on original data, papers re-estimated
    on original data, papers with any current specification)."""
    synth_list = synthetic_list()
    specs = sorted(f for f in (ROOT / "output/specs").glob("*.csv") if (ROOT / "data/specs" / (f.stem + ".json")).exists())
    synth = set()
    for f in specs:
        try:
            prov = str(json.load(open(ROOT / "data/specs" / (f.stem + ".json"))).get("data_provenance", "real") or "real")
        except Exception:  # noqa: BLE001
            prov = "real"
        if f.name.split("__")[0] in synth_list or (SPEC_SYN.search(prov) and not re.match(r"\s*(real|original)", prov, re.I)):
            synth.add(f.stem)
    real = [f for f in specs if f.stem not in synth]
    return specs, real, {f.name.split("__")[0] for f in real}, {f.name.split("__")[0] for f in specs}


def data_status(suffix, rec, reest, spec_papers, synth_list):
    if suffix in reest:
        return "reestimated"
    prov, da = str(rec.get("data_provenance") or ""), str(rec.get("data_access") or "")
    if suffix in synth_list or SYN_LABEL.match(prov) or SYN_LABEL.match(da) or SYN_DATA.search(da) or suffix in spec_papers:
        return "synthetic"
    if rec.get("screened_from") == TEXT_ONLY:
        return "no_package"
    if rec.get("data_files_present") in (False, "false", "False") or re.search(r"\bnot[_ ]shipped\b", prov, re.I):
        return "not_shipped"
    return "usable_not_reestimated"


def gap_reason(suffix):
    if list((ROOT / "data/specs_pending_data").glob(suffix + "__*.json")):
        return "awaiting data"
    if list((ROOT / "data/specs_excluded").glob(suffix + "__*.json")):
        return "all specifications excluded at replication"
    return "no specification JSON"


def paper_status():
    """One row per candidate (any journal) or screening record."""
    cand, pkg, recs = load_candidates(), load_packages(), load_screening()
    synth_list = synthetic_list()
    _, _, reest, spec_papers = spec_sets()
    rows = []
    for s in sorted(set(cand) | set(recs)):
        c, rec = cand.get(s), recs.get(s)
        st = {"suffix": s, "journal": c["journal"] if c else journal_of(s), "candidate": c is not None,
              "tier": c["tier"] if c else "", "package": pkg.get(s, "") == "downloaded", "package_status": pkg.get(s, ""),
              "record": rec is not None, "screened": is_screened(rec), "eligible": is_eligible(rec),
              # JMR has no public packages (restricted Dataverse), so every JMR candidate was screened from the article (Nov 6)
              "text_only": rec is not None and (rec.get("screened_from") == TEXT_ONLY
                                                or ((c["journal"] if c else journal_of(s)) == "jmr" and is_screened(rec))),
              "near_miss": rec is not None and truthy(rec.get("near_miss")) and not is_eligible(rec),
              "n_qualifying_specs": n_qualifying(rec) if rec else "", "data_status": "", "gap_reason": "",
              "reestimated": s in reest}
        if st["eligible"]:
            st["data_status"] = data_status(s, rec, reest, spec_papers, synth_list)
            if st["data_status"] == "usable_not_reestimated":
                st["gap_reason"] = gap_reason(s)
        rows.append(st)
    return rows


def funnel_counts(rows=None):
    rows = paper_status() if rows is None else rows
    R = collections.defaultdict(collections.Counter)
    for j, n in load_frame().items():
        R[j]["frame"] = n
    for r in rows:
        k = R[r["journal"]]
        if r["candidate"]:
            k["cand"] += 1
            k["tier" + r["tier"]] += 1
            k["pkg"] += r["package"]
            k["scr_cand" if r["screened"] else ("unassessable" if r["record"] else "notscr")] += 1
        elif r["screened"]:
            k["scr_noncand"] += 1
        elif r["record"]:
            k["unassessable_noncand"] += 1
        k["scr"] += r["screened"]
        k["scr_text"] += r["screened"] and r["text_only"]
        k["nm_flag"] += r["screened"] and r["near_miss"]          # screener-flagged near-misses (Table 3 uses code/20 for MAIN)
        if r["eligible"]:
            k["elig"] += 1
            k["elig_cand" if r["candidate"] else "elig_noncand"] += 1
            k[r["data_status"]] += 1
            k["usable"] += r["data_status"] in ("reestimated", "usable_not_reestimated")
        k["reest_any"] += r["reestimated"]
    for k in R.values():
        k["nopkg"] = k["cand"] - k["pkg"]
    return R


def check(R, rows):
    """Partition identities; raises if any fails."""
    _, _, reest, _ = spec_sets()
    bad = [f"{r['suffix']}: candidate not screened although its package was downloaded (Table 2 row label)"
           for r in rows if r["candidate"] and r["journal"] in MAIN and not r["record"] and r["package"]]
    for j in MAIN:
        k = R[j]
        tests = {"candidates = screened + not assessable + not screened": k["cand"] == k["scr_cand"] + k["unassessable"] + k["notscr"],
                 "screened = candidates screened + non-candidates screened": k["scr"] == k["scr_cand"] + k["scr_noncand"],
                 "eligible = synthetic + not shipped + no package + usable":
                     k["elig"] == k["synthetic"] + k["not_shipped"] + k["no_package"] + k["usable"],
                 "text-only screens are candidates without a package": k["scr_text"] <= k["cand"] - k["pkg"],
                 "usable = re-estimated + not re-estimated": k["usable"] == k["reestimated"] + k["usable_not_reestimated"],
                 "every re-estimated paper is an eligible design": k["reest_any"] == k["reestimated"]}
        bad += [f"{j}: {t}" for t, ok in tests.items() if not ok]
    if sum(R[j]["reestimated"] for j in MAIN) != len(reest):
        bad.append(f"re-estimated papers in the funnel ({sum(R[j]['reestimated'] for j in MAIN)}) != papers with a current spec on original data ({len(reest)})")
    if bad:
        raise SystemExit("funnel check failed:\n  " + "\n  ".join(bad))


def total(R, key, journals=MAIN):
    return sum(R[j][key] for j in journals)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    rows = paper_status()
    R = funnel_counts(rows)
    check(R, rows)
    specs, specs_real, reest, _ = spec_sets()

    # ---- Table 1: candidates by journal and tier -------------------------------------------------------
    lines = [r"\begin{tabular}{lcccc}", r"\toprule", r" & Tier 1 & Tier 2 & Tier 3 & Frame \\", r"\midrule"]
    for j in MAIN:
        lines.append(f"{LONG[j]} & {fmt(R[j]['tier1'])} & {fmt(R[j]['tier2'])} & {fmt(R[j]['tier3'])} & {fmt(R[j]['frame'])} \\\\")
    lines += [r"\midrule", f"Total & {fmt(total(R, 'tier1'))} & {fmt(total(R, 'tier2'))} & {fmt(total(R, 'tier3'))} & {fmt(total(R, 'frame'))} \\\\",
              r"\bottomrule", r"\end{tabular}"]
    (OUT / "candidates.tex").write_text("\n".join(lines) + "\n")

    # ---- Table 2: funnel ------------------------------------------------------------------------------------
    def line(label, key, na=()):
        vals = ["--" if j in na else fmt(R[j][key]) for j in MAIN]
        return f"{label} & " + " & ".join(vals) + f" & {fmt(total(R, key, [j for j in MAIN if j not in na]))} \\\\"
    gaps = sorted({r["gap_reason"] for r in rows if r["data_status"] == "usable_not_reestimated"})
    gap_label = {"all specifications excluded at replication": "estimate not reproduced",
                 "awaiting data": "awaiting data"}.get(gaps[0], "other") if len(gaps) == 1 else "see notes"
    rows_tex = [line("Articles in search frame", "frame"),
                line("Candidate papers (tiers 1--3)", "cand"),
                line("Candidates with a replication package", "pkg", na=("jmr",)),
                line("Candidates screened", "scr_cand"),
                line(r"\quad of which from the article text alone", "scr_text"),
                line("Candidates not screened (no package or article text)", "notscr"),
                line("Candidates not assessable (wrong file)", "unassessable"),
                line("Non-candidates screened", "scr_noncand"),
                line("Papers screened", "scr"),
                r"\midrule",
                line("Eligible staggered design", "elig"),
                line(r"\quad package data synthetic or disguised", "synthetic"),
                line(r"\quad analysis data not in package", "not_shipped"),
                line(r"\quad no replication package", "no_package"),
                line(r"\quad usable data", "usable"),
                line(r"\qquad re-estimated on original data", "reestimated"),
                line(r"\qquad not re-estimated (" + gap_label + ")", "usable_not_reestimated")]
    hdr = r" & \emph{MS} & \emph{MKSC} & \emph{JMR} & Total \\"
    (OUT / "funnel.tex").write_text("\n".join([r"\begin{tabular}{lcccc}", r"\toprule", hdr, r"\midrule"] + rows_tex
                                              + [r"\bottomrule", r"\end{tabular}"]) + "\n")

    # ---- macros (totals over MS, MKSC, JMR; per-journal macros are in journal_funnel_numbers.tex) --------------
    jm = R["jm"]
    macros = {
        "nFrame": fmt(total(R, "frame")), "nCand": fmt(total(R, "cand")), "nTierOne": fmt(total(R, "tier1")),
        "nCandPkg": fmt(total(R, "pkg", ("mnsc", "mksc"))), "nCandNoPkg": fmt(total(R, "nopkg", ("mnsc", "mksc"))),
        "nScreened": fmt(total(R, "scr")), "nScreenedCand": fmt(total(R, "scr_cand")),
        "nScreenedNonCand": fmt(total(R, "scr_noncand")), "nNotScreened": fmt(total(R, "notscr")),
        "nScreenedText": fmt(total(R, "scr_text")), "nScreenedFromPkg": fmt(total(R, "scr_cand") - total(R, "scr_text")),
        "nEligNoPkg": fmt(total(R, "no_package")),
        "nCandExtra": fmt(total(R, "cand", EXTRA)), "nScreenedExtra": fmt(total(R, "scr", EXTRA)),
        "nNotScreenedExtra": fmt(total(R, "notscr", EXTRA)), "nEligibleExtra": fmt(total(R, "elig", EXTRA)),
        "nNearMissExtra": fmt(total(R, "nm_flag", EXTRA)),
        "nUnassessable": fmt(total(R, "unassessable") + total(R, "unassessable_noncand")),
        "nEligible": fmt(total(R, "elig")), "nEligibleCand": fmt(total(R, "elig_cand")),
        "nEligibleNonCand": fmt(total(R, "elig_noncand")),
        "nEligSynth": fmt(total(R, "synthetic")), "nEligNoData": fmt(total(R, "not_shipped")),
        "nEligUsable": fmt(total(R, "usable")), "nUsableNotReest": fmt(total(R, "usable_not_reestimated")),
        "nSpecs": fmt(len(specs_real)), "nSpecPapers": fmt(len(reest)),
        "nJMscreened": fmt(jm["scr"]), "nJMeligible": fmt(jm["elig"]),
    }
    # files the journals' server returned for MS and MKSC (candidates and the articles outside the candidate list that were
    # also requested and screened); review Nov 4: the text used to call the candidate count "the files the server returned"
    import csv as _csv
    _man = list(_csv.DictReader(open(ROOT / "data/candidates/package_manifest.csv", encoding="utf-8")))
    _nfiles = sum(1 for r in _man if r.get("journal") in ("mnsc", "mksc") and r.get("status") == "downloaded")
    macros["nPkgFiles"] = fmt(_nfiles); macros["nPkgNonCand"] = fmt(_nfiles - total(R, "pkg", ("mnsc", "mksc")))
    (OUT / "numbers.tex").write_text("".join(f"\\newcommand{{\\{k}}}{{{v}}}\n" for k, v in macros.items()))

    # ---- audit file ---------------------------------------------------------------------------------------
    (ROOT / "output/tables").mkdir(parents=True, exist_ok=True)
    with open(ROOT / "output/tables/funnel_paper_status.csv", "w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)

    for j in MAIN:
        print(j, {k: R[j][k] for k in ("frame", "cand", "tier1", "pkg", "scr_cand", "scr_text", "notscr", "unassessable", "scr_noncand", "scr",
                                       "elig", "elig_noncand", "synthetic", "not_shipped", "no_package", "usable", "reestimated",
                                       "usable_not_reestimated", "nm_flag")})
    for j in EXTRA:
        print(j, {k: R[j][k] for k in ("frame", "cand", "tier1", "scr", "scr_text", "notscr", "elig", "no_package", "nm_flag")})
    for r in rows:
        if r["data_status"] == "usable_not_reestimated":
            print("  usable, not re-estimated:", r["suffix"], "-", r["gap_reason"])
    print(macros)


if __name__ == "__main__":
    main()
