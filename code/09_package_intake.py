#!/usr/bin/env python3
"""Intake of replication packages.
1. Move newly downloaded archives from ~/Downloads into packages/<journal>/<doi-suffix>/ and extract.
2. Inventory each package: code files by language, data files by extension and size, README,
   regression commands found in code (Stata/R/Python), candidate treatment and FE variables.
Output: data/packages/inventory.csv and data/packages/<doi-suffix>_regressions.txt
Usage: python3 code/09_package_intake.py [--doi <suffix> --file <archive>]  (default: scan ~/Downloads)
"""
import csv, fcntl, os, pathlib, re, shutil, subprocess, sys, zipfile, tarfile, time, collections
ROOT = pathlib.Path(__file__).resolve().parents[1]
PK = pathlib.Path.home() / "did_packages"; OUT = ROOT / "data" / "packages"; OUT.mkdir(parents=True, exist_ok=True)
DL = pathlib.Path.home() / "Downloads"
DL2 = ROOT / "related"  # Chrome saved here once; scan both

CODE_EXT = {".do": "stata", ".ado": "stata", ".r": "r", ".rmd": "r", ".qmd": "r", ".py": "python", ".ipynb": "python",
            ".m": "matlab", ".jl": "julia", ".sas": "sas", ".sql": "sql", ".sh": "shell"}
DATA_EXT = {".dta", ".csv", ".rds", ".rdata", ".rda", ".parquet", ".feather", ".xlsx", ".xls", ".txt", ".tsv", ".json",
            ".sav", ".mat", ".pkl", ".gz", ".zip", ".7z", ".rar", ".db", ".sqlite", ".fst"}
REG_PATS = {
    "stata": re.compile(r"^\s*(?:qui(?:etly)?\s+|cap(?:ture)?\s+|noi(?:sily)?\s+|eststo[^:]*:\s*|est(?:imates)?\s+store[^:]*:\s*)*"
                        r"(reghdfe|areg|xtreg|reg(?:ress)?|ppmlhdfe|poisson|xtpoisson|logit|probit|ivreghdfe|ivreg2|xtivreg|csdid|did_imputation|did_multiplegt|eventstudyinteract|did2s|jwdid|stackedev|bacondecomp|xthdidregress|hdidregress|wooldid|sdid)\b.*$", re.I | re.M),
    "r": re.compile(r"\b(feols|felm|lm|glm|plm|fepois|fixest|lfe|att_gt|did_imputation|did2s|sunab|did_multiplegt|etwfe|synthdid|lm_robust|feglm)\s*\(", re.I),
    "python": re.compile(r"\b(smf\.ols|sm\.OLS|PanelOLS|feols|linearmodels|statsmodels|pyfixest)\b", re.I),
}
TREAT_HINT = re.compile(r"\b(treat\w*|post\w*|after\w*|adopt\w*|entry\w*|launch\w*|exposed?\w*|policy\w*|law\w*|ban\w*|legal\w*|reform\w*|rollout\w*|did\w*|dd\w*|event\w*|cohort\w*|first[_.]?treat\w*|gvar|tr\w*post\w*)\b", re.I)

def _extract_into(archive: pathlib.Path, tmp: pathlib.Path):
    """Extract archive into tmp; raises on failure. zipfile first; /usr/bin/unzip for methods zipfile lacks (e.g.
    Deflate64, found on mksc.2022.0080 / mksc.2021.1306); /usr/bin/tar (libarchive) for tar archives, because
    tarfile's filter= argument needs Python >= 3.9.17 (review R1)."""
    if zipfile.is_zipfile(archive):
        try:
            with zipfile.ZipFile(archive) as z:
                for m in z.infolist():
                    if m.filename.startswith("__MACOSX") or ".." in m.filename:
                        continue
                    z.extract(m, tmp)
        except (NotImplementedError, zipfile.BadZipFile, RuntimeError) as e:
            print(f"  zipfile failed for {archive.name} ({e}); falling back to /usr/bin/unzip", file=sys.stderr)
            shutil.rmtree(tmp, ignore_errors=True); tmp.mkdir(parents=True)
            r = subprocess.run(["/usr/bin/unzip", "-qq", "-o", str(archive), "-d", str(tmp), "-x", "__MACOSX/*"], capture_output=True, text=True)
            if r.returncode not in (0, 1):   # 1 = warnings only
                raise RuntimeError(f"unzip rc={r.returncode}: {r.stderr[:300]}")
    elif tarfile.is_tarfile(archive):
        r = subprocess.run(["/usr/bin/tar", "-xf", str(archive), "-C", str(tmp)], capture_output=True, text=True)
        if r.returncode != 0:
            raise RuntimeError(f"tar rc={r.returncode}: {r.stderr[:300]}")
    else:
        r = subprocess.run(["/usr/bin/tar", "-xf", str(archive), "-C", str(tmp)], capture_output=True, text=True)   # 7z/rar via libarchive
        if r.returncode != 0:
            shutil.copy2(archive, tmp / archive.name)   # unreadable: copied, not extracted (flagged in inventory)
    if not any(p.is_file() for p in tmp.rglob("*")):
        raise RuntimeError("archive produced no files")

