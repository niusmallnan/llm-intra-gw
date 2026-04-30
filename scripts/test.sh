#!/usr/bin/env bash
# test.sh — smoke tests for llm-intra-gw
# Expects gateway running on GATEWAY_URL (default: http://localhost:8080).

set -euo pipefail

GATEWAY_URL="${GATEWAY_URL:-http://localhost:8080}"
PASS=0
FAIL=0

check() {
    local label="$1" status="$2" desc="$3"
    printf ">>> %-50s " "${label}"
    if [ "${status}" -eq 0 ]; then
        echo "PASS"
        PASS=$((PASS + 1))
    else
        echo "FAIL (${desc})"
        FAIL=$((FAIL + 1))
    fi
}

# --- health check ---
HEALTH=$(curl -sf "${GATEWAY_URL}/health" 2>&1) && rc=0 || rc=$?
check "GET /health (200)" "${rc}" "health endpoint not reachable"

# --- unknown path returns 404 ---
STATUS=$(curl -s -o /dev/null -w '%{http_code}' "${GATEWAY_URL}/unknown")
test "${STATUS}" = "404" && rc=0 || rc=1
check "GET /unknown (404)" "${rc}" "expected 404, got ${STATUS}"

# --- /v1/models returns curated model list ---
MODELS_RESP=$(curl -sf "${GATEWAY_URL}/v1/models" 2>&1) && rc=0 || rc=$?
if [ "${rc}" -eq 0 ]; then
    echo "${MODELS_RESP}" | grep -q '"id":"DeepSeek-v4-Pro"'  2>/dev/null && rc=0 || rc=1
    check "/v1/models → DeepSeek-v4-Pro" "${rc}" "missing model id"

    echo "${MODELS_RESP}" | grep -q '"id":"GLM-5.1"'         2>/dev/null && rc=0 || rc=1
    check "/v1/models → GLM-5.1"      "${rc}" "missing model id"

    echo "${MODELS_RESP}" | grep -q '"object":"list"'         2>/dev/null && rc=0 || rc=1
    check "/v1/models → object:list"  "${rc}" "wrong object type"
else
    echo ">>> /v1/models request failed (${MODELS_RESP})"
    FAIL=$((FAIL + 3))
fi

# --- summary ---
echo
echo "Tests: $((PASS + FAIL)) | Passed: ${PASS} | Failed: ${FAIL}"
if [ "${FAIL}" -gt 0 ]; then
    exit 1
fi
