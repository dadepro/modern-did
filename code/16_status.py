#!/usr/bin/env python3
"""One-screen status of the pipeline."""
import csv, pathlib, collections, glob, time
ROOT = pathlib.Path(__file__).resolve().parents[1]
man = list(csv.DictReader(open(ROOT / "data/candidates/package_manifest.csv", newline="")))
st = collections.Counter((r["status"].split(":")[0] or "pending") for r in man)
t1 = collections.Counter((r["status"].split(":")[0] or "pending") for r in man if r["tier"] == "1")
print(f"{time.strftime('%H:%M')}  packages: {dict(st)} | tier1: {dict(t1)}")
pk = pathlib.Path.home() / "did_packages"
print("  extracted packages:", sum(1 for j in ("mnsc", "mksc", "jmr") for _ in (pk / j).glob("*")) if pk.exists() else 0)
pdfs = {j: len(list((ROOT / "papers" / j).glob("*.pdf"))) for j in ("mnsc", "mksc", "jmr")}
print("  article PDFs:", pdfs)
scr = list(csv.DictReader(open(ROOT / "data/screening/screened.csv", newline=""))) if (ROOT / "data/screening/screened.csv").exists() else []
el = [r for r in scr if r["eligible"] in ("True", "true") and int(r["n_spec_records"] or 0) > 0]
print(f"  screened: {len(scr)} | eligible with specs: {len(el)} | batches: {len(glob.glob(str(ROOT / 'data/screening/batches/*.json')))}")
specs = glob.glob(str(ROOT / "output/specs/*.csv"))
print(f"  spec JSONs: {len(glob.glob(str(ROOT / 'data/specs/*.json')))} | estimated specs: {len(specs)} | papers estimated: {len({pathlib.Path(s).name.split('__')[0] for s in specs})}")
