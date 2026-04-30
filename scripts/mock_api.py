#!/usr/bin/env python3
"""
Mock internal LLM API for integration testing.

Handles the subset of endpoints the gateway may forward to the upstream.
Echoes request details (headers, body, path) so tests can verify that the
gateway correctly injects authentication headers, strips client auth, and
respects Content-Type validation.
"""

import http.server
import json
import os
import sys

PORT = int(os.environ.get("MOCK_PORT", 18080))


class Handler(http.server.BaseHTTPRequestHandler):

    def _send_json(self, status, data):
        body = json.dumps(data).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_body(self):
        length = int(self.headers.get("Content-Length", 0))
        if length == 0:
            return ""
        return self.rfile.read(length).decode("utf-8", errors="replace")

    def _echo(self, status=200):
        body = self._read_body()
        # Parse JSON body if present
        parsed = None
        if body.strip():
            try:
                parsed = json.loads(body)
            except json.JSONDecodeError:
                parsed = {"raw": body}

        self._send_json(status, {
            "echo": {
                "method": self.command,
                "path": self.path,
                "headers": dict(self.headers),
                "body": parsed,
            }
        })

    def do_GET(self):
        if self.path == "/health":
            self._send_json(200, {"status": "ok"})
        else:
            self._echo()

    def do_POST(self):
        # Reject non-JSON requests (mirrors the gateway's own validation for
        # realistic upstream behaviour).
        ct = self.headers.get("Content-Type", "")
        if ct and not ct.lower().startswith("application/json"):
            self._send_json(415, {
                "error": {
                    "message": "unsupported content-type: " + ct,
                    "type": "invalid_request_error",
                }
            })
            return
        self._echo()

    def do_PUT(self):
        self._echo()

    def do_DELETE(self):
        self._echo()

    def log_message(self, fmt, *args):
        print("[mock]", fmt % args, file=sys.stderr, flush=True)


def main():
    httpd = http.server.HTTPServer(("0.0.0.0", PORT), Handler)
    httpd.timeout = 1  # allow periodic interruptions
    print(f"[mock] listening on :{PORT}", file=sys.stderr, flush=True)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
