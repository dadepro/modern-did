#!/usr/bin/env python3
"""Extract text for every article PDF in papers/<journal>/ that has no data/text/<journal>/<suffix>.txt yet
(pdftotext -layout, as in 08_prescreen.py). Usage: python3 -I code/07b_pdf_to_text.py"""
import pathlib, subprocess
ROOT = pathlib.Path(__file__).resolve().parents[1]
n = 0
for pdf in sorted((ROOT / "papers").glob("*/*.pdf")):
    out = ROOT / "data/text" / pdf.parent.name / (pdf.stem + ".txt")
    if out.exists() and out.stat().st_size > 0: continue
    out.parent.mkdir(parents=True, exist_ok=True)
    try:
        subprocess.run(["pdftotext", "-layout", str(pdf), str(out)], capture_output=True, timeout=180); n += 1
    except Exception as e:
        print("pdftotext failed:", pdf.name, e)
print(f"text extracted for {n} new PDFs")
