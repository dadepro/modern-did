#!/usr/bin/env python3
"""Request and download INFORMS replication packages by submitting the journal's
replication-file form (name, organization, email, agreement) for each candidate paper,
as authorized by the PI on Nov 1, 2026. Sequential, paced, resumable.
Usage: python3 code/12_fetch_packages.py [--tier 1] [--max N] [--sleep 4]
Saves archives to ~/did_packages/_incoming/<suffix>.<ext>; updates package_manifest.csv."""
import os, csv, pathlib, re, subprocess, sys, time, tempfile
ROOT = pathlib.Path(__file__).resolve().parents[1]
MAN = ROOT / "data/candidates/package_manifest.csv"
INC = pathlib.Path.home() / "did_packages" / "_incoming"; INC.mkdir(parents=True, exist_ok=True)
FORM = {"first_name": "the PI", "last_name": "Proserpio", "org": "USC Marshall School of Business",
        "email": "proserpi@marshall.usc.edu", "ack": "1"}
args = sys.argv[1:]
tier = args[args.index("--tier") + 1] if "--tier" in args else None
maxn = int(args[args.index("--max") + 1]) if "--max" in args else 10**6
pause = float(args[args.index("--sleep") + 1]) if "--sleep" in args else 4.0
shard = args[args.index("--shard") + 1] if "--shard" in args else "0/1"
only = set(args[args.index("--only") + 1].split(",")) if "--only" in args else None
jfilter = set(args[args.index("--journal") + 1].split(",")) if "--journal" in args else None  # restrict a worker to given journal keys
force = "--force" in args  # with --only: re-fetch even if a status file or manifest status says downloaded
k, nshard = (int(x) for x in shard.split("/"))
ST = ROOT / "data/packages/status"; ST.mkdir(parents=True, exist_ok=True)

def save_manifest(man):
    with open(MAN, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(man[0].keys())); w.writeheader(); w.writerows(man)

def fetch_one(journal, suffix):
    with tempfile.TemporaryDirectory() as td:
        cj = pathlib.Path(td) / "cj.txt"
        form_url = f"https://services.informs.org/dataset/{journal}/download.php?doi={suffix}"
        page = subprocess.run(["curl", "-s", "-c", str(cj), "-b", str(cj), "-L", "--max-time", "60", form_url],
                              capture_output=True, text=True).stdout
        m = re.search(r'name="token" value="([0-9a-f]{32})"', page)
        if not m:
            if "not found" in page.lower() or "no replication" in page.lower() or len(page) < 500:
                return "no_package_page", 0
            return "no_token", 0
        data = ["--data-urlencode", f"doi={suffix}", "--data-urlencode", f"token={m.group(1)}"]
        for k, v in FORM.items():
            data += ["--data-urlencode", f"{k}={v}"]
        hdr = pathlib.Path(td) / "hdr.txt"
        subprocess.run(["curl", "-s", "-c", str(cj), "-b", str(cj), "-D", str(hdr), "-o", "/dev/null", "-e", form_url,
                        "--max-time", "60", *data, "https://services.informs.org/dataset/action/download_process.php"],
                       capture_output=True, text=True)
        loc = re.search(r"^location:\s*(\S+)", hdr.read_text(), re.I | re.M)
        if not loc or "amazonaws" not in loc.group(1):
            return ("no_file_redirect:" + (loc.group(1)[:60] if loc else "none")), 0
        url = loc.group(1)
        ext = re.search(r"/datasets/\w+/[^?]+?(\.[A-Za-z0-9]+)\?", url)
        out = INC / f"{suffix}{ext.group(1) if ext else '.zip'}"
        part = out.with_name(f"{out.name}.{os.getpid()}.part")   # per-process temp name (review R4)
        r = subprocess.run(["curl", "-s", "-L", "--max-time", "3600", "--speed-time", "60", "--speed-limit", "2000", "-o", str(part), "-w", "%{http_code} %{size_download}", url],
                           capture_output=True, text=True)
        code, size = r.stdout.split()[:2] if r.stdout else ("0", "0")
        if code != "200" or int(size) < 100 or r.returncode != 0:
            part.unlink(missing_ok=True)   # record curl's exit code too, so transient failures are retried (review B7)
            return (f"download_failed:{code}" if code == "404" else f"download_failed:{code}:rc{r.returncode}"), 0
        part.rename(out)
        return "downloaded", int(size)

man = list(csv.DictReader(open(MAN, newline="")))
done = 0
for i, r in enumerate(man):
    if only is not None and r["suffix"] not in only:
        continue
    if jfilter is not None and r["journal"] not in jfilter:
        continue
    if only is None and (i % nshard != k or (tier and r["tier"] != tier)):
        continue
    sf = ST / f"{r['suffix']}.txt"
    if force and only is not None:
        pass
    elif sf.exists() and not (sf.read_text().startswith(("download_failed:", "no_token", "no_file_redirect:none"))
                              and not sf.read_text().startswith("download_failed:404")):   # retry every failure except 404
        continue
    if not (force and only is not None) and r["status"] in ("downloaded", "download_failed:404"):
        sf.write_text(r["status"]); continue
    if done >= maxn:
        break
    t0 = time.time()
    status, size = fetch_one(r["journal"], r["suffix"])
    sf.write_text(f"{status}\t{size}")
    print(f"{time.strftime('%H:%M:%S')} shard{k} {r['suffix']:18s} tier{r['tier']} {status:28s} {size/1e6:8.1f} MB  {time.time()-t0:5.0f}s", flush=True)
    done += 1
    time.sleep(pause)
print("finished", done, flush=True)
