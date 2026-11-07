#!/usr/bin/env python3
"""Specification characteristics (analog of Hull 2026, Table 1), replication status, software, and adoption of modern DiD.

Inputs
  output/specs_main.csv            main-sample specifications (code/R/analysis.R; one row per specification and window)
  output/specs/<suffix>__<id>.csv  per-spec estimates with the authors' DiD-averaging settings (option B; used only to compare
                                   published Callaway-Sant'Anna numbers with our estimate under the same settings)
  data/specs/<suffix>__<id>.json   spec metadata: replication_status, published_coef, published_estimator, published_event_coefs
  data/screening/by_paper/*.json   screening records: department, software, reports_modern_estimator, eligibility, near_miss
  data/text/mnsc/<suffix>.txt      article text, for the department when the screening record has none
  data/frame/frame.csv             OpenAlex citations (fallback when specs_main.csv has none)
  data/candidates/crossref_years.csv   journal issue year (print year, else issued year), as in code/R/analysis.R
  code/15_tables.py                screening and eligibility definitions (imported, as code/20_nearmiss_table.py does)

Outputs
  paper/tables/characteristics.tex          booktabs tabular: characteristics of all specifications and of those passing
                                            the TWFE leverage screen (pass == TRUE in specs_main.csv)
  paper/tables/adoption.tex                 booktabs tabular: staggered designs and the share reporting a modern estimator,
                                            by publication period and journal
  paper/tables/characteristics_numbers.tex  LaTeX macros (replication status, software, adoption timing, sample counts)
  output/tables/characteristics.csv         every number behind the three files, plus per-spec and per-paper audit rows

Definitions
  Specification: unique (suffix, spec_id) in specs_main.csv, counted once; its characteristics come from the post-window row
  (event studies) or the static row. Shares are specification-weighted, as in Hull's Table 1. The always-treated share is
  recorded for static specifications only (output/specs), so its mean is over static specifications; this is the column
  analysis.R averages for \\shareAlwaysMean. The never-treated share is averaged over specifications (analysis.R's
  \\shareNeverMean averages over comparisons, so pre-window rows count twice there).
  Department (Management Science only): the screening record's "department" field, else the department in the article's
  "Accepted by <editor>, <department>." line, grouped into DEPT_GROUPS below.
  Replication status: (a) label = first word of the spec JSON's replication_status (exact / approx / fail, other labels kept
  as "other"); (b) number-based = published_coef against our estimate in raw units (estimate x y_sd_regsample), where the
  estimate is the one the paper publishes: TWFE, or for a published Callaway-Sant'Anna (or Sun-Abraham) number our
  DiD-averaging estimate with the authors' settings (output/specs, option B), or for a published imputation / two-stage
  number our imputation estimate. Exact if the gap is at most half a unit of the last printed decimal of published_coef
  (for event-study summaries that average printed bins, the last decimal of the printed bins) or 1e-6 relative; approximate
  if same sign and within 10 percent; failed otherwise; "no printed value" if published_coef is null. The macros use (b),
  with (a) where there is no printed value.
  Software (papers in the main sample): free text of the screening record's "software" field, classified as stata, r, both
  or other; auxiliary tools (Python figures, SAS data construction) do not change the class and are listed as ambiguous.
  Adoption timing: screened Management Science and Marketing Science papers (code/15_tables.py is_screened) that are
  eligible staggered designs (is_eligible) or near-misses (record near_miss true); share whose record has
  reports_modern_estimator true. Year = Crossref print year, else issued year, else the record's year. With
  --paper-nearmiss the near-misses are instead the near-miss appendix set of code/20_nearmiss_table.py, which also keeps
  keyword-identified records of data/screening/near_miss.csv that the screener did not flag.
Run from the project root:  python3 -I code/23_characteristics.py [--paper-nearmiss]
"""
import collections
import csv
import importlib.util
import json
import math
import pathlib
import re
import statistics
import sys
import unicodedata
from decimal import Decimal

ROOT = pathlib.Path(__file__).resolve().parents[1]
TAB = ROOT / "paper" / "tables"
# --paper-nearmiss: adoption-table near-misses = the near-miss appendix set of code/20_nearmiss_table.py (adds keyword-only
# records of data/screening/near_miss.csv); default = screening records with near_miss true
PAPER_NEARMISS = "--screener-nearmiss" not in sys.argv[1:]   # default since Nov 4 (review): the paper's near-miss set; --screener-nearmiss restores the flag-only set


def _load(name, fname):
    spec = importlib.util.spec_from_file_location(name, ROOT / "code" / fname)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


