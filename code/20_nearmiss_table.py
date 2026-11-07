#!/usr/bin/env python3
"""Near-miss appendix tables (Appendix C of paper/main.tex).

Reads data/screening/near_miss.csv (written by code/17_outreach_and_nearmiss.py) and the screening
records in data/screening/by_paper/, and writes
  paper/tables/near_miss_summary.tex  booktabs tabular: near-miss papers by reason category
  paper/tables/near_miss_list.tex     longtable: one row per near-miss paper
  paper/tables/near_miss_numbers.tex  LaTeX macros with the counts used in the appendix text
  output/tables/near_miss_classified.csv  audit file with the category assigned to every input row

near_miss.csv combines two sources: records the screener flagged as near-misses (near_miss = true,
with a free-text near_miss_reason) and records that code/17 adds by keyword ("time-varying controls" /
"additional treatment regressor"). The keyword rule also picks up designs with a single adoption date or
a continuous treatment. A near-miss requires a staggered binary design, so keyword-only rows are kept
only when the screening record marks the design as eligible (eligible_design = true) or its text
describes a staggered binary design; the others are counted on a separate line and left out of the list.
Pass --keep-all to skip that filter.

Definition (shared with code/15_tables.py, which holds the eligibility rule): a near-miss is a screened
Management Science, Marketing Science or JMR paper in near_miss.csv that passes the staggered-design filter
above and is NOT an eligible staggered design (no main-text specification meets every rule). Rows whose
record has a qualifying specification (eligible design whose data are unusable) are eligible designs, not
near-misses, and are reported on a memo line. Percentages use the screened papers of code/15_tables.py
(\nScreened) as denominator. Journal of Marketing records are outside the frame and counted separately.

The category is the restriction mentioned first in the reason text: the full near_miss_reason for flagged
records, otherwise the full eligible_reason; the short label in near_miss.csv is the fallback. A record
lists a single violation ("sole") when its reason text matches no other category.
Run from anywhere with:  python3 -I code/20_nearmiss_table.py
"""
import csv
import importlib.util
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
KEEP_ALL = "--keep-all" in sys.argv[1:]


def _load(name, fname):
    spec = importlib.util.spec_from_file_location(name, ROOT / "code" / fname)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


T = _load("tables15", "15_tables.py")   # single source of the screening and eligibility definitions

# (label, regex) in table order; matching is case-insensitive and the earliest match in the text wins.
CATEGORIES = [
    ("Time-varying controls",
     r"time[- ]varying\W+(?:\(?lagged\)?\s+)?(?:[\w/,-]+\s+){0,4}(?:controls?|covariates?)|\bcontrols? in every"
     r"|\blagged (?:time-varying )?(?:firm |country |bank |state |county )?controls|\bmobility control|\blagged (?:outcome|dependent variable)"
     r"|conditions? on (?:[\w-]+ ){0,3}covariates|(?:control|covariate)s?\b[^.;]{0,80}\bvar(?:y|ies|ying)\b(?! treatment)"
     r"|(?:observation|individual|applicant|customer|loan)-level (?:controls?|covariates?)"),
    ("Extra treatment regressors or interactions",
     r"additional (?:staggered )?treatments?\b|additional treatment regressors?|extra (?:treatment )?regressors?|second (?:absorbing |staggered )?treatment"
     r"|bundle of treatment regressors|simultaneous (?:non-absorbing )?treatments|treatment[- ]by[- ](?:subgroup|performance|moderator)"
     r"|interacts? the treatment|enter only as interactions|subgroup-by-treatment|treatment x moderator|triple (?:interaction|difference)"
     r"|\bddd\b|anticipation indicators?|release indicator|post trends?|treatment[- ]intensity"
     r"|(?:pair it|paired|interacted|interacts?) with (?:a |the )?continuous|treatment-by-characteristic"),
    ("Additional fixed effects (age, event time)",
     r"\bage fe\b|\bage fixed effects|event[- ]time (?:main effects?|fixed effects|fe)\b|additional (?:additive )?(?:event-time )?(?:fixed effects|fe)\b"
     r"|additional non-?redundant additive|extra (?:additive )?fe\b|post main effect|relative-event-time fe"),
    ("Unit-specific trends",
     r"(?:unit|individual|firm|state|county|country|city|region|district|market|product|industry|store|plant|assignment-unit)"
     r"[- ]specific (?:linear |quadratic )?(?:time )?trends?|treated-group linear trend"
     r"|\bunit[- ]trends?\b|firm[- ]trend regressions"),
    ("Stacked design", r"\bstack(?:ed|ing|s)?\b|event-window sample|matched-cohort"),
    ("Matching, IPW or entropy-balancing weights",
     r"propensity|\bipw\b|\biptw\b|inverse[- ]probability|entropy[- ]balanc|coarsened[- ]exact|\bcem\b|matching[- ]based|matching weights|\bpsm\b"),
     # a plain TWFE on a matched sample is eligible (PROTOCOL 5b), so "matched sample/controls" is not a category trigger
    ("Nonlinear model (Poisson, logit, PPML)",
     r"\bppml|poisson|\blogit\b|logistic regression|\bprobit\b|negative binomial|xtnbreg|\bnonlinear\b"),
    ("ETWFE or other non-admitted estimator only",
     r"\betwfe\b|\bjwdid\b|wooldridge|synthetic difference-in-differences|synthetic did|\bsdid\b|matrix completion|scm-did|synthetic control"),
]
OTHER = "Other"
LABELS = [c[0] for c in CATEGORIES] + [OTHER]
COMPILED = [(lab, re.compile(rx, re.I)) for lab, rx in CATEGORIES]
SHORT = {"Extra treatment regressors or interactions": "Extra treatment regressors",
         "Additional fixed effects (age, event time)": "Additional fixed effects",
         "Matching, IPW or entropy-balancing weights": "Matching or reweighting",
         "Nonlinear model (Poisson, logit, PPML)": "Nonlinear model",
         "ETWFE or other non-admitted estimator only": "Non-admitted estimator only"}
