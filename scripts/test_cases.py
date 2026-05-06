#!/usr/bin/env python3
"""
Test cases for llm-intra-gw.

Expects the gateway to be already running. Takes the gateway URL as the
first argument. Prints PASS/FAIL for each test and returns exit code 1
if any test fails.

Assumes the gateway is configured with:
  FAKE_OPENAI_KEY=test-client-key
  UPSTREAM_API_KEY=test-api-key
  PERSONAL_ACCESS_CODE=test-access-code
  EXTRA_HEADERS={"X-Department":"ai-test"}

Usage:
  python3 scripts/test_cases.py http://localhost:8080
"""

import json
import re
import os
import sys
import urllib.error
import urllib.request


pass_count = 0
fail_count = 0

AUTH_HEADER = {"Authorization": "Bearer test-client-key"}
WRONG_AUTH   = {"Authorization": "Bearer wrong-key"}


def check(label, condition, detail=""):
    global pass_count, fail_count
    print(f"  {label:<55s} ", end="")
    if condition:
        print("PASS")
        pass_count += 1
    else:
        print(f"FAIL ({detail})" if detail else "FAIL")
        fail_count += 1


def http_get(url, headers=None):
    try:
        req = urllib.request.Request(url, method="GET", headers=headers or {})
        with urllib.request.urlopen(req, timeout=10) as resp:
            return resp.status, resp.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", errors="replace")
    except Exception:
        return 0, ""


def http_post(url, body, headers=None):
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


def http_post_stream(url, body, headers=None):
    """Send a POST request and return the raw response body (for SSE streaming)."""
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


def parse_sse_events(raw):
    """Parse SSE response, returning list of parsed JSON objects (None for non-JSON events)."""
    events = []
    parts = raw.split("\n\n")
    for part in parts:
        part = part.strip()
        if not part or part == "data: [DONE]":
            continue
        if part.startswith("data: "):
            json_str = part[len("data: "):]
            try:
                events.append(json.loads(json_str))
            except json.JSONDecodeError:
                events.append(None)
    return events


