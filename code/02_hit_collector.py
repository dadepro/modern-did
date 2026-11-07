#!/usr/bin/env python3
"""Tiny local collector: the browser posts one JSON blob per search-results page here.
Each POST body: {"journal":..,"query":..,"page":..,"count":..,"dois":[...]}
Saved to data/hits/raw/<journal>__<query>__p<page>.json
"""
import json, pathlib, re, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
OUT = pathlib.Path(__file__).resolve().parents[1] / "data" / "hits" / "raw"
OUT.mkdir(parents=True, exist_ok=True)
class H(BaseHTTPRequestHandler):
    def _cors(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "*")
        self.send_header("Access-Control-Allow-Methods", "POST, OPTIONS")
        # Chrome Private Network Access: a public https page may only call loopback if the
        # preflight response carries this header.
        self.send_header("Access-Control-Allow-Private-Network", "true")
    def do_OPTIONS(self):
        self.send_response(204); self._cors(); self.end_headers()
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(n)
        try:
            d = json.loads(body)
            safe = lambda s: re.sub(r"[^A-Za-z0-9._-]+", "_", str(s))[:60]
            fn = OUT / f"{safe(d['journal'])}__{safe(d['query'])}__p{int(d['page'])}.json"
            fn.write_text(json.dumps(d, indent=0))
            msg = f"saved {fn.name} ({len(d.get('dois', []))} dois, count={d.get('count')})"
            code = 200
        except Exception as e:
            msg, code = f"error: {e}", 400
        print(msg, file=sys.stderr, flush=True)
        self.send_response(code); self._cors(); self.send_header("Content-Type", "text/plain"); self.end_headers()
        self.wfile.write(msg.encode())
    def log_message(self, *a): pass
if __name__ == "__main__":
    HTTPServer(("127.0.0.1", 8977), H).serve_forever()