GENERIC = {"time-varying controls": "Time-varying controls",
           "additional treatment regressor": "Extra treatment regressors or interactions",
           "additional treatment regressors": "Extra treatment regressors or interactions"}
# Staggered-design filter for keyword-only rows (screener did not flag a near-miss or an eligible design):
# drop when the leading sentence states a non-staggered design or the text says it is not a staggered TWFE;
# otherwise keep only when the text affirmatively describes a staggered binary (or stacked) design.
NOT_STAGGERED_LEAD = re.compile(
    r"^\s*(?:single|each (?:did|estimate|wildfire)\b|randomi[sz]ed field experiment|two-period|no (?:binary )?staggered"
    r"|no difference-in-differences|not a staggered|the paper is mainly|main analysis regresses|the main identification"
    r"|the paper's main regressor|the only did .{0,80}?(?:two-period|single))", re.I)
NOT_STAGGERED_ANY = re.compile(r"not an? (?:pooled )?(?:binary )?staggered|not a unit-by-calendar-time", re.I)
STAGGERED = re.compile(
    r"design qualifies|staggered binary|binary staggered treatment exists|textbook staggered|\(staggered\)"
    r"|(?<!no )(?<!not a )(?<!pooled )staggered (?:design|did\b|acquisition|subscription|country-level|ceo|across)"
    r"|underlying (?:design|treatment) (?:is a|qualifies)|switch(?:es|ing)? on at [\w-]+-specific"
    r"|[\w-]+-specific (?:[\w-]+ ){0,2}(?:years?|dates?|months?|weeks?|days?|quarters?)\b|\bstack(?:ed|s)?\b|near-miss", re.I)


def describes_staggered(text):
    lead = re.split(r"(?<=[.;:])\s", text.strip(), maxsplit=1)[0] if text.strip() else ""
    if NOT_STAGGERED_LEAD.search(lead) or NOT_STAGGERED_ANY.search(text):
        return False
    return bool(STAGGERED.search(text))


def truthy(v):
    return v in (True, "true", "True", 1)


def earliest(text):
    best = None
    for lab, rx in COMPILED:
        m = rx.search(text or "")
        if m and (best is None or m.start() < best[0]):
            best = (m.start(), lab)
    return best[1] if best else None


def all_matches(text):
    return {lab for lab, rx in COMPILED if rx.search(text or "")}


def tex_escape(s):
    rep = {"\\": r"\textbackslash{}", "&": r"\&", "%": r"\%", "$": r"\$", "#": r"\#", "_": r"\_",
           "{": r"\{", "}": r"\}", "~": r"\textasciitilde{}", "^": r"\textasciicircum{}",
           "“": "``", "”": "''", "‘": "`", "’": "'", "–": "--", "—": "---", " ": " "}
    return "".join(rep.get(ch, ch) for ch in s)


def short_title(t, n=60):
    t = " ".join((t or "").split())
    if len(t) <= n:
        return tex_escape(t)
    return tex_escape(t[:n].rstrip()) + r"\ldots{}"


# journal issue year from Crossref (print year, else issued year; data/candidates/crossref_years.csv, Nov 3): the OpenAlex year
# is often the online-first year or a merged working-paper year
CROSSREF_YEAR = {}
_cy = pathlib.Path("data/candidates/crossref_years.csv")
if _cy.exists():
    for _r in csv.DictReader(open(_cy)):
        _y = _r.get("print_year") or _r.get("issued_year")
        if _y: CROSSREF_YEAR[_r["doi"].split("/", 1)[-1]] = _y