T = _load("tables15", "15_tables.py")   # single source of the screening and eligibility definitions

# Management Science departments, grouped (first match wins; the rest is "Operations and other")
DEPT_GROUPS = [("Accounting", r"accounting"), ("Finance", r"financ"), ("Information systems", r"information systems"),
               ("Strategy, innovation and organizations", r"strategy|entrepreneurship|innovation|organization"),
               ("Marketing", r"marketing")]
DEPT_OTHER, DEPT_NONE = "Operations and other", "Not recorded"
DEPT_ORDER = [g for g, _ in DEPT_GROUPS] + [DEPT_OTHER, DEPT_NONE]
# Publication periods of the adoption table (design choice: two-year bins from 2019 left 2019-2020 with 1-2 papers per journal)
PERIODS = [(2013, 2018), (2019, 2022), (2023, 2024), (2025, 2026)]
ADOPT_JOURNALS = ("mnsc", "mksc")
CS_PAT = re.compile(r"callaway|sant.?anna|csdid|att_gt|\bcsa|sunab|sun.?abraham|eventstudyinteract", re.I)
BJS_PAT = re.compile(r"did_imputation|borusyak|\bbjs\b|did2s|gardner|two.?stage", re.I)
# published estimator inferred from the spec id when published_estimator is empty (e.g. "<table>_<outcome>_bjs_basic")
SPEC_ID_EST = {"bjs": "did_imputation", "imputation": "did_imputation", "did2s": "did2s", "csdid": "csdid", "csa": "csa"}
OTHER_TOOLS = re.compile(r"python|\bsas\b|matlab|julia|spss|\bgauss\b|fortran|c\+\+|excel", re.I)


# ---------------------------------------------------------------------------------------------------------------------------
def num(x):
    try:
        v = float(x)
    except (TypeError, ValueError):
        return None
    return v if math.isfinite(v) else None


def flag(x):
    s = str(x).strip().upper()
    return True if s == "TRUE" else False if s == "FALSE" else None


def mean(xs):
    xs = [x for x in xs if x is not None]
    return (sum(xs) / len(xs), len(xs)) if xs else (None, 0)


def median(xs):
    xs = [x for x in xs if x is not None]
    return (statistics.median(xs), len(xs)) if xs else (None, 0)


def read_csv(p):
    return list(csv.DictReader(open(p, newline="", encoding="utf-8")))


def load_specs():
    """One record per specification (post or static row; a pre row only if nothing else exists)."""
    rows = read_csv(ROOT / "output/specs_main.csv")
    by = collections.OrderedDict()
    for r in rows:
        by.setdefault((r["suffix"], r["spec_id"]), []).append(r)
    out, problems = [], []
    # analysis.R keeps only specifications with a current spec JSON; a spec excluded after specs_main.csv was written
    # (JSON moved to data/specs_excluded/) is left out here too, and the stale file is reported
    gone = [k for k in by if not (ROOT / "data/specs" / f"{k[0]}__{k[1]}.json").exists()]
    if gone:
        papers = collections.Counter(k[0] for k in gone)
        problems.append(f"specs_main.csv is older than data/specs/: {len(gone)} specifications without a current JSON left out "
                        f"({', '.join(f'{s} {n}' for s, n in sorted(papers.items()))}); re-run code/R/analysis.R")
    for key, rr in by.items():
        if key in gone:
            continue
        main = [r for r in rr if r["window"] in ("post", "static")]
        if len(main) != 1:
            problems.append(f"{key[0]}__{key[1]}: {len(main)} post/static rows (windows {sorted(r['window'] for r in rr)})")
        out.append((main or rr)[0])
    return out, problems


def crossref_years():
    cy = {}
    p = ROOT / "data/candidates/crossref_years.csv"
    if p.exists():
        for r in read_csv(p):
            y = r.get("print_year") or r.get("issued_year")
            if y:
                cy[r["doi"].split("/", 1)[-1]] = int(y)
    return cy


def frame_cites():
    out = {}
    for r in read_csv(ROOT / "data/frame/frame.csv"):
        out[r["doi"].lower().replace("https://doi.org/", "").split("/", 1)[-1]] = r.get("cited_by", "")
    return out


# ---- department ---------------------------------------------------------------------------------------------------------
ACCEPTED = re.compile(r"accepted\s+by\s+([^,]{2,60}?),\s*([^.;]{2,150}?)\s*\.", re.I)


DEPT_CACHE = ROOT / "data/candidates/departments.csv"   # departments read from the article text, cached so that the table
# can be rebuilt where the article text is absent (public copy of the repository, Nov 7)


