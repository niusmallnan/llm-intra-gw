#!/usr/bin/env python3
"""
Integration tests for llm-intra-gw.

Starts a mock upstream API, launches the gateway via docker-compose pointed
at the mock, runs all test cases, then tears everything down.

Usage:
  make test                       # full integration test (builds if needed)
  MOCK_ONLY=1 python3 scripts/test.py  # start mock API only (manual testing)
"""

import http.client
import json
import os
import re
import signal
import subprocess
import sys
import time
import urllib.request


SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_DIR = os.path.dirname(SCRIPT_DIR)
MOCK_PORT = int(os.environ.get("MOCK_PORT", 18080))
GATEWAY_PORT = int(os.environ.get("GATEWAY_PORT", 8080))
GATEWAY_URL = f"http://localhost:{GATEWAY_PORT}"

pass_count = 0
fail_count = 0
mock_proc = None


def main():
    global mock_proc

    signal.signal(signal.SIGINT, lambda sig, frame: cleanup_and_exit())
    signal.signal(signal.SIGTERM, lambda sig, frame: cleanup_and_exit())

    mock_only = os.environ.get("MOCK_ONLY") == "1"

    # ---- start mock API ----
    print("=== Starting mock API (port %d) ===" % MOCK_PORT)
    mock_proc = subprocess.Popen(
        [sys.executable, os.path.join(SCRIPT_DIR, "mock_api.py")],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,  # merge for log clarity
    )

    if not wait_for(f"http://localhost:{MOCK_PORT}/health", timeout=10):
        fatal("mock API did not start")

    print("Mock API is up.")

    if mock_only:
        print("[mock_only] mock API running on :%d — Ctrl-C to stop" % MOCK_PORT)
        try:
            mock_proc.wait()
        except KeyboardInterrupt:
            pass
        sys.exit(0)

    # ---- start gateway (pointed at mock) ----
    mock_host = os.environ.get("MOCK_HOST", "host.docker.internal")
    upstream = f"http://{mock_host}:{MOCK_PORT}"

    upstream_base = os.environ.get("UPSTREAM_BASE_URL", upstream)
    apikey = os.environ.get("APIKEY", "test-api-key")
    access_code = os.environ.get("PERSONAL_ACCESS_CODE", "test-access-code")
    extra_headers = os.environ.get("EXTRA_HEADERS", '{"X-Department":"ai-test"}')
    strip_path = os.environ.get("STRIP_REQUEST_PATH", "true")

    print("=== Starting gateway (docker compose) ===")
    print(f"  UPSTREAM_BASE_URL={upstream_base}")
    print(f"  APIKEY={apikey}")
    print(f"  PERSONAL_ACCESS_CODE={access_code}")
    print(f"  EXTRA_HEADERS={extra_headers}")
    print(f"  STRIP_REQUEST_PATH={strip_path}")

    docker_env = os.environ.copy()
    docker_env.update({
        "UPSTREAM_BASE_URL": upstream_base,
        "APIKEY": apikey,
        "PERSONAL_ACCESS_CODE": access_code,
        "EXTRA_HEADERS": extra_headers,
        "STRIP_REQUEST_PATH": strip_path,
        "GATEWAY_PORT": str(GATEWAY_PORT),
    })

    result = subprocess.run(
        ["docker", "compose", "--project-directory", PROJECT_DIR, "up", "-d", "--build", "--wait"],
        env=docker_env,
        capture_output=True,
        text=True,
        timeout=120,
    )
    if result.stdout:
        for line in result.stdout.splitlines():
            print(f"  {line}")
    if result.returncode != 0:
        if result.stderr:
            print(result.stderr, file=sys.stderr)
        docker_logs()
        fatal("docker compose up failed")

    if not wait_for(f"{GATEWAY_URL}/health", timeout=15):
        docker_logs()
        fatal("gateway did not start")

    print("Gateway is up.")

    # ---- run tests ----
    print("\n=== Running tests ===")
    try:
        run_tests()
    finally:
        print()
        print(f"Tests: {pass_count + fail_count} | Passed: {pass_count} | Failed: {fail_count}")
        cleanup()
        if fail_count > 0:
            sys.exit(1)


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------


def cleanup_and_exit(code=1):
    cleanup()
    sys.exit(code)


def cleanup():
    global mock_proc
    if mock_proc is not None and mock_proc.poll() is None:
        print("[cleanup] stopping mock API (pid %d)..." % mock_proc.pid)
        mock_proc.terminate()
        try:
            mock_proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            mock_proc.kill()
            mock_proc.wait()

    if os.environ.get("MOCK_ONLY") != "1":
        print("[cleanup] docker compose down...")
        subprocess.run(
            ["docker", "compose", "--project-directory", PROJECT_DIR, "down", "--timeout", "5"],
            capture_output=True,
        )


def fatal(msg):
    print(f"FATAL: {msg}", file=sys.stderr)
    cleanup()
    sys.exit(1)


