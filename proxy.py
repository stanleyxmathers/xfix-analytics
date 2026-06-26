#!/usr/bin/env python3
"""Local dev proxy: serves static files + proxies /webhook/* to n8n with CORS headers."""

import http.server
import urllib.request
import urllib.error
import ssl
import os

_ssl_ctx = ssl.create_default_context()
_ssl_ctx.check_hostname = False
_ssl_ctx.verify_mode = ssl.CERT_NONE

N8N_BASE = "https://imtime.app.n8n.cloud"
PORT = 8080

class Handler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, fmt, *args):
        print(f"  {self.command} {self.path} → {args[0] if args else ''}")

    def _cors(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")

    def do_OPTIONS(self):
        self.send_response(204)
        self._cors()
        self.end_headers()

    def _proxy(self, method):
        target = N8N_BASE + self.path
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length) if length else None
        content_type = self.headers.get("Content-Type", "")

        req = urllib.request.Request(target, data=body, method=method)
        if content_type:
            req.add_header("Content-Type", content_type)

        try:
            with urllib.request.urlopen(req, timeout=30, context=_ssl_ctx) as resp:
                data = resp.read()
                self.send_response(resp.status)
                self.send_header("Content-Type", resp.headers.get("Content-Type", "application/json"))
                self._cors()
                self.end_headers()
                self.wfile.write(data)
        except urllib.error.HTTPError as e:
            data = e.read()
            self.send_response(e.code)
            self.send_header("Content-Type", "application/json")
            self._cors()
            self.end_headers()
            self.wfile.write(data)
        except Exception as e:
            self.send_response(502)
            self.send_header("Content-Type", "application/json")
            self._cors()
            self.end_headers()
            self.wfile.write(f'{{"error":"{e}"}}'.encode())

    def do_GET(self):
        if self.path.startswith("/webhook"):
            self._proxy("GET")
        else:
            super().do_GET()

    def do_POST(self):
        if self.path.startswith("/webhook"):
            self._proxy("POST")
        else:
            self.send_response(405)
            self.end_headers()

os.chdir(os.path.dirname(os.path.abspath(__file__)))
print(f"XFIX dev server: http://localhost:{PORT}/dashboard.html")
print(f"Proxying /webhook/* → {N8N_BASE}")
http.server.HTTPServer(("", PORT), Handler).serve_forever()