def classify():
    """Classify every near_miss.csv row. Returns (rows, n_screened, problems); a row is a near-miss when kept is True."""
    nm_path = ROOT / "data/screening/near_miss.csv"
    rows = list(csv.DictReader(open(nm_path, newline="", encoding="utf-8")))
    recs = T.load_screening()
    status = {r["suffix"]: r for r in T.paper_status()}
    n_screened = sum(r["screened"] for r in status.values() if r["journal"] in T.MAIN)

    out, seen, problems = [], set(), []
    for r in rows:
        s = r["suffix"].strip()
        if s in seen:
            problems.append(f"duplicate suffix {s}")
            continue
        seen.add(s)
        j = recs.get(s)
        if j is None:
            problems.append(f"no readable screening record for {s}")
            j = {}
        st = status.get(s, {})
        flagged = truthy(j.get("near_miss"))
        design_ok = truthy(j.get("eligible_design"))
        nm_reason = str(j.get("near_miss_reason") or "")
        el_reason = str(j.get("eligible_reason") or "")
        why = (r.get("why") or "").strip()
        text = nm_reason if flagged and nm_reason else (el_reason or r.get("reason", ""))
        cat = earliest(text) or earliest(why if why.lower() not in GENERIC else "") or earliest(r.get("reason", "")) \
            or GENERIC.get(why.lower()) or OTHER
        others = all_matches(text) - {cat}
        staggered = flagged or design_ok or describes_staggered(el_reason or r.get("reason", ""))
        source = "flagged" if flagged else "keyword"
        journal = st.get("journal") or T.journal_of(s)
        eligible = T.is_eligible(j) if j else False
        if eligible:
            excluded = "eligible design (has a qualifying specification)"
        elif not (KEEP_ALL or staggered):
            excluded = "no staggered binary design"
        elif journal not in T.MAIN:
            excluded = "outside the frame journals"
        elif not T.is_screened(j):
            excluded = "screening record not assessable"
        else:
            excluded = ""
        if not r.get("year"):
            problems.append(f"missing year for {s}")
        out.append({"suffix": s, "journal": journal, "year": CROSSREF_YEAR.get(s) or r.get("year", ""), "title": r.get("title", ""),
                    "candidate": st.get("candidate", False), "source": source, "eligible_design": design_ok,
                    "has_qualifying_spec": eligible, "staggered": staggered, "kept": not excluded, "excluded": excluded,
                    "category": cat, "sole_reason": not others, "other_categories": "; ".join(sorted(others))})
    return out, n_screened, problems


