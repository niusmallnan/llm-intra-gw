#!/usr/bin/env bash
# test.sh — integration tests for llm-intra-gw
#
# Starts a mock upstream API, launches the gateway via docker-compose pointed
# at the mock, runs all test cases, then tears everything down.
#
# Usage:
#   make test                     # full integration test (builds if needed)
#   MOCK_ONLY=1 bash scripts/test.sh   # start mock API only (manual testing)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
MOCK_PORT="${MOCK_PORT:-18080}"
GATEWAY_PORT="${GATEWAY_PORT:-8080}"
GATEWAY_URL="http://localhost:${GATEWAY_PORT}"

PASS=0
FAIL=0
MOCK_PID=""

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

cleanup() {
    if [ -n "${MOCK_PID:-}" ] && kill -0 "$MOCK_PID" 2>/dev/null; then
        echo "[cleanup] stopping mock API (pid $MOCK_PID)..."
        kill "$MOCK_PID" 2>/dev/null || true
        wait "$MOCK_PID" 2>/dev/null || true
    fi
    if [ "${MOCK_ONLY:-}" != "1" ]; then
        echo "[cleanup] docker compose down..."
        docker compose --project-directory "$PROJECT_DIR" down --timeout 5 2>/dev/null || true
    fi
}

check() {
    local label="$1" rc="$2" desc="$3"
    printf "  %-55s " "${label}"
    if [ "${rc}" -eq 0 ]; then
        echo "PASS"
        PASS=$((PASS + 1))
    else
        echo "FAIL (${desc})"
        FAIL=$((FAIL + 1))
    fi
}

wait_for() {
    local url="$1" max="${2:-30}"
    local i=0
    while [ $i -lt "$max" ]; do
        if curl -sf "$url" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
        i=$((i + 1))
    done
    return 1
}

# ---------------------------------------------------------------------------
# start mock API
# ---------------------------------------------------------------------------

trap cleanup EXIT

echo "=== Starting mock API (port ${MOCK_PORT}) ==="
python3 "$SCRIPT_DIR/mock_api.py" &
MOCK_PID=$!
if ! wait_for "http://localhost:${MOCK_PORT}/health" 10; then
    echo "FATAL: mock API did not start"
    exit 1
fi
echo "Mock API is up."

if [ "${MOCK_ONLY:-}" = "1" ]; then
    echo "[mock_only] mock API running on :${MOCK_PORT} — Ctrl-C to stop"
    wait "$MOCK_PID"
    exit 0
fi

# ---------------------------------------------------------------------------
# start gateway (pointed at mock)
# ---------------------------------------------------------------------------

echo "=== Starting gateway (docker compose) ==="

# host.docker.internal resolves from inside the container to the host on
# Docker Desktop (macOS/Windows). On Linux, override with MOCK_HOST env var.
MOCK_HOST="${MOCK_HOST:-host.docker.internal}"
UPSTREAM="http://${MOCK_HOST}:${MOCK_PORT}"

export UPSTREAM_BASE_URL="${UPSTREAM_BASE_URL:-${UPSTREAM}}"
export APIKEY="${APIKEY:-test-api-key}"
export PERSONAL_ACCESS_CODE="${PERSONAL_ACCESS_CODE:-test-access-code}"
export EXTRA_HEADERS="${EXTRA_HEADERS:-{\"X-Department\":\"ai-test\"}}"
export STRIP_REQUEST_PATH="${STRIP_REQUEST_PATH:-true}"

echo "  UPSTREAM_BASE_URL=${UPSTREAM_BASE_URL}"
echo "  APIKEY=${APIKEY}"
echo "  PERSONAL_ACCESS_CODE=${PERSONAL_ACCESS_CODE}"
echo "  EXTRA_HEADERS=${EXTRA_HEADERS}"
echo "  STRIP_REQUEST_PATH=${STRIP_REQUEST_PATH}"

docker compose --project-directory "$PROJECT_DIR" up -d --build --wait 2>&1 | sed 's/^/  /'

# Double-check gateway is reachable
if ! wait_for "${GATEWAY_URL}/health" 15; then
    echo "FATAL: gateway did not start"
    docker compose --project-directory "$PROJECT_DIR" logs --tail 30
    exit 1
fi
echo "Gateway is up."