def run_tests(gateway_url):
    upstream_mode = os.environ.get("UPSTREAM_MODE", "")

    # --- 1. health check (no auth needed) ---
    status, _ = http_get(f"{gateway_url}/health")
    check("GET /health → 200", status == 200, f"got {status}")

    # --- 2. unknown path returns 404 (no auth needed) ---
    status, _ = http_get(f"{gateway_url}/unknown")
    check("GET /unknown → 404", status == 404, f"got {status}")

    # --- 3. FAKE_OPENAI_KEY: missing auth → 401 (on /v1/models) ---
    status, body = http_get(f"{gateway_url}/v1/models")
    check("GET /v1/models without auth → 401", status == 401, f"got {status}")

    # --- 4. FAKE_OPENAI_KEY: wrong auth → 401 ---
    status, body = http_post(
        f"{gateway_url}/v1/chat/completions",
        '{"model":"test"}',
        headers={**WRONG_AUTH, "Content-Type": "application/json"},
    )
    check("POST with wrong auth → 401", status == 401, f"got {status}")

    # --- 5-7. /v1/models with valid auth returns curated list ---
    status, body = http_get(f"{gateway_url}/v1/models", headers=AUTH_HEADER)
    if status == 200:
        check("/v1/models → DeepSeek-V4-Pro",
              '"id":"DeepSeek-V4-Pro"' in body,
              "missing model id")
        check("/v1/models → GLM-5.1",
              '"id":"GLM-5.1"' in body,
              "missing model id")
        check("/v1/models → object:list",
              '"object":"list"' in body,
              "wrong object type")
    else:
        check("/v1/models → 200", False, f"got {status}")

    # --- 8-12. chat completions — header injection ---
    req_body = '{"model":"DeepSeek-V4-Pro","messages":[{"role":"user","content":"hello"}]}'
    status, echo_body = http_post(
        f"{gateway_url}/v1/chat/completions",
        req_body,
        headers={
            "Content-Type": "application/json",
            **AUTH_HEADER,
        },
    )

    if status == 200:
        # apikey injected
        check("chat/completions → apikey injected",
              bool(re.search(r'"apikey"\s*:\s*"test-api-key"', echo_body)),
              "header not found")

        # Authorization replaced with upstream credentials
        check("chat/completions → Authorization replaced",
              bool(re.search(r'"Authorization"\s*:\s*"ACCESSCODE test-access-code"', echo_body)),
              "header not found")

        # Client's FAKE_OPENAI_KEY stripped (must not leak to upstream)
        leaked = re.search(r'"Authorization"\s*:\s*"Bearer test-client-key"', echo_body)
        check("chat/completions → client auth stripped",
              not leaked,
              "client auth leaked to upstream" if leaked else "")

        # EXTRA_HEADERS injected
        check("chat/completions → extra headers injected",
              bool(re.search(r'"X-Department"\s*:\s*"ai-test"', echo_body)),
              "header not found")

        # body preserved (openai) / transformed (inhouse)
        if upstream_mode == "inhouse":
            check("chat/completions → messages → contextMessage",
                  '"contextMessage":' in echo_body,
                  "contextMessage not found")
            check("chat/completions → messages stripped",
                  '"messages":' not in echo_body,
                  "original messages key leaked")
        else:
            check("chat/completions → body preserved",
                  '"messages":' in echo_body,
                  "body missing")
    else:
        check("chat/completions → 200", False, f"got {status}")

    # --- 13. Content-Type validation: non-JSON rejected ---
    status, _ = http_post(
        f"{gateway_url}/v1/chat/completions",
        "not json",
        headers={"Content-Type": "text/plain", **AUTH_HEADER},
    )
    check("POST with text/plain → 415", status == 415, f"got {status}")

    # --- 14. Content-Type with charset is accepted ---
    status, _ = http_post(
        f"{gateway_url}/v1/chat/completions",
        '{"test":true}',
        headers={"Content-Type": "application/json; charset=utf-8", **AUTH_HEADER},
    )
    check("POST with json+charset → 200", status == 200, f"got {status}")

    # --- 15. SSE response: content="" + tool_calls → content:null ---
    # Only applies in openai mode (response_transform deactivates for inhouse).
    if upstream_mode != "inhouse":
        sse_body = json.dumps({
            "model": "test",
            "messages": [{"role": "user", "content": "weather?"}],
            "stream": True,
        })
        status, raw_sse = http_post_stream(
            f"{gateway_url}/v1/chat/completions",
            sse_body,
            headers={"Content-Type": "application/json", **AUTH_HEADER},
        )
        if status == 200:
            events = parse_sse_events(raw_sse)
            if len(events) >= 2:
                chunk1 = events[0]
                delta1 = (chunk1.get("choices", [{}])[0] or {}).get("delta", {})
                has_tool_calls = "tool_calls" in delta1
                content_is_null = delta1.get("content") is None
                check("SSE → content:null when tool_calls present",
                      has_tool_calls and content_is_null,
                      f"content={delta1.get('content')!r} tool_calls={'yes' if has_tool_calls else 'no'}")

                chunk2 = events[1]
                delta2 = (chunk2.get("choices", [{}])[0] or {}).get("delta", {})
                check("SSE → regular content unchanged",
                      delta2.get("content") == "The weather in Shenyang is sunny.",
                      f"content={delta2.get('content')!r}")
            else:
                check("SSE → got SSE events", False, f"only {len(events)} events parsed")
        else:
            check("SSE → 200", False, f"got {status}")

    # --- 16-20. in-house mode: body transformation ---
    if upstream_mode == "inhouse":
        req_body = '{"model":"test","messages":[{"role":"user","content":"hi"}],"max_tokens":100,"top_p":0.9}'
        status, echo_body = http_post(
            f"{gateway_url}/v1/chat/completions",
            req_body,
            headers={"Content-Type": "application/json", **AUTH_HEADER},
        )
        if status == 200:
            check("inhouse → max_tokens → maxTokens",
                  '"maxTokens":' in echo_body,
                  "maxTokens not found")
            check("inhouse → top_p → topP",
                  '"topP":' in echo_body,
                  "topP not found")
            check("inhouse → model unchanged",
                  '"model":' in echo_body,
                  "model missing")
            check("inhouse → modelCode equals model",
                  '"modelCode":' in echo_body,
                  "modelCode not found")
            check("inhouse → question fixed value",
                  '"question":' in echo_body,
                  "question not found")
        else:
            check("inhouse → 200", False, f"got {status}")

    # --- upstream error code detection (openai mode only) ---
    if upstream_mode != "inhouse":
        # A1010 code → body cleared so client can retry
        status, body = http_post(
            f"{gateway_url}/v1/chat/completions",
            '{"model":"test","messages":[{"role":"user","content":"hi"}]}',
            headers={
                "Content-Type": "application/json",
                **AUTH_HEADER,
                "X-Mock-Code": "A1010",
            },
        )
        check("code=A1010 → body cleared",
              status == 200 and body.strip() == "",
              f"status={status} len={len(body)} body={body[:100]!r}")

        # Non-A1010 code → body preserved with code field
        status, body = http_post(
            f"{gateway_url}/v1/chat/completions",
            '{"model":"test","messages":[{"role":"user","content":"hi"}]}',
            headers={
                "Content-Type": "application/json",
                **AUTH_HEADER,
                "X-Mock-Code": "OTHER",
            },
        )
        check("code=OTHER → body preserved",
              status == 200 and '"code"' in body and "OTHER" in body,
              f"status={status} body={body[:100]!r}")

        # No code → normal response preserved
        status, body = http_post(
            f"{gateway_url}/v1/chat/completions",
            '{"model":"test","messages":[{"role":"user","content":"hi"}]}',
            headers={"Content-Type": "application/json", **AUTH_HEADER},
        )
        check("no code → body preserved",
              status == 200 and '"echo"' in body,
              f"status={status} body={body[:100]!r}")
    else:
        # inhouse mode: A1010 code should NOT be cleared
        status, body = http_post(
            f"{gateway_url}/v1/chat/completions",
            '{"model":"test","messages":[{"role":"user","content":"hi"}]}',
            headers={
                "Content-Type": "application/json",
                **AUTH_HEADER,
                "X-Mock-Code": "A1010",
            },
        )
        check("inhouse code=A1010 → body NOT cleared",
              status == 200 and '"code"' in body and "A1010" in body,
              f"status={status} body={body[:100]!r}")


def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <gateway-url>", file=sys.stderr)
        sys.exit(2)

    gateway_url = sys.argv[1].rstrip("/")

    print("\n=== Running tests ===")
    run_tests(gateway_url)
    print()
    print(f"Tests: {pass_count + fail_count} | Passed: {pass_count} | Failed: {fail_count}")

    if fail_count > 0:
        sys.exit(1)


if __name__ == "__main__":
    main()
