#!/usr/bin/env bash
# _send_impl.sh — shared implementation for send_*.sh scripts.
# Expects REQUEST_BODY to be defined by the calling script.
set -euo pipefail

GATEWAY_URL="${1:-http://localhost:8080}"
FAKE_OPENAI_KEY="${2:-}"
CONTAINER="${CONTAINER_NAME:-llm-intra-gw}"

GATEWAY_URL="${GATEWAY_URL%/}"

# ── Send ──────────────────────────────────────────────────────

AUTH_ARG=()
if [ -n "$FAKE_OPENAI_KEY" ]; then
  AUTH_ARG=(-H "Authorization: Bearer ${FAKE_OPENAI_KEY}")
fi

RESPONSE=$(curl -s -w '\n%{http_code}' -X POST "${GATEWAY_URL}/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  "${AUTH_ARG[@]}" \
  -d "$REQUEST_BODY")

HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | sed '$d')

# ── Display ────────────────────────────────────────────────────

section() {
  printf '\n══ %s ══\n' "$1"
}

section "REQUEST (client → gateway)"
echo "POST ${GATEWAY_URL}/v1/chat/completions"
echo "Content-Type: application/json"
[ -n "$FAKE_OPENAI_KEY" ] && echo "Authorization: Bearer ${FAKE_OPENAI_KEY}"
echo ""
echo "$REQUEST_BODY" | jq .

section "RESPONSE (gateway → client)"
echo "HTTP ${HTTP_CODE}"
echo ""
echo "$BODY" | jq . 2>/dev/null || echo "$BODY"

# ── TRACE ──────────────────────────────────────────────────────

TRACE_RAW=$(docker logs "$CONTAINER" --tail 200 2>&1 \
  | grep '\[TRACE\]' \
  || true)

section "GATEWAY TRACE LOGS (what the gateway saw/sent/received)"

if [ -z "$TRACE_RAW" ]; then
  echo "(no TRACE logs — is the gateway container \"$CONTAINER\" running with TRACE=1?)"
  exit 1
fi

echo "$TRACE_RAW" | python3 "$(dirname "$0")/format_trace.py"