def docker_logs():
    """Print recent gateway container logs for debugging."""
    result = subprocess.run(
        ["docker", "compose", "--project-directory", PROJECT_DIR, "logs", "--tail", "30"],
        capture_output=True,
        text=True,
    )
    if result.stdout:
        for line in result.stdout.splitlines():
            print(f"  [log] {line}")


def wait_for(url, timeout=30):
    """Poll url until it responds with 2xx, or timeout."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            req = urllib.request.Request(url, method="GET")
            resp = urllib.request.urlopen(req, timeout=3)
            if 200 <= resp.status < 300:
                return True
        except Exception:
            pass
        time.sleep(1)
    return False


def check(label, condition, detail=""):
    """Report a single test result."""
    global pass_count, fail_count
    print(f"  {label:<55s} ", end="")
    if condition:
        print("PASS")
        pass_count += 1
    else:
        print(f"FAIL ({detail})" if detail else "FAIL")
        fail_count += 1


def http_get(url):
    """GET request, returns (status, body)."""
    try:
        req = urllib.request.Request(url, method="GET")
        with urllib.request.urlopen(req, timeout=10) as resp:
            return resp.status, resp.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", errors="replace")
    except Exception:
        return 0, ""


def http_post(url, body, headers=None):
    """POST request, returns (status, body)."""
    if headers is None:
        headers = {}
    data = body.encode() if isinstance(body, str) else body
    try:
        req = urllib.request.Request(url, data=data, headers=headers, method="POST")
        with urllib.request.urlopen(req, timeout=10) as resp:
            return resp.status, resp.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", errors="replace")
    except Exception:
        return 0, ""


# ---------------------------------------------------------------------------
# test cases
# ---------------------------------------------------------------------------


def run_tests():
    # --- 1. health check ---
    status, _ = http_get(f"{GATEWAY_URL}/health")
    check("GET /health → 200", status == 200, f"got {status}")

    # --- 2. unknown path returns 404 ---
    status, _ = http_get(f"{GATEWAY_URL}/unknown")
    check("GET /unknown → 404", status == 404, f"got {status}")

    # --- 3-5. /v1/models returns curated list ---
    status, body = http_get(f"{GATEWAY_URL}/v1/models")
    if status == 200:
        check("/v1/models → DeepSeek-v4-Pro",
              '"id":"DeepSeek-v4-Pro"' in body,
              "missing model id")
        check("/v1/models → GLM-5.1",
              '"id":"GLM-5.1"' in body,
              "missing model id")
        check("/v1/models → object:list",
              '"object":"list"' in body,
              "wrong object type")
    else:
        check("/v1/models → 200", False, f"got {status}")

    # --- 6-10. chat completions — header injection ---
    req_body = '{"model":"DeepSeek-v4-Pro","messages":[{"role":"user","content":"hello"}]}'
    status, echo_body = http_post(
        f"{GATEWAY_URL}/v1/chat/completions",
        req_body,
        headers={
            "Content-Type": "application/json",
            "Authorization": "Bearer client-fake-key",
        },
    )

    if status == 200:
        # apikey injected
        check("chat/completions → apikey injected",
              bool(re.search(r'"apikey"\s*:\s*"test-api-key"', echo_body)),
              "header not found")

        # Authorization replaced
        check("chat/completions → Authorization replaced",
              bool(re.search(r'"Authorization"\s*:\s*"ACCESSCODE test-access-code"', echo_body)),
              "header not found")

        # Client's original Authorization stripped
        leaked = re.search(r'"Authorization"\s*:\s*"Bearer client-fake-key"', echo_body)
        check("chat/completions → client auth stripped",
              not leaked,
              "client auth leaked to upstream" if leaked else "")

        # EXTRA_HEADERS injected
        check("chat/completions → extra headers injected",
              bool(re.search(r'"X-Department"\s*:\s*"ai-test"', echo_body)),
              "header not found")

        # body preserved
        check("chat/completions → body preserved",
              '"messages":' in echo_body,
              "body missing")
    else:
        check("chat/completions → 200", False, f"got {status}")

    # --- 11. Content-Type validation: non-JSON rejected ---
    status, _ = http_post(
        f"{GATEWAY_URL}/v1/chat/completions",
        "not json",
        headers={"Content-Type": "text/plain"},
    )
    check("POST with text/plain → 415", status == 415, f"got {status}")

    # --- 12. Content-Type with charset is accepted ---
    status, _ = http_post(
        f"{GATEWAY_URL}/v1/chat/completions",
        '{"test":true}',
        headers={"Content-Type": "application/json; charset=utf-8"},
    )
    check("POST with json+charset → 200", status == 200, f"got {status}")

    # --- 13. GET without Content-Type allowed ---
    status, _ = http_get(f"{GATEWAY_URL}/v1/models")
    check("GET without Content-Type → 200", status == 200, f"got {status}")


if __name__ == "__main__":
    main()