def _dept_cache():
    if not DEPT_CACHE.exists():
        return {}
    with open(DEPT_CACHE, encoding="utf-8", newline="") as f:
        return {r["suffix"]: r["department"] for r in csv.DictReader(f)}


def department_from_text(suffix):
    p = ROOT / "data/text" / T.journal_of(suffix) / (suffix + ".txt")
    if not p.exists():
        cached = _dept_cache().get(suffix)
        return (cached, "article text (cached)") if cached else (None, "no article text")
    t = unicodedata.normalize("NFKC", p.read_text(encoding="utf-8", errors="replace"))
    t = re.sub(r"­\s*", "", t)            # soft hyphens at line breaks ("Busi\xad ness")
    t = " ".join(t.split())
    i = t.find("History:")
    m = ACCEPTED.search(t, i) if i >= 0 else None
    m = m or ACCEPTED.search(t)
    if not m:
        return None, "no 'Accepted by' line in article text"
    return m.group(2).strip(), "article text"


def dept_group(dept):
    if not dept:
        return DEPT_NONE
    for g, rx in DEPT_GROUPS:
        if re.search(rx, dept, re.I):
            return g
    return DEPT_OTHER


# ---- replication status ---------------------------------------------------------------------------------------------------
def decimals(v):
    if isinstance(v, Decimal):
        e = v.as_tuple().exponent
        return -e if isinstance(e, int) and e < 0 else 0
    if isinstance(v, int):
        return 0
    return None


def label_class(label):
    s = str(label or "").strip().lower()
    for k, c in (("exact", "exact"), ("approx", "approximate"), ("fail", "failed")):
        if s.startswith(k):
            return c
    return "other" if s else "missing"


APPROX_REASONS = ("random_subsample", "altered_data", "package_version", "rounding", "other")


def approx_reason(j):
    """Why the authors' code does not reproduce the printed value exactly (label-based approximate / failed specs; Nov 4).
    An explicit spec field replication_reason (one of APPROX_REASONS) wins; otherwise data_provenance random_subsample,
    then keywords of the replication_status label."""
    r = str(j.get("replication_reason") or "").strip().lower()
    if r in APPROX_REASONS:
        return r
    if re.search(r"random_subsample", str(j.get("data_provenance") or ""), re.I):
        return "random_subsample"
    s = str(j.get("replication_status") or "").lower()
    if re.search(r"disclos|\breduced\b(?!-form)|transformed|shipped data and code give", s):
        return "altered_data"
    if re.search(r"package version|version difference|\bversion\b", s):
        return "package_version"
    if re.search(r"truncat|\bround(ed|ing)?\b", s):
        return "rounding"
    return "other"


def optionB_estimate(suffix, spec_id, window, col):
    p = ROOT / "output/specs" / f"{suffix}__{spec_id}.csv"
    if not p.exists():
        return None
    for r in read_csv(p):
        if r.get("window") == window:
            return num(r.get(col))
    return None


def deviation_flags(j, r):
    """Documented protocol steps that make our TWFE differ from the authors' (audit only; read from the spec JSON)."""
    f = []
    if any(num(j.get(k)) for k in ("rows_dropped_switchoff", "rows_dropped_switch_off")) or T.truthy(j.get("treatment_switches_off")):
        f.append("switch-off rows dropped")
    if num(r.get("n_presample_adopters")):
        f.append("pre-sample adopters")
    prov = str(j.get("data_provenance") or "")
    if re.search(r"random_subsample|authors_transformed", prov):
        f.append(prov)
    text = " ".join(str(j.get(k) or "") for k in ("notes", "replication_status", "run_spec_mapping"))
    if re.search(r"anticipation", text, re.I):
        f.append("anticipation bin")
    if re.search(r"deviation", text, re.I):
        f.append("documented deviation")
    return ",".join(f)


