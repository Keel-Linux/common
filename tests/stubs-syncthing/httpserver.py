#!/usr/bin/python3
"""Stub of the Syncthing REST API for tests/syncthing-health.bats.

Answers 200 to /rest/system/ping when the X-API-Key header is the key in
STUB_APIKEY, and 401 to any other key. The port is STUB_PORT. The real
Syncthing is tests/overlay-syncthing.bats'.
"""

import json
import os
from http.server import BaseHTTPRequestHandler, HTTPServer

KEY = os.environ["STUB_APIKEY"]


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.headers.get("X-API-Key") != KEY:
            self.send_response(401)
            self.end_headers()
            return
        if self.path == "/rest/system/ping":
            body = json.dumps({"ping": "pong"}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_response(404)
        self.end_headers()

    def log_message(self, *args):
        pass


HTTPServer(("127.0.0.1", int(os.environ["STUB_PORT"])), Handler).serve_forever()
