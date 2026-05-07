#!/usr/bin/env bash
# test.sh — integration tests for llm-intra-gw
#
# Starts a mock upstream API, launches the gateway via docker-compose pointed
# at the mock, runs test cases (delegated to test_cases.py), then tears everything
# down.
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

MOCK_PID=""
EXIT_CODE=0

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
export UPSTREAM_API_KEY="${UPSTREAM_API_KEY:-test-api-key}"
export PERSONAL_ACCESS_CODE="${PERSONAL_ACCESS_CODE:-test-access-code}"
export EXTRA_HEADERS="${EXTRA_HEADERS:-{\"X-Department\":\"ai-test\"}}"
export STRIP_REQUEST_PATH="${STRIP_REQUEST_PATH:-true}"
export FAKE_OPENAI_KEY="${FAKE_OPENAI_KEY:-test-client-key}"
export UPSTREAM_MODE="${UPSTREAM_MODE:-}"
export RATE_LIMIT_REQUESTS="${RATE_LIMIT_REQUESTS:-}"
export RATE_LIMIT_BODY_MB="${RATE_LIMIT_BODY_MB:-}"

echo "  UPSTREAM_BASE_URL=${UPSTREAM_BASE_URL}"
echo "  UPSTREAM_API_KEY=${UPSTREAM_API_KEY}"
echo "  PERSONAL_ACCESS_CODE=${PERSONAL_ACCESS_CODE}"
echo "  EXTRA_HEADERS=${EXTRA_HEADERS}"
echo "  STRIP_REQUEST_PATH=${STRIP_REQUEST_PATH}"
echo "  FAKE_OPENAI_KEY=${FAKE_OPENAI_KEY}"
echo "  UPSTREAM_MODE=${UPSTREAM_MODE:-openai}"
echo "  RATE_LIMIT_REQUESTS=${RATE_LIMIT_REQUESTS:-off}"
echo "  RATE_LIMIT_BODY_MB=${RATE_LIMIT_BODY_MB:-off}"

docker compose --project-directory "$PROJECT_DIR" up -d --build --wait 2>&1 | sed 's/^/  /'

# Double-check gateway is reachable
if ! wait_for "${GATEWAY_URL}/health" 15; then
    echo "FATAL: gateway did not start"
    docker compose --project-directory "$PROJECT_DIR" logs --tail 30
    exit 1
fi
echo "Gateway is up."

# ---------------------------------------------------------------------------
# run test cases (Python)
# ---------------------------------------------------------------------------

if [ -n "${RATE_LIMIT_REQUESTS:-}" ]; then
    python3 "$SCRIPT_DIR/test_cases.py" "$GATEWAY_URL" --ratelimit-only || EXIT_CODE=$?
else
    python3 "$SCRIPT_DIR/test_cases.py" "$GATEWAY_URL" || EXIT_CODE=$?
fi

exit $EXIT_CODE