def replication(r):
    """Label-based and number-based replication status of one specification."""
    j = json.load(open(ROOT / "data/specs" / f"{r['suffix']}__{r['spec_id']}.json", encoding="utf-8"), parse_float=Decimal)
    label = j.get("replication_status")
    lab = label_class(label)
    # reference value: the authors' estimator re-run on the protocol sample where the spec records one (switch-off rows dropped;
    # appendix.R uses the same reference for Table pubcs), else the printed value (review Nov 4)
    pub = j.get("authors_rerun_csdid_dropoff_coef") if j.get("authors_rerun_csdid_dropoff_coef") is not None else j.get("published_coef")
    if isinstance(pub, str):
        try:
            pub = Decimal(pub.strip())
        except Exception:  # noqa: BLE001
            pub = None
    est_name = str(j.get("published_estimator") or r.get("published_estimator") or "")
    if not est_name.strip() or est_name.strip().upper() == "NA":
        est_name = SPEC_ID_EST.get(next((k for k in SPEC_ID_EST if re.search(rf"(?:^|_){k}(?:_|$)", r["spec_id"], re.I)), ""), "")
    if CS_PAT.search(est_name):
        comp, est = "csa (authors' settings)", optionB_estimate(r["suffix"], r["spec_id"], r["window"], "csa")
    elif BJS_PAT.search(est_name):
        comp, est = "bjs", num(r["bjs"])
    else:
        comp, est = "twfe", num(r["twfe"])
    out = {"label": str(label or ""), "label_class": lab, "reason": approx_reason(j) if lab in ("approximate", "failed") else "",
           "published_coef": "" if pub is None else str(pub),
           "compared_with": comp, "ours_raw": "", "gap": "", "tolerance": "", "num_class": "no printed value",
           "flags": deviation_flags(j, r)}
    if pub is None:
        out["final"] = lab if lab in ("exact", "approximate", "failed") else "unclassified"
        return out
    ysd = num(r["y_sd_regsample"])
    if est is None or ysd is None:
        out["num_class"] = "not computable"
        out["final"] = lab if lab in ("exact", "approximate", "failed") else "unclassified"
        return out
    p, ours = float(pub), est * ysd
    dec = decimals(pub)
    bins = j.get("published_event_coefs")
    bvals = list(bins.values()) if isinstance(bins, dict) else bins if isinstance(bins, list) else []
    bdec = [decimals(b) for b in bvals if decimals(b) is not None]
    if bdec and dec is not None and dec > max(bdec):
        dec = max(bdec)        # summary that averages printed bins: their precision
    tol = max(0.5 * 10 ** (-dec) if dec is not None else 0.0, 1e-6 * abs(p))
    gap = abs(ours - p)
    if gap <= tol * (1 + 1e-9):
        nc = "exact"
    elif p != 0 and math.copysign(1, ours) == math.copysign(1, p) and gap <= 0.10 * abs(p):
        nc = "approximate"
    else:
        nc = "failed"
    out.update(ours_raw=f"{ours:.10g}", gap=f"{gap:.3g}", tolerance=f"{tol:.3g}", num_class=nc, final=nc)
    return out


# ---- software ---------------------------------------------------------------------------------------------------------------
def software_class(s):
    s = str(s or "")
    st = bool(re.search(r"stata|reghdfe|\bareg\b|csdid", s, re.I))
    rr = bool(re.search(r"(?<![\w.])r(?![\w])|fixest|\brstudio\b", s, re.I))
    cls = "both" if st and rr else "stata" if st else "r" if rr else "other"
    return cls, bool(OTHER_TOOLS.search(s)) or (cls == "other")


# ---- formatting ---------------------------------------------------------------------------------------------------------------
def f3(x):
    return "--" if x is None else f"{x:.3f}"


def f1(x):
    return "--" if x is None else f"{x:.1f}"


def fmed(x):
    return "--" if x is None else (f"{x:.0f}" if float(x).is_integer() else f"{x:.1f}")


def pct(k, n):
    return "--" if not n else f"{100 * k / n:.1f}"


def period_label(a, b, tex=True):
    return f"{a}--{b}" if tex else f"{a}-{b}"


