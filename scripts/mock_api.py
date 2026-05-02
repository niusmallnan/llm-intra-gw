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

    def _echo(self, body_data=None):
        if body_data is None:
            body_raw = self._read_body()
            if body_raw.strip():
                try:
                    body_data = json.loads(body_raw)
                except json.JSONDecodeError:
                    body_data = {"raw": body_raw}

        self._send_json(200, {
            "echo": {
                "method": self.command,
                "path": self.path,
                "headers": dict(self.headers),
                "body": body_data,
            }
        })

    def _send_sse_event(self, data):
        """Send one SSE event (data: <json>\n\n)."""
        payload = "data: " + json.dumps(data, ensure_ascii=False) + "\n\n"
        self.wfile.write(payload.encode())
        self.wfile.flush()

    def _send_sse_stream(self, body_data):
        """Return a test SSE stream with chunks that trigger response transformation."""
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()

        model = body_data.get("model", "test")

        # Chunk 1: content="" with tool_calls → gateway should change content to null
        self._send_sse_event({
            "id": "chunk-1",
            "object": "chat.completion.chunk",
            "created": 1715555555,
            "model": model,
            "choices": [{
                "index": 0,
                "delta": {
                    "content": "",
                    "tool_calls": [{
                        "index": 0,
                        "id": "call_test123",
                        "type": "function",
                        "function": {
                            "name": "get_current_weather",
                            "arguments": ""
                        }
                    }]
                }
            }]
        })

        # Chunk 2: regular content (no tool_calls) → should pass through unchanged
        self._send_sse_event({
            "id": "chunk-2",
            "object": "chat.completion.chunk",
            "created": 1715555555,
            "model": model,
            "choices": [{
                "index": 0,
                "delta": {
                    "content": "The weather in Shenyang is sunny."
                }
            }]
        })

        # Chunk 3: DONE marker
        self.wfile.write("data: [DONE]\n\n".encode())
        self.wfile.flush()

    def do_GET(self):
        self._echo()

    def do_POST(self):
        ct = self.headers.get("Content-Type", "")
        if ct and not ct.lower().startswith("application/json"):
            self._send_json(415, {
                "error": {
                    "message": "unsupported content-type: " + ct,
                    "type": "invalid_request_error",
                }
            })
            return

        body_raw = self._read_body()
        body_data = None
        if body_raw.strip():
            try:
                body_data = json.loads(body_raw)
            except json.JSONDecodeError:
                body_data = {"raw": body_raw}

        # If the client requests streaming, return SSE test chunks.
        if body_data and isinstance(body_data, dict) and body_data.get("stream") is True:
            self._send_sse_stream(body_data)
            return

        self._echo(body_data)

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
