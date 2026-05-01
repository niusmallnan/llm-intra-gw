#!/usr/bin/env bash
# send_toolcall.sh — send a Tool Calls chat completions request to the gateway
set -euo pipefail

REQUEST_BODY=$(
  jq -n --arg model "${MODEL_ID:-DeepSeek-V4-Pro}" '{
    model: $model,
    messages: [
      { role: "user", content: "What is the weather like in Shenyang today?" }
    ],
    tools: [
      {
        type: "function",
        function: {
          name: "get_current_weather",
          description: "Get the current weather in a given location",
          parameters: {
            type: "object",
            properties: {
              location: { type: "string", description: "The city and state, e.g. Shenyang, Liaoning" },
              unit: { type: "string", enum: ["celsius", "fahrenheit"] }
            },
            required: ["location"]
          }
        }
      }
    ]
  }'
)

source "$(dirname "$0")/_send_impl.sh" "$@"
