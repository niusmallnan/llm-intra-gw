# LLM Intra Gateway

An [OpenResty](https://openresty.org/)-based gateway that proxies requests from
[OpenAI-compatible](https://platform.openai.com/docs/api-reference) clients to
an enterprise-internal LLM API, automatically injecting the authentication
headers your organization requires — headers that off-the-shelf AI agents and
SDKs cannot easily configure.

## Why

Most AI agent frameworks and SDKs speak the OpenAI API protocol.  Enterprise
LLM deployments, however, often require custom authentication headers that
these tools do not support.

**LLM Intra Gateway** sits between your agents and your internal API:

```
Agent (OpenAI SDK) ─── /v1/chat/completions ───▶ Gateway ─── + injected headers ───▶ Internal LLM API
     ◀── OpenAI JSON response ─────────────────── Gateway ◀── internal response ─────
```

- The agent sees a standard OpenAI endpoint.
- The internal API receives the proprietary headers it expects.
- No code changes needed on either side.

## How Authentication Works

The gateway performs two layers of authentication:

**Client → Gateway**: When `FAKE_OPENAI_KEY` is set, every client must include `Authorization: Bearer <FAKE_OPENAI_KEY>` in its request. This gives you a single API key to configure in all your agents and SDKs (set as the usual OpenAI API key).

**Gateway → Internal API**: After validating the client key, the gateway strips it and injects the proprietary headers your internal API expects:

| Header | Source | Description |
|---|---|---|
| `apikey` | `UPSTREAM_API_KEY` env var | A shared key obtained from your internal **API Platform**. |
| `Authorization` | Fixed prefix `ACCESSCODE` + `PERSONAL_ACCESS_CODE` | Composed as `ACCESSCODE <PERSONAL_ACCESS_CODE>`. `ACCESSCODE` is a fixed prefix; `PERSONAL_ACCESS_CODE` is a personal token from your **LLM platform**. |

The client's original `Authorization` header is **stripped** before the request leaves the gateway — it never reaches your internal API.

## Quick Start

```bash
# 1. Build the image
docker build -t llm-intra-gw .

# 2. Run with your credentials
docker run --rm -p 8080:8080 \
  -e UPSTREAM_BASE_URL=https://llm-api.internal.example.com \
  -e UPSTREAM_API_KEY="your-shared-api-key" \
  -e PERSONAL_ACCESS_CODE="your-personal-token" \
  -e FAKE_OPENAI_KEY="sk-your-fake-openai-key" \
  llm-intra-gw
```

Point your agent's `OPENAI_BASE_URL` (or equivalent) at `http://localhost:8080`
and it will work without any additional configuration.

## Configuration

All settings are passed as environment variables.  **No secrets are stored in
the image or the source code.**

| Variable | Required | Default | Description |
|---|---|---|---|
| `UPSTREAM_BASE_URL` | ✅ | — | Base URL of the internal LLM API (e.g. `https://llm-api.example.com`). |
| `UPSTREAM_API_KEY` | ✅ | — | Shared API key from your internal API Platform. Injected as the `apikey` header. |
| `PERSONAL_ACCESS_CODE` | ✅ | — | Personal token from your internal LLM platform. Composed as `Authorization: ACCESSCODE <PERSONAL_ACCESS_CODE>` (the `ACCESSCODE` prefix is hard-coded). |
| `IP_WHITELIST` | ❌ | *(allow all)* | Comma-separated list of IPs or CIDR ranges allowed to access the gateway (e.g. `10.0.0.0/8,172.16.1.5`). |
| `FAKE_OPENAI_KEY` | ❌ | *(no client auth)* | An API key that clients must present as `Authorization: Bearer <key>`. When set, requests without a matching key receive a `401`. When unset, no client-side authentication is required. |
| `EXTRA_HEADERS` | ❌ | `{}` | Additional headers to inject, as a JSON object (e.g. `{"X-Department":"ai","X-Tenant":"default"}`). |
| `RESOLVER` | ❌ | `127.0.0.11` | DNS resolver IP. Override if not running inside Docker. |
| `GATEWAY_PORT` | ❌ | `8080` | Port the gateway listens on inside the container. |
| `STREAM` | ❌ | `auto` | Streaming mode. `auto` — client decides (gateway does not touch the `stream` field). `true` — gateway forces `"stream": true`, sets `proxy_read_timeout 3600s`, disables `gzip`. `false` — gateway forces `"stream": false`. |
| `STRIP_REQUEST_PATH` | ❌ | `true` | When `true` (default), proxy requests directly to `UPSTREAM_BASE_URL`. When `false`, append the original request URI (e.g. `/v1/chat/completions`). |
| `TRACE` | ❌ | *(off)* | Enable request/response tracing to the error log for debugging. Set to `1`, `true`, `on`, or `yes` to log: client request (headers + body), gateway-modified upstream request (injected headers + target URL), and upstream response (status + headers + full body). |
| `UPSTREAM_MODE` | ❌ | `openai` | Upstream API mode. `openai` (default) proxies requests as-is. `inhouse` transforms the request body: renames `messages` to `contextMessage` and converts root-level keys from `snake_case` to `camelCase` (e.g. `max_tokens` → `maxTokens`). |

## Endpoints

| Path | Method | Description |
|---|---|---|
| `/health` | `GET` | Health check. Returns `{"status":"ok"}`. |
| `/v1/chat/completions` | `POST` | Chat completions (streaming controlled by `STREAM` env var and client's `stream` field). |
| `/v1/models` | `GET` | Curated model list (`DeepSeek-V4-Pro`, `GLM-5.1`). |
| `/v1/*` | `*` | All other OpenAI-compatible endpoints are proxied transparently. |

> **Streaming support:** `STREAM` defaults to `auto` — the gateway does not modify
> the `stream` field; the client controls streaming behaviour.  Set `STREAM=true`
> to force stream on (or `STREAM=false` to force it off).

## How It Works

1. **Access phase** — IP whitelist and content-type validation:
   - If `IP_WHITELIST` is configured, the client IP is checked against the
     list. Non-matching requests receive a `403`.
   - If a `Content-Type` header is present, it must be `application/json`
     (`application/json; charset=utf-8` is accepted). Anything else receives
     a `415`.

2. **Rewrite phase** — Client authentication, body transformation, and header injection:
   - If `FAKE_OPENAI_KEY` is configured, the client's `Authorization: Bearer <key>`
     header is validated **first** (before any header modification). Mismatched or
     missing keys receive a `401`.
   - If `UPSTREAM_MODE=inhouse`, the request body is transformed: root-level
     `snake_case` keys are converted to `camelCase` (e.g. `max_tokens` →
     `maxTokens`), and the `messages` field is renamed to `contextMessage`.
   - If `STREAM` is `true` or `false`, `"stream"` is set accordingly in the request body.
   - The client's original `Authorization` header is stripped.
   - `apikey` and `Authorization` (`ACCESSCODE <PERSONAL_ACCESS_CODE>`) headers are injected.
   - Any `EXTRA_HEADERS` are applied (except `apikey` and `Authorization`,
     which are reserved).

3. **Proxy** — The request is forwarded to `UPSTREAM_BASE_URL` with the
   original path and request body preserved.  Since the internal API already
   speaks the OpenAI protocol, no body transformation is needed.
   TLS certificate verification is disabled (`proxy_ssl_verify off`) for
   HTTPS upstreams — the gateway trusts the internal network.

4. **Response** — The upstream response is returned to the client as-is
   (proxied transparently).

5. **Trace (debugging)** — When `TRACE` is enabled, the gateway logs three
   stages to the nginx error log:
   - Original client request (headers + body)
   - Gateway-modified upstream request (injected headers + target URL)
   - Upstream response (status + all headers + full body)

## Deploying

### With Docker Compose

Create a `.env` file:

```bash
UPSTREAM_BASE_URL=https://llm-api.internal.example.com
UPSTREAM_API_KEY=your-shared-api-key
PERSONAL_ACCESS_CODE=your-personal-token
FAKE_OPENAI_KEY=sk-your-fake-openai-key
IP_WHITELIST=10.0.0.0/8
EXTRA_HEADERS={"X-Department":"ai-platform"}
# STREAM=true             # optional, force streaming on
# TRACE=1                # optional, log request/response details for debugging
```

Then run:

```bash
docker compose up -d
```

### With Kubernetes

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: gateway-secrets
stringData:
  UPSTREAM_API_KEY: "your-shared-api-key"
  PERSONAL_ACCESS_CODE: "your-personal-token"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: llm-intra-gw
spec:
  replicas: 2
  selector:
    matchLabels:
      app: llm-intra-gw
  template:
    metadata:
      labels:
        app: llm-intra-gw
    spec:
      containers:
      - name: gateway
        image: llm-intra-gw:latest
        ports:
        - containerPort: 8080
        env:
        - name: UPSTREAM_BASE_URL
          value: "https://llm-api.internal.example.com"
        - name: UPSTREAM_API_KEY
          valueFrom:
            secretKeyRef:
              name: gateway-secrets
              key: UPSTREAM_API_KEY
        - name: PERSONAL_ACCESS_CODE
          valueFrom:
            secretKeyRef:
              name: gateway-secrets
              key: PERSONAL_ACCESS_CODE
        - name: IP_WHITELIST
          value: "10.0.0.0/8"
        readinessProbe:
          httpGet:
            path: /health
            port: 8080
```

## Testing Locally

```bash
# Run the full integration test suite (mock upstream + gateway + test cases)
make test

# Run tests with in-house API mode (UPSTREAM_MODE=inhouse, body transformation)
make test-inhouse

# Run just a health check against a running instance
make health
```

`make test` is self-contained — it starts a mock internal LLM API, launches the
gateway via docker compose pointed at the mock, runs all tests (health, models,
chat completions header injection, Content-Type validation, auth stripping), and
cleans up afterwards.

## Development

```bash
# Build the image
make build

# Start with docker compose
make up

# View logs
make logs

# Send a sample request and display TRACE debug output
# (gateway must be running with TRACE=1)
make send
# optionally override env vars:
#   GATEWAY_URL=https://my-gateway.example.com FAKE_OPENAI_KEY=sk-test make send

# Stop and clean up
make clean
```

## License

MIT