# ---------------------------------------------------------------------------------------------------------------------------
def main():
    specs, problems = load_specs()
    recs = T.load_screening()
    cy = crossref_years()
    fcites = frame_cites()
    csv_rows = []

    def add(section, item, group, value, n="", detail=""):
        csv_rows.append({"section": section, "item": item, "group": group, "value": value, "n": n, "detail": detail})

    # ---- per-paper attributes ----
    papers = sorted({r["suffix"] for r in specs})
    dept, soft = {}, {}
    for s in papers:
        rec = recs.get(s)
        if rec is None:
            problems.append(f"{s}: no screening record")
            rec = {}
        if T.journal_of(s) == "mnsc":
            d, src = (str(rec["department"]).strip(), "screening record") if rec.get("department") else (None, "")
            td, tsrc = department_from_text(s)
            if d and td and dept_group(d) != dept_group(td):
                problems.append(f"{s}: department '{d}' in screening record vs '{td}' in article text")
            if not d:
                d, src = td, tsrc
            if not d:
                problems.append(f"{s}: department not recorded ({tsrc})")
            dept[s] = (dept_group(d), d or "", src)
            add("paper", "department", s, dept_group(d), detail=f"{d or ''} [{src}]")
        sw = rec.get("software")
        cls, amb = software_class(sw)
        soft[s] = (cls, amb, str(sw or ""))
        add("paper", "software", s, cls, detail=str(sw or "") + (" [ambiguous]" if amb else ""))
    # cache the departments read from the article text (not written when the run itself used the cache)
    from_text = {s: v[1] for s, v in dept.items() if v[2] == "article text" and v[1]}
    if from_text:
        with open(DEPT_CACHE, "w", encoding="utf-8", newline="") as f:
            w = csv.writer(f)
            w.writerow(["suffix", "department"])
            for s in sorted(from_text):
                w.writerow([s, from_text[s]])

    # ---- per-spec attributes ----
    S = []
    for r in specs:
        s = r["suffix"]
        year = num(r.get("year"))
        if year is None:
            year = cy.get(s) or num((recs.get(s) or {}).get("year"))
            problems.append(f"{s}: year missing in specs_main.csv, fallback {year}")
        cites = num(r.get("cited_by"))
        if cites is None:
            cites = num(fcites.get(s))
            problems.append(f"{s}: cited_by missing in specs_main.csv, frame.csv value {cites}")
        ev = r["window"] != "static"
        if (r.get("static_or_event") or "") not in ("", "NA") and (r["static_or_event"] == "event") != ev:
            problems.append(f"{s}__{r['spec_id']}: static_or_event '{r['static_or_event']}' but window '{r['window']}'")
        S.append({"suffix": s, "spec_id": r["spec_id"], "pass": flag(r["pass"]) is True, "year": year,
                  "y2021": None if year is None else float(year >= 2021), "mksc": float(r["journal"] == "mksc"),
                  "cites": cites, "modern": float(flag(r["reported_modern"]) is True),
                  "preferred": float(flag(r["preferred"]) is True), "absintro": float(flag(r["in_abstract_intro"]) is True),
                  "event": float(ev), "cohorts": num(r["n_cohorts"]), "never": num(r["share_never"]),
                  "always": num(r["share_always"]) if not ev else None, "dept": dept.get(s, (None,))[0], "row": r})

    # ---- Table: characteristics ----
    samples = [("All specifications", S), ("Pass leverage screen", [x for x in S if x["pass"]])]
    stats = {}
    for lab, xs in samples:
        st = {}
        for k in ("year", "y2021", "mksc", "cites", "modern", "absintro", "preferred", "event", "always", "never"):
            st[k] = mean([x[k] for x in xs])
        st["cites_med"] = median([x["cites"] for x in xs])
        st["cohorts_med"] = median([x["cohorts"] for x in xs])
        ms = [x for x in xs if x["dept"] is not None]
        for g in DEPT_ORDER:
            st["dept:" + g] = mean([float(x["dept"] == g) for x in ms])
        st["specs"] = (len(xs), len(xs))
        st["papers"] = (len({x["suffix"] for x in xs}), len(xs))
        st["ms_specs"] = (len(ms), len(ms))
        stats[lab] = st
    lines = [r"\begin{tabular}{lcc}", r"\toprule", r" & All specifications & Pass leverage screen \\", r"\midrule"]
    spec_rows = [("Publication year", "year", f1), ("Published in 2021 or later", "y2021", f3),
                 (r"\emph{Marketing Science}", "mksc", f3), ("Paper citations (mean)", "cites", f1),
                 ("Paper citations (median)", "cites_med", fmed), ("Paper reports a modern estimator", "modern", f3),
                 ("Result in abstract or introduction", "absintro", f3), ("Preferred specification", "preferred", f3),
                 ("Event study", "event", f3), ("Adoption cohorts (median)", "cohorts_med", fmed),
                 ("Always-treated share (static specifications)", "always", f3), ("Never-treated share", "never", f3)]
    cols = [lab for lab, _ in samples]
    for name, k, f in spec_rows:
        lines.append(f"{name} & " + " & ".join(f(stats[c][k][0]) for c in cols) + r" \\")
    lines += [r"\midrule", r"\multicolumn{3}{l}{\emph{Management Science department (share of MS specifications)}} \\"]
    for g in DEPT_ORDER:
        if g == DEPT_NONE and not any(stats[c]["dept:" + g][0] for c in cols):
            continue
        lines.append(f"\\quad {g} & " + " & ".join(f3(stats[c]["dept:" + g][0]) for c in cols) + r" \\")
    lines += [r"\midrule", "Specifications & " + " & ".join(T.fmt(stats[c]["specs"][0]) for c in cols) + r" \\",
              "Papers & " + " & ".join(T.fmt(stats[c]["papers"][0]) for c in cols) + r" \\", r"\bottomrule", r"\end{tabular}"]
    TAB.mkdir(parents=True, exist_ok=True)
    (TAB / "characteristics.tex").write_text("\n".join(lines) + "\n", encoding="utf-8")
    for c in cols:
        for k, (v, n) in stats[c].items():
            add("characteristics", k, c, "" if v is None else f"{v:.6g}", n)

    # ---- replication status ----
    rep = collections.Counter()
    lab_counts, num_counts, cross = collections.Counter(), collections.Counter(), collections.Counter()
    reason_counts, reason_papers = collections.Counter(), collections.defaultdict(set)   # label-based approximate/failed, by reason (Nov 4)
    for x in S:
        o = replication(x["row"])
        x["rep"] = o
        lab_counts[o["label_class"]] += 1
        num_counts[o["num_class"]] += 1
        rep[o["final"]] += 1
        cross[(o["label_class"], o["num_class"])] += 1
        if o["reason"]:
            reason_counts[o["reason"]] += 1
            reason_papers[o["reason"]].add(x["suffix"])
        if o["final"] == "failed" and "random_subsample" in o["flags"]:
            rep["failed_subsample"] += 1   # package ships a random subsample of the data (audit, Nov 4)
        add("replication_spec", f"{x['suffix']}__{x['spec_id']}", o["final"], o["num_class"],
            detail=f"label={o['label_class']}; published={o['published_coef']}; ours_raw={o['ours_raw']}; "
                   f"compared_with={o['compared_with']}; gap={o['gap']}; tol={o['tolerance']}; flags={o['flags']}; "
                   f"label_text={o['label'][:160]}")
    for k, v in lab_counts.items():
        add("replication_label", k, "all", v)
    for k, v in num_counts.items():
        add("replication_number", k, "all", v)
    for (a, b), v in sorted(cross.items()):
        add("replication_cross", f"label={a}", f"number={b}", v)
    for k, v in sorted(reason_counts.items()):
        add("replication_reason", k, "all", v, detail=";".join(sorted(reason_papers[k])))
    for k, v in rep.items():
        add("replication_final", k, "all", v)

    # ---- software ----
    sc = collections.Counter(v[0] for v in soft.values())
    for k in ("stata", "r", "both", "other"):
        add("software", k, "papers", sc[k], len(soft))

    # ---- adoption of modern estimators ----
    pop = []
    paper_nm = None
    if PAPER_NEARMISS:   # near-misses as in the paper's appendix (\nNearMiss): code/20_nearmiss_table.py classify()
        nm_rows, _, _ = _load("nearmiss20", "20_nearmiss_table.py").classify()
        paper_nm = {o["suffix"] for o in nm_rows if o["kept"]}
    for s, rec in recs.items():
        jn = T.journal_of(s)
        if jn not in ADOPT_JOURNALS or not T.is_screened(rec):
            continue
        if rec.get("screened_from") == T.TEXT_ONLY:   # text-screen verdicts carry no reports_modern_estimator field (Nov 5)
            continue
        elig = T.is_eligible(rec)
        nm = (s in paper_nm) if paper_nm is not None else T.truthy(rec.get("near_miss"))
        if not (elig or nm):
            continue
        y, ysrc = cy.get(s), "crossref"
        if y is None:
            y, ysrc = (int(rec["year"]), "screening record") if num(rec.get("year")) is not None else (None, "missing")
        mod = rec.get("reports_modern_estimator")
        if mod not in (True, False, None, "true", "false", "True", "False"):
            problems.append(f"{s}: reports_modern_estimator = {mod!r}, counted as not reporting")
        pop.append({"suffix": s, "journal": jn, "year": y, "ysrc": ysrc, "modern": T.truthy(mod),
                    "eligible": elig, "near_miss": nm})
        add("adoption_paper", s, jn, int(T.truthy(mod)), detail=f"year={y} [{ysrc}]; eligible={elig}; near_miss={nm}")
    no_year = [p["suffix"] for p in pop if p["year"] is None]
    for p in pop:
        if p["year"] is None:
            problems.append(f"{p['suffix']}: no publication year, left out of the adoption table")
    fallback_year = sorted(p["suffix"] for p in pop if p["ysrc"] == "screening record")

    def cell(jn, a, b):
        xs = [p for p in pop if p["journal"] == jn and p["year"] is not None and a <= p["year"] <= b]
        return len(xs), sum(p["modern"] for p in xs)
    outside = [p["suffix"] for p in pop if p["year"] is not None and not any(a <= p["year"] <= b for a, b in PERIODS)]
    for s in outside:
        problems.append(f"{s}: publication year outside the adoption periods")
    alines = [r"\begin{tabular}{lcccc}", r"\toprule",
              r" & \multicolumn{2}{c}{\emph{Management Science}} & \multicolumn{2}{c}{\emph{Marketing Science}} \\",
              r"\cmidrule(lr){2-3}\cmidrule(lr){4-5}",
              r"Publication year & Papers & Share modern & Papers & Share modern \\", r"\midrule"]
    cells = {}
    for a, b in PERIODS:
        vals = []
        for jn in ADOPT_JOURNALS:
            n, k = cell(jn, a, b)
            cells[(jn, a, b)] = (n, k)
            vals += [str(n), f3(k / n) if n else "--"]
            add("adoption", period_label(a, b, False), jn, k, n, detail="papers with modern estimator (value) of staggered designs (n)")
        alines.append(f"{period_label(a, b)} & " + " & ".join(vals) + r" \\")
    tot = {}
    for jn in ADOPT_JOURNALS:
        xs = [p for p in pop if p["journal"] == jn and p["year"] is not None]
        tot[jn] = (len(xs), sum(p["modern"] for p in xs))
        add("adoption", "all years", jn, tot[jn][1], tot[jn][0])
        for y in sorted({p["year"] for p in xs}):
            ys = [p for p in xs if p["year"] == y]
            add("adoption_year", str(y), jn, sum(p["modern"] for p in ys), len(ys))
    alines += [r"\midrule", "All years & " + " & ".join(f"{tot[jn][0]} & {f3(tot[jn][1] / tot[jn][0]) if tot[jn][0] else '--'}"
                                                        for jn in ADOPT_JOURNALS) + r" \\", r"\bottomrule", r"\end{tabular}"]
    (TAB / "adoption.tex").write_text("\n".join(alines) + "\n", encoding="utf-8")
    # first period = first period with papers in every journal; last period = last period with papers in every journal
    common = [(a, b) for a, b in PERIODS if all(cells[(jn, a, b)][0] for jn in ADOPT_JOURNALS)]
    first, last = (common[0], common[-1]) if common else (PERIODS[0], PERIODS[-1])
    first_year = {jn: min((p["year"] for p in pop if p["journal"] == jn and p["modern"] and p["year"] is not None), default=None)
                  for jn in ADOPT_JOURNALS}

    # ---- macros ----
    nS = len(S)
    allc, passc = stats["All specifications"], stats["Pass leverage screen"]
    jl = {"mnsc": "MS", "mksc": "MKSC"}
    macros = {
        # replication status (number-based rule, label where no printed value)
        "nReplExact": rep["exact"], "nReplApprox": rep["approximate"], "nReplFail": rep["failed"],
        "nReplUnclassified": rep["unclassified"], "nReplTotal": nS,
        "pctReplExact": pct(rep["exact"], nS), "pctReplApprox": pct(rep["approximate"], nS), "pctReplFail": pct(rep["failed"], nS),
        "nReplNoPrinted": num_counts["no printed value"],
        "nReplPrinted": nS - num_counts["no printed value"],
        "nReplLabelExactPrinted": lab_counts["exact"] - cross[("exact", "no printed value")],
        "nReplNonExactNoPrinted": cross[("approximate", "no printed value")] + cross[("failed", "no printed value")],
        "nReplFailSub": rep["failed_subsample"],
        "nReplLabelExact": lab_counts["exact"], "nReplLabelApprox": lab_counts["approximate"], "nReplLabelFail": lab_counts["failed"],
        "nReplLabelOther": lab_counts["other"] + lab_counts["missing"],
        "nReplLabelNonExact": lab_counts["approximate"] + lab_counts["failed"],
        # why the authors' code does not reproduce the printed value exactly (label-based approximate / failed specs, Nov 4)
        "nReplApproxSub": reason_counts["random_subsample"], "nReplApproxSubPapers": len(reason_papers["random_subsample"]),
        "nReplApproxAltered": reason_counts["altered_data"], "nReplApproxAlteredPapers": len(reason_papers["altered_data"]),
        "nReplApproxVersion": reason_counts["package_version"], "nReplApproxVersionPapers": len(reason_papers["package_version"]),
        "nReplApproxRounding": reason_counts["rounding"], "nReplApproxRoundingPapers": len(reason_papers["rounding"]),
        "nReplApproxOther": reason_counts["other"], "nReplApproxOtherPapers": len(reason_papers["other"]),
        # software of the re-estimated papers
        "nReplStata": sc["stata"], "nReplR": sc["r"], "nReplBoth": sc["both"], "nReplOther": sc["other"],
        "nReplStataAny": sc["stata"] + sc["both"], "nReplRAny": sc["r"] + sc["both"], "nReplPapers": len(soft),
        # sample counts of the characteristics table
        "nCharSpecs": T.fmt(nS), "nCharPapers": allc["papers"][0], "nCharPassSpecs": T.fmt(passc["specs"][0]),
        "nCharPassPapers": passc["papers"][0], "charCitesMedian": fmed(allc["cites_med"][0]),
        "charModernShare": pct(allc["modern"][0] or 0, 1), "charEventShare": pct(allc["event"][0] or 0, 1),
        "charMKSCShare": pct(allc["mksc"][0] or 0, 1),
        # adoption timing
        "adoptFirstPeriod": period_label(*first), "adoptLastPeriod": period_label(*last),
    }
    for jn in ADOPT_JOURNALS:
        n1, k1 = cells[(jn, *first)]
        n2, k2 = cells[(jn, *last)]
        macros[f"adopt{jl[jn]}firstShare"] = pct(k1, n1)
        macros[f"adopt{jl[jn]}lastShare"] = pct(k2, n2)
        macros[f"adopt{jl[jn]}firstN"] = n1
        macros[f"adopt{jl[jn]}lastN"] = n2
        macros[f"adopt{jl[jn]}Share"] = pct(tot[jn][1], tot[jn][0])
        macros[f"adopt{jl[jn]}N"] = tot[jn][0]
        macros[f"adopt{jl[jn]}firstYear"] = first_year[jn] if first_year[jn] is not None else "--"
        if k1 > 0:   # claim guard: Section 4.4 of the paper says "none of the ... published in <first period> reports" one
            print(f"CLAIM CHECK: {jn} has {k1} of {n1} papers reporting a modern estimator in the first period; "
                  "edit the adoption sentence in paper/main.tex ('none of the ... reports')")
    (TAB / "characteristics_numbers.tex").write_text("".join(f"\\newcommand{{\\{k}}}{{{v}}}\n" for k, v in macros.items()),
                                                     encoding="utf-8")
    for k, v in macros.items():
        add("macro", k, "", v)

    # ---- audit csv ----
    (ROOT / "output/tables").mkdir(parents=True, exist_ok=True)
    with open(ROOT / "output/tables/characteristics.csv", "w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=["section", "item", "group", "value", "n", "detail"])
        w.writeheader()
        w.writerows(csv_rows)

    # ---- summary ----
    print(f"specifications {nS} from {allc['papers'][0]} papers; pass leverage screen {passc['specs'][0]} from {passc['papers'][0]} papers")
    for name, k, f in spec_rows:
        plain = re.sub(r"\\emph\{([^}]*)\}", r"\1", name)
        print(f"  {plain:<46s} " + "  ".join(f"{f(stats[c][k][0]):>8s}" for c in cols))
    for g in DEPT_ORDER:
        print(f"  MS dept: {g:<37s} " + "  ".join(f"{f3(stats[c]['dept:' + g][0]):>8s}" for c in cols))
    print("replication, label-based:", dict(lab_counts))
    print("replication, number-based:", dict(num_counts))
    print("replication, final (macros):", dict(rep))
    print("label x number:", {f"{a}/{b}": v for (a, b), v in sorted(cross.items())})
    miss = [x for x in S if x["rep"]["label_class"] == "exact" and x["rep"]["num_class"] in ("approximate", "failed")]
    print(f"label exact, number approximate/failed: {len(miss)} specs from {len({x['suffix'] for x in miss})} papers; "
          "documented deviation flags:", dict(collections.Counter(x["rep"]["flags"] or "none" for x in miss)))
    print("software (papers):", dict(sc), "ambiguous:", sorted(s for s, v in soft.items() if v[1]))
    print("adoption population:", {jn: tot[jn][0] for jn in ADOPT_JOURNALS},
          "eligible / near-miss:", collections.Counter((p["journal"], p["eligible"], p["near_miss"]) for p in pop))
    for a, b in PERIODS:
        print(f"  {period_label(a, b, False)}: " + "  ".join(f"{jl[jn]} {cells[(jn, a, b)][1]}/{cells[(jn, a, b)][0]}" for jn in ADOPT_JOURNALS))
    print(f"  year from the screening record (not in crossref_years.csv): {len(fallback_year)}; no year: {len(no_year)}")
    print("macros:", macros)
    for msg in problems:
        print("  input problem:", msg)


if __name__ == "__main__":
    main()
