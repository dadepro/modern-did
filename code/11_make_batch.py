#!/usr/bin/env python3
"""Print a browser_batch action list that requests N replication packages from INFORMS.
Each paper: navigate to the form page, wait, fill + submit via JS, wait for the download to start.
Usage: python3 code/11_make_batch.py <tabId> <N> [--tier 1]"""
import csv, json, sys, pathlib
ROOT = pathlib.Path(__file__).resolve().parents[1]
tab = int(sys.argv[1]); n = int(sys.argv[2])
tier = sys.argv[sys.argv.index("--tier") + 1] if "--tier" in sys.argv else None
man = list(csv.DictReader(open(ROOT / "data/candidates/package_manifest.csv", newline="")))
todo = [r for r in man if not r["status"] and (tier is None or r["tier"] == tier)][:n]
JS = ("const f=document.querySelector('form');if(!f){'NOFORM '+document.title.slice(0,60)}else{"
      "const t=[...f.querySelectorAll('input[type=text]')];const v=['Davide','Proserpio','USC Marshall School of Business','proserpi@marshall.usc.edu'];"
      "t.forEach((e,i)=>{if(v[i]!==undefined){e.value=v[i];e.dispatchEvent(new Event('input',{bubbles:true}));}});"
      "const c=f.querySelector('input[type=checkbox]');if(c){c.checked=true;}"
      "const b=f.querySelector('button[type=submit],input[type=submit]');if(b){b.click();}"
      "'SUBMITTED '+location.search.slice(-20)+' fields='+t.length+' cb='+(c?c.checked:'none')}")
actions = []
for r in todo:
    actions.append({"name": "navigate", "input": {"tabId": tab, "url": r["form_url"]}})
    actions.append({"name": "computer", "input": {"tabId": tab, "action": "wait", "duration": 2}})
    actions.append({"name": "javascript_tool", "input": {"tabId": tab, "action": "javascript_exec", "text": JS}})
    actions.append({"name": "computer", "input": {"tabId": tab, "action": "wait", "duration": 4}})
print(json.dumps(actions))
print(f"\n# {len(todo)} papers: " + ", ".join(r["suffix"] for r in todo), file=sys.stderr)
