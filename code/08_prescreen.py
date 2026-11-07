#!/usr/bin/env python3
"""Extract text from downloaded article PDFs and compute regex features for pre-screening.
Text -> data/text/<journal>/<doi-suffix>.txt ; features -> data/screening/prescreen.csv
Run repeatedly; only new PDFs are processed."""
import csv, pathlib, re, subprocess, sys
ROOT = pathlib.Path(__file__).resolve().parents[1]
PAP, TXT = ROOT / "papers", ROOT / "data" / "text"
OUT = ROOT / "data" / "screening" / "prescreen.csv"
OUT.parent.mkdir(parents=True, exist_ok=True)

PATS = {
    "did": r"difference[s]?[- ]in[- ]difference[s]?|diff[- ]in[- ]diff|\bDiD\b|\bDID\b",
    "staggered": r"stagger",
    "diff_timing": r"(at|in) different (times|points in time|years|months|periods)|different adoption (dates|times)|variation in (the )?timing|timing of (adoption|entry|treatment|implementation|rollout)|roll(ed|ing)?[- ]?out",
    "event_study": r"event[- ]stud",
    "twfe": r"two[- ]way fixed effects|\bTWFE\b|unit and (time|year|month) fixed effects|firm and year fixed effects|(county|state|city|store|user|product|individual|hotel|restaurant|zip code|dma|market) and (year|month|week|time|quarter|day) fixed effects",
    "fe_generic": r"fixed effects",
    "always_treated": r"always[- ]treated|never[- ]treated|not[- ]yet[- ]treated|clean controls?|forbidden comparisons?|negative weights",
    "callaway": r"Callaway",
    "sun_abraham": r"Sun and Abraham|Sun & Abraham|eventstudyinteract",
    "borusyak": r"Borusyak|did_imputation|imputation estimator",
    "dcdh": r"Chaisemartin|did_multiplegt",
    "goodman_bacon": r"Goodman[- ]Bacon|bacondecomp",
    "stacked": r"stacked (regression|DiD|difference|event|design)|Cengiz",
    "csdid_cmd": r"\bcsdid\b|\bdid2s\b|\bdidimputation\b|\bfixest\b|\bsunab\b|\breghdfe\b|\bxtreg\b",
    "synth": r"synthetic control",
    "matching": r"propensity score|matched (sample|control)|coarsened exact matching|nearest[- ]neighbou?r",
    "poisson": r"Poisson|negative binomial|logit|probit",
    "iv": r"instrumental variable|two[- ]stage least squares|\b2SLS\b",
    "timevarying_ctrl": r"time[- ]varying (controls?|covariates)|control(s|ling)? for .{0,40}(population|income|unemployment|weather|temperature)",
    "data_avail": r"data (and|&) code|replication (package|files|materials|code)|data availability|disclosure (plan|statement)|alternative disclosure|publicly available|non[- ]?disclosure agreement|\bNDA\b|proprietary",
    "stata": r"\bStata\b|\.do\b|\.dta\b",
    "r_lang": r"\bR package\b|\bRStudio\b|\bggplot|\bfixest\b",
    "python": r"\bPython\b|pandas|statsmodels",
    "pretrend": r"pre[- ]?trend|parallel trend|placebo",
}
CPATS = {k: re.compile(v, re.I) for k, v in PATS.items()}

def main():
    prev = {}
    if OUT.exists():
        for r in csv.DictReader(open(OUT, newline="")):
            prev[r["doi_suffix"]] = r
    rows = dict(prev)
    for jdir in sorted(PAP.iterdir()):
        if not jdir.is_dir():
            continue
        (TXT / jdir.name).mkdir(parents=True, exist_ok=True)
        for pdf in sorted(jdir.glob("*.pdf")):
            key = pdf.stem
            if key in rows:
                continue
            txt_path = TXT / jdir.name / (key + ".txt")
            if not txt_path.exists():
                subprocess.run(["pdftotext", "-layout", str(pdf), str(txt_path)], capture_output=True, timeout=180)
            txt = txt_path.read_text(errors="ignore") if txt_path.exists() else ""
            # drop references section for method flags (keeps citations from inflating counts)
            body = re.split(r"\n\s*References\s*\n", txt, maxsplit=1)[0] if "References" in txt else txt
            r = {"journal": jdir.name, "doi_suffix": key, "n_chars": len(txt), "n_pages": txt.count("\f") + 1}
            for k, pat in CPATS.items():
                r[k] = len(pat.findall(body))
            r["any_modern"] = int(any(r[k] for k in ("callaway", "sun_abraham", "borusyak", "dcdh", "goodman_bacon", "stacked")))
            r["stag_signal"] = int(bool(r["staggered"] or r["diff_timing"] or r["always_treated"]))
            r["did_signal"] = int(bool(r["did"] or r["twfe"] or r["event_study"]))
            # 0 = unlikely, 1 = possible, 2 = likely staggered DiD
            r["prescore"] = 2 if (r["did_signal"] and (r["stag_signal"] or r["any_modern"])) else (1 if r["did_signal"] else 0)
            rows[key] = r
    if not rows:
        print("no PDFs yet"); return
    fields = list(next(iter(rows.values())).keys())
    with open(OUT, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fields); w.writeheader(); w.writerows(rows.values())
    import collections
    c = collections.Counter((r["journal"], str(r["prescore"])) for r in rows.values())
    print(f"{len(rows)} papers; prescore counts:", dict(sorted(c.items())))

if __name__ == "__main__":
    main()
