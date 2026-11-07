#!/usr/bin/env python3
"""Fetch open-access PDFs (direct links from OpenAlex best_oa_location.pdf_url) for candidates.
Saves to papers/<journal>/<doi-suffix>.pdf when the response is a real PDF. Updates pdf_manifest.csv."""
import csv, pathlib, subprocess, sys, time
ROOT = pathlib.Path(__file__).resolve().parents[1]
cand = {r["doi"].lower(): r for r in csv.DictReader(open(ROOT / "data/candidates/candidates.csv", newline=""))}
MAN = ROOT / "data/candidates/pdf_manifest.csv"
man = list(csv.DictReader(open(MAN, newline="")))
ok = fail = skip = 0
for r in man:
    c = cand.get(r["doi"].lower())
    if not c or not c["oa_pdf_url"] or r["status"] in ("downloaded", "oa_downloaded"):
        continue
    dest = ROOT / "papers" / r["journal"] / (r["doi"].split("/")[1] + ".pdf")
    if dest.exists():
        r["status"] = "oa_downloaded"; skip += 1; continue
    url = c["oa_pdf_url"]
    try:
        res = subprocess.run(["curl", "-sL", "--max-time", "90", "-A", "diff-in-diff-replica/0.1 (mailto:proserpi@marshall.usc.edu)",
                              "-o", str(dest), "-w", "%{http_code} %{content_type}", url], capture_output=True, text=True, timeout=120)
        head = dest.read_bytes()[:5] if dest.exists() else b""
        if head.startswith(b"%PDF"):
            r["status"] = "oa_downloaded"; r["url"] = url; ok += 1
            print(f"  ok   {r['doi']}  {dest.stat().st_size/1e6:.1f} MB  {url[:70]}")
        else:
            dest.unlink(missing_ok=True); r["status"] = f"oa_failed:{res.stdout.strip()[:40]}"; fail += 1
            print(f"  fail {r['doi']}  {res.stdout.strip()[:40]}  {url[:70]}")
    except Exception as e:
        dest.unlink(missing_ok=True); r["status"] = f"oa_error"; fail += 1
    time.sleep(1.0)
with open(MAN, "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=list(man[0].keys())); w.writeheader(); w.writerows(man)
print(f"OA fetch: ok={ok} fail={fail} already={skip}")
