#!/usr/bin/env python3
"""Local dev server: serves static files. Backend is Supabase (CORS handled by Supabase)."""

import http.server
import os

PORT = 8080

os.chdir(os.path.dirname(os.path.abspath(__file__)))
print(f"XFIX dev server: http://localhost:{PORT}/dashboard.html")
http.server.HTTPServer(("", PORT), http.server.SimpleHTTPRequestHandler).serve_forever()
