#!/usr/bin/env bash
# send_request.sh — send a sample chat completions request to the gateway
set -euo pipefail

REQUEST_BODY=$(
  jq -n --arg model "${MODEL_ID:-DeepSeek-V4-Pro}" '{
    model: $model,
    messages: [
      { role: "developer", content: "You are a helpful assistant." },
      { role: "user", content: "Hello!" }
    ]
  }'
)

source "$(dirname "$0")/_send_impl.sh" "$@"