def main():
    out, n_screened, problems = classify()
    kept = [o for o in out if o["kept"]]
    dropped = [o for o in out if o["excluded"] == "no staggered binary design"]
    elig = [o for o in out if o["excluded"].startswith("eligible design")]
    other_excl = [o for o in out if o["excluded"] and o not in dropped and o not in elig]
    counts = {lab: sum(o["category"] == lab for o in kept) for lab in LABELS}
    sole = {lab: sum(o["category"] == lab and o["sole_reason"] for o in kept) for lab in LABELS}

    # ---- summary table ----
    def share(k):
        return f"{100 * k / n_screened:.1f}" if n_screened else "--"
    lines = [r"\begin{tabular}{lccc}", r"\toprule",
             r" & & No other & Percent of \\", r" & Papers & violation listed & screened papers \\", r"\midrule"]
    for lab in LABELS:
        lines.append(f"{lab} & {counts[lab]} & {sole[lab]} & {share(counts[lab])} \\\\")
    lines += [r"\midrule", f"All near-miss papers & {len(kept)} & {sum(sole.values())} & {share(len(kept))} \\\\"]
    if dropped or elig:
        lines += [r"\midrule", r"\multicolumn{4}{l}{\emph{Memo: excluded keyword-screen records}} \\"]
        if dropped:
            lines.append(f"No staggered binary design & {len(dropped)} & -- & {share(len(dropped))} \\\\")
        if elig:
            lines.append(f"Eligible design, data not usable & {len(elig)} & -- & {share(len(elig))} \\\\")
    lines += [r"\midrule", f"Screened papers & {T.fmt(n_screened)} & & \\\\", r"\bottomrule", r"\end{tabular}"]
    (ROOT / "paper/tables").mkdir(parents=True, exist_ok=True)
    (ROOT / "paper/tables/near_miss_summary.tex").write_text("\n".join(lines) + "\n", encoding="utf-8")
    jcount = {j: sum(o["journal"] == j for o in kept) for j in T.MAIN}
    jm_nm = sum(1 for o in out if o["journal"] == "jm" and o["staggered"] and not o["has_qualifying_spec"])
    macros = {"nNearMiss": len(kept), "nNearMissSole": sum(sole.values()), "nNearMissTVC": counts["Time-varying controls"],
              "nNearMissTVCsole": sole["Time-varying controls"],
              "nNearMissFlagged": sum(o["source"] == "flagged" for o in kept), "nNearMissExcluded": len(dropped),
              "nNearMissEligExcl": len(elig), "nNearMissNonCand": sum(not o["candidate"] for o in kept),
              "nNearMissMS": jcount["mnsc"], "nNearMissMKSC": jcount["mksc"], "nNearMissJMR": jcount["jmr"], "nNearMissJM": jm_nm,
              "shareNearMiss": share(len(kept)),
              "nScreenedRecords": T.fmt(n_screened)}   # deprecated alias of \nScreened (numbers.tex): same value
    (ROOT / "paper/tables/near_miss_numbers.tex").write_text(
        "".join(f"\\newcommand{{\\{k}}}{{{v}}}\n" for k, v in macros.items()), encoding="utf-8")

    # ---- list (longtable) ----
    jl = {"mnsc": "MS", "mksc": "MKSC", "jmr": "JMR"}
    jorder = {"mksc": 0, "mnsc": 1, "jmr": 2}
    kept_sorted = sorted(kept, key=lambda o: (LABELS.index(o["category"]), jorder.get(o["journal"], 9), str(o["year"]), o["suffix"]))
    head = r"Paper (DOI suffix) & Journal & Year & Title & Reason \\"
    body = [f"\\texttt{{{tex_escape(o['suffix'])}}} & {jl.get(o['journal'], tex_escape(o['journal'].upper()) or '--')} & "
            f"{o['year'] or '--'} & \\raggedright {short_title(o['title'])} & {tex_escape(SHORT.get(o['category'], o['category']))} \\\\" for o in kept_sorted]
    notes = (r"{\footnotesize\noindent Notes: Papers with a staggered binary design and unit and time fixed "
             r"effects in which every reported main-text column violates at least one restriction of Appendix~\ref{app:protocol}. "
             r"The reason is the restriction listed first in the screening record; Table~\ref{tab:nearmiss} reports how many records list "
             r"no other violation. Titles are truncated at 60 characters. MS = \emph{Management Science}; MKSC = \emph{Marketing Science}; "
             r"JMR = \emph{Journal of Marketing Research}.\par}")
    lt = [r"\begingroup\footnotesize\setstretch{1}", r"\setlength{\LTcapwidth}{\textwidth}", r"\setlength{\tabcolsep}{4pt}",
          r"\begin{longtable}{lccp{0.34\textwidth}l}",
          r"\caption{Near-miss papers}\label{tab:nearmisslist}\\", r"\toprule", head, r"\midrule", r"\endfirsthead",
          r"\multicolumn{5}{l}{\emph{Table \thetable, continued}} \\", r"\toprule", head, r"\midrule", r"\endhead",
          r"\midrule", r"\multicolumn{5}{r}{\emph{Continued on next page}} \\", r"\endfoot",
          r"\bottomrule", r"\endlastfoot"] + body + [r"\end{longtable}", r"\vspace{-0.5\baselineskip}", notes, r"\endgroup"]
    (ROOT / "paper/tables/near_miss_list.tex").write_text("\n".join(lt) + "\n", encoding="utf-8")

    # ---- audit file ----
    (ROOT / "output/tables").mkdir(parents=True, exist_ok=True)
    with open(ROOT / "output/tables/near_miss_classified.csv", "w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=list(out[0].keys()))
        w.writeheader()
        w.writerows(out)

    print(f"near_miss.csv rows: {len(out)}; flagged by screener: {sum(o['source'] == 'flagged' for o in out)}; "
          f"keyword-only: {sum(o['source'] == 'keyword' for o in out)}")
    print(f"near-misses kept: {len(kept)} (MS {jcount['mnsc']}, MKSC {jcount['mksc']}, JMR {jcount['jmr']}); "
          f"excluded: no staggered design {len(dropped)}, eligible design {len(elig)} ({', '.join(o['suffix'] for o in elig)}), "
          f"other {len(other_excl)}; screened papers: {n_screened}")
    for lab in LABELS:
        print(f"  {lab:<58s} {counts[lab]:>3d}  sole {sole[lab]:>3d}  ({share(counts[lab])}%)")
    for msg in problems:
        print("  input problem:", msg)


if __name__ == "__main__":
    main()