def extract(archive: pathlib.Path, dest: pathlib.Path) -> bool:
    """Extract into <dest>.partial and rename to <dest> only on success (review B1: a failed or interrupted extraction
    used to leave a non-empty dest that every later run skipped as 'already extracted'). Returns success."""
    tmp = dest.with_name(dest.name + ".partial")
    shutil.rmtree(tmp, ignore_errors=True); tmp.mkdir(parents=True)
    try:
        _extract_into(archive, tmp)
    except Exception as e:
        print(f"  extract failed for {archive.name}: {e}", file=sys.stderr)
        shutil.rmtree(tmp, ignore_errors=True); return False
    for inner in list(tmp.rglob("*.zip")):   # second-level archives (best effort, as before)
        try:
            with zipfile.ZipFile(inner) as z:
                z.extractall(inner.with_suffix(""))
        except Exception:
            pass
    for inner in [p for p in tmp.rglob("*") if p.suffix.lower() in (".7z", ".rar")]:   # /usr/bin/tar (libarchive) reads 7z and rar
        out = inner.with_suffix(""); out.mkdir(parents=True, exist_ok=True)
        subprocess.run(["/usr/bin/tar", "-xf", str(inner), "-C", str(out)], capture_output=True)
    if dest.exists():
        shutil.rmtree(dest)
    os.rename(tmp, dest)
    return True

def inventory(pkg_dir: pathlib.Path, journal: str, suffix: str):
    files = [p for p in pkg_dir.rglob("*") if p.is_file()]
    code = collections.Counter(); data = collections.Counter(); data_bytes = 0; readme = []
    regs = []
    for p in files:
        ext = p.suffix.lower()
        if ext in CODE_EXT:
            lang = CODE_EXT[ext]; code[lang] += 1
            try:
                txt = p.read_text(errors="ignore")
            except Exception:
                continue
            pat = REG_PATS.get(lang)
            if pat:
                for m in pat.finditer(txt):
                    line = txt[txt.rfind("\n", 0, m.start()) + 1: txt.find("\n", m.end()) if txt.find("\n", m.end()) > 0 else None]
                    regs.append((str(p.relative_to(pkg_dir)), line.strip()[:300]))
        elif ext in DATA_EXT:
            data[ext] += 1; data_bytes += p.stat().st_size
        if re.match(r"readme", p.name, re.I):
            readme.append(str(p.relative_to(pkg_dir)))
    (OUT / f"{suffix}_regressions.txt").write_text("\n".join(f"{f} :: {l}" for f, l in regs))
    fe_hits = sum(1 for _, l in regs if re.search(r"absorb|\|\s*\w+\s*\+|fe\b|i\.year|i\.time|xtreg.*fe|factor\(", l, re.I))
    modern = sum(1 for _, l in regs if re.search(r"csdid|did_imputation|did_multiplegt|eventstudyinteract|did2s|att_gt|sunab|jwdid|stackedev|bacondecomp|etwfe|wooldid", l, re.I))
    treat_vars = collections.Counter(w.lower() for _, l in regs for w in TREAT_HINT.findall(l))
    return {
        "journal": journal, "doi_suffix": suffix, "n_files": len(files), "n_code": sum(code.values()),
        "code_langs": ";".join(f"{k}:{v}" for k, v in code.most_common()), "n_data": sum(data.values()),
        "data_mb": round(data_bytes / 1e6, 1), "data_exts": ";".join(f"{k}:{v}" for k, v in data.most_common(6)),
        "readme": ";".join(readme[:3]), "n_regressions": len(regs), "n_fe_regressions": fe_hits, "n_modern_did_cmds": modern,
        "treat_var_hints": ";".join(f"{k}:{v}" for k, v in treat_vars.most_common(8)),
        "intake_time": time.strftime("%Y-%m-%d %H:%M"),
    }

