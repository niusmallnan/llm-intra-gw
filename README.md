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

The gateway injects **two mandatory headers** into every proxied request:

| Header | Source | Description |
|---|---|---|
| `apikey` | `APIKEY` env var | A shared key obtained from your internal **API Platform**. |
| `Authorization` | Fixed prefix `ACCESSCODE` + `PERSONAL_ACCESS_CODE` | Composed as `ACCESSCODE <PERSONAL_ACCESS_CODE>`. `ACCESSCODE` is a fixed prefix; `PERSONAL_ACCESS_CODE` is a personal token from your **LLM platform**. |

The agent's original `Authorization` header (e.g., an OpenAI API key) is
**stripped** before the request leaves the gateway — it never reaches your
internal API.

## Quick Start

```bash
# 1. Build the image
docker build -t llm-intra-gw .

# 2. Run with your credentials
docker run --rm -p 8080:8080 \
  -e UPSTREAM_BASE_URL=https://llm-api.internal.example.com \
  -e APIKEY="your-shared-api-key" \
  -e PERSONAL_ACCESS_CODE="your-personal-token" \
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
| `APIKEY` | ✅ | — | Shared API key from your internal API Platform. Injected as the `apikey` header. |
| `PERSONAL_ACCESS_CODE` | ✅ | — | Personal token from your internal LLM platform. Composed as `Authorization: ACCESSCODE <PERSONAL_ACCESS_CODE>` (the `ACCESSCODE` prefix is hard-coded). |
| `IP_WHITELIST` | ❌ | *(allow all)* | Comma-separated list of IPs or CIDR ranges allowed to access the gateway (e.g. `10.0.0.0/8,172.16.1.5`). |
| `EXTRA_HEADERS` | ❌ | `{}` | Additional headers to inject, as a JSON object (e.g. `{"X-Department":"ai","X-Tenant":"default"}`). |
| `RESOLVER` | ❌ | `127.0.0.11` | DNS resolver IP. Override if not running inside Docker. |
| `GATEWAY_PORT` | ❌ | `8080` | Port the gateway listens on inside the container. |

## Endpoints

| Path | Method | Description |
|---|---|---|
| `/health` | `GET` | Health check. Returns `{"status":"ok"}`. |
| `/v1/chat/completions` | `POST` | Chat completions (non-streaming). |
| `/v1/models` | `GET` | List available models. |
| `/v1/*` | `*` | All other OpenAI-compatible endpoints are proxied transparently. |

> **Note:** Streaming (`stream: true`) is not yet supported.  It is on the
> roadmap for a future release.

## How It Works

1. **Access phase** — If `IP_WHITELIST` is configured, the client IP is
   checked against the list. Non-matching requests receive a `403`.

2. **Rewrite phase** — Three things happen:
   - The agent's `Authorization` header is stripped.
   - `apikey` and `Authorization` (`ACCESSCODE <PERSONAL_ACCESS_CODE>`) headers are injected.
   - Any `EXTRA_HEADERS` are applied (except `apikey` and `Authorization`,
     which are reserved).

3. **Proxy** — The request is forwarded to `UPSTREAM_BASE_URL` with the
   original path and request body preserved.  Since the internal API already
   speaks the OpenAI protocol, no body transformation is needed.

4. **Response** — The upstream response is returned to the client as-is
   (proxied transparently).

## Deploying

### With Docker Compose

Create a `.env` file:

```bash
UPSTREAM_BASE_URL=https://llm-api.internal.example.com
APIKEY=your-shared-api-key
PERSONAL_ACCESS_CODE=your-personal-token
IP_WHITELIST=10.0.0.0/8
EXTRA_HEADERS={"X-Department":"ai-platform"}
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
  APIKEY: "your-shared-api-key"
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
        - name: APIKEY
          valueFrom:
            secretKeyRef:
              name: gateway-secrets
              key: APIKEY
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
# Run a health check
make health

# Run quick smoke tests (requires the gateway to be running)
make test
```

## Development

```bash
# Build the image
make build

# Start with docker compose
make up

# View logs
make logs

# Stop and clean up
make clean
```

## License

MIT