# ---------------------------------------------------------------------------
# test cases
# ---------------------------------------------------------------------------

echo
echo "=== Running tests ==="

# --- 1. health check ---
curl -sf "${GATEWAY_URL}/health" >/dev/null 2>&1 && rc=0 || rc=$?
check "GET /health → 200" "$rc" "health check failed"

# --- 2. unknown path returns 404 ---
STATUS=$(curl -s -o /dev/null -w '%{http_code}' "${GATEWAY_URL}/unknown")
test "${STATUS}" = "404" && rc=0 || rc=1
check "GET /unknown → 404" "$rc" "got ${STATUS}"

# --- 3. /v1/models returns curated list ---
MODELS=$(curl -sf "${GATEWAY_URL}/v1/models") && rc=0 || rc=$?
if [ "$rc" -eq 0 ]; then
    echo "${MODELS}" | grep -q '"id":"DeepSeek-v4-Pro"' && rc=0 || rc=1
    check "/v1/models → DeepSeek-v4-Pro" "$rc" "missing model id"

    echo "${MODELS}" | grep -q '"id":"GLM-5.1"' && rc=0 || rc=1
    check "/v1/models → GLM-5.1" "$rc" "missing model id"

    echo "${MODELS}" | grep -q '"object":"list"' && rc=0 || rc=1
    check "/v1/models → object:list" "$rc" "wrong object type"
else
    check "/v1/models → 200" "$rc" "request failed"
fi

# --- 4. chat completions — header injection ---
BODY='{"model":"DeepSeek-v4-Pro","messages":[{"role":"user","content":"hello"}]}'
ECHO=$(curl -sf -X POST "${GATEWAY_URL}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer client-fake-key" \
    -d "$BODY") && rc=0 || rc=$?
if [ "$rc" -eq 0 ]; then
    # apikey injected
    echo "${ECHO}" | grep -qE '"apikey"\s*:\s*"test-api-key"' && rc=0 || rc=1
    check "chat/completions → apikey injected" "$rc" "header not found"

    # Authorization replaced
    echo "${ECHO}" | grep -qE '"Authorization"\s*:\s*"ACCESSCODE test-access-code"' && rc=0 || rc=1
    check "chat/completions → Authorization replaced" "$rc" "header not found"

    # Client's original Authorization stripped
    if echo "${ECHO}" | grep -qE '"Authorization"\s*:\s*"Bearer client-fake-key"'; then
        check "chat/completions → client auth stripped" "1" "client auth leaked to upstream"
    else
        check "chat/completions → client auth stripped" "0" ""
    fi

    # EXTRA_HEADERS injected
    echo "${ECHO}" | grep -qE '"X-Department"\s*:\s*"ai-test"' && rc=0 || rc=1
    check "chat/completions → extra headers injected" "$rc" "header not found"

    # body preserved
    echo "${ECHO}" | grep -q '"messages":' && rc=0 || rc=1
    check "chat/completions → body preserved" "$rc" "body missing"
else
    check "chat/completions → 200" "$rc" "request failed"
fi

# --- 5. Content-Type validation: non-JSON rejected ---
CT_STATUS=$(curl -s -o /dev/null -w '%{http_code}' \
    -X POST "${GATEWAY_URL}/v1/chat/completions" \
    -H "Content-Type: text/plain" \
    -d "not json")
test "${CT_STATUS}" = "415" && rc=0 || rc=1
check "POST with text/plain → 415" "$rc" "got ${CT_STATUS}"

# --- 6. Content-Type with charset is accepted ---
CT_CHARSET=$(curl -sf -X POST "${GATEWAY_URL}/v1/chat/completions" \
    -H "Content-Type: application/json; charset=utf-8" \
    -d '{"test":true}') && rc=0 || rc=$?
check "POST with json+charset → 200" "$rc" "charset variant rejected"

# --- 7. GET without Content-Type allowed ---
curl -sf "${GATEWAY_URL}/v1/models" >/dev/null 2>&1 && rc=0 || rc=$?
check "GET without Content-Type → 200" "$rc" "GET blocked"

# ---------------------------------------------------------------------------
# summary
# ---------------------------------------------------------------------------

echo
echo "Tests: $((PASS + FAIL)) | Passed: ${PASS} | Failed: ${FAIL}"
[ "${FAIL}" -eq 0 ] || exit 1