def write_inventory(inv_path, row=None, rows=None):
    """Merge rows into inventory.csv: re-read the current file, update, write a temp file and os.replace (review B2/R3)."""
    cur = {r["doi_suffix"]: r for r in csv.DictReader(open(inv_path, newline=""))} if inv_path.exists() else {}
    for r in ([row] if row else []) + list(rows or []):
        cur[r["doi_suffix"]] = r
    if not cur:
        return 0
    fields = []
    for r in cur.values():
        for k in r:
            if k not in fields: fields.append(k)
    tmp = inv_path.with_name(inv_path.name + ".tmp")
    with open(tmp, "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=fields, restval=""); w.writeheader(); w.writerows(cur.values())
        fh.flush(); os.fsync(fh.fileno())
    os.replace(tmp, inv_path)
    return len(cur)

def zip_complete(archive: pathlib.Path, dest: pathlib.Path):
    """True/False whether every non-directory member of a zip exists in dest; None if not checkable."""
    try:
        with zipfile.ZipFile(archive) as z:
            for m in z.infolist():
                if m.is_dir() or m.filename.startswith("__MACOSX") or ".." in m.filename: continue
                p = dest / m.filename
                if not p.exists(): return False   # missing member = incomplete extraction (size differences are not
        return True                                        # flagged: e.g. Stata's outreg2 rewrites its .pref file in place)
    except Exception:
        return None

def main():
    args = sys.argv[1:]
    inv_path = OUT / "inventory.csv"
    # one intake at a time (review B2: two concurrent runs lost inventory rows); a second run exits at once
    lockf = open(PK / ".intake.lock", "w")
    try:
        fcntl.flock(lockf, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print("another intake run holds the lock; exiting"); return
    if "--repair" in args:
        # (a) re-extract packages whose dest has no files besides the moved archive (failed extraction), or whose zip is
        # incomplete; (b) inventory every dest dir that has no inventory row
        inv = {r["doi_suffix"] for r in csv.DictReader(open(inv_path, newline=""))} if inv_path.exists() else set()
        for j in ("mnsc", "mksc"):
            for dest in sorted((PK / j).glob(f"{j}.*")):
                if not dest.is_dir() or dest.name.endswith(".partial"): continue
                arcs = sorted(dest.glob("_archive_*"))
                content = [p for p in dest.rglob("*") if p.is_file() and not p.name.startswith("_archive_")]
                bad = (not content) or (arcs and arcs[0].suffix.lower() == ".zip" and zip_complete(arcs[0], dest) is False)
                if bad and arcs:
                    print(f"  {dest.name}: incomplete extraction ({len(content)} files); re-extracting {arcs[0].name}")
                    keep = dest.with_name(dest.name + ".archive_hold"); keep.mkdir(exist_ok=True)
                    a = shutil.move(str(arcs[0]), keep / arcs[0].name)
                    ok = extract(pathlib.Path(a), dest)
                    dest.mkdir(exist_ok=True); shutil.move(a, dest / pathlib.Path(a).name); shutil.rmtree(keep, ignore_errors=True)
                    print(f"  {dest.name}: re-extract {'ok' if ok else 'FAILED'}")
                    row = inventory(dest, j, dest.name); row["extract_status"] = "ok" if ok else "extract_failed"
                    write_inventory(inv_path, row); inv.add(dest.name)
                elif dest.name not in inv:
                    print(f"  {dest.name}: missing from inventory; adding")
                    row = inventory(dest, j, dest.name); row["extract_status"] = "ok"
                    write_inventory(inv_path, row); inv.add(dest.name)
        print(f"{write_inventory(inv_path)} packages in inventory"); return
    jobs = []
    if "--doi" in args:
        suffix = args[args.index("--doi") + 1]; f = pathlib.Path(args[args.index("--file") + 1])
        jobs.append((suffix, f))
    else:
        INC = PK / "_incoming"
        for f in list(DL.iterdir()) + list(DL2.iterdir()) + (list(INC.iterdir()) if INC.exists() else []):
            m = re.match(r"(mnsc|mksc)[._-](\d{4}[._]\d+)", f.name, re.I)
            if f.name.endswith((".part", ".crdownload")):
                continue
            if m and f.suffix.lower() in (".zip", ".7z", ".rar", ".tar", ".gz", ".tgz"):
                jobs.append((f"{m.group(1).lower()}.{m.group(2).replace('_', '.')}", f))
    FAILD = OUT / "extract_failed"; FAILD.mkdir(exist_ok=True)
    for suffix, f in jobs:
        try:
            journal = suffix.split(".")[0]
            dest = PK / journal / suffix
            if dest.exists() and any(dest.iterdir()):
                print(f"  {suffix}: already extracted"); continue
            marker = FAILD / f"{suffix}.txt"
            if marker.exists() and marker.stat().st_mtime > f.stat().st_mtime:
                continue   # this archive already failed; retry only when a newer archive arrives
            print(f"  {suffix}: extracting {f.name} ({f.stat().st_size/1e6:.1f} MB)")
            ok = extract(f, dest)
            if not ok:
                marker.write_text(f"{time.strftime('%Y-%m-%d %H:%M')} extract failed for {f}")
                write_inventory(inv_path, {"journal": journal, "doi_suffix": suffix, "extract_status": "extract_failed",
                                           "intake_time": time.strftime("%Y-%m-%d %H:%M")})
                continue
            shutil.move(str(f), dest / ("_archive_" + f.name))
            row = inventory(dest, journal, suffix); row["extract_status"] = "ok" if f.suffix.lower() in (".zip", ".tar", ".gz", ".tgz") else "copied_unextracted"
            write_inventory(inv_path, row)   # per package, so an exception later cannot drop earlier rows
        except Exception as e:
            print(f"  {suffix}: intake error {e!r}", file=sys.stderr)
    print(f"{write_inventory(inv_path)} packages in inventory")

if __name__ == "__main__":
    main()
