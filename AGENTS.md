# AGENTS.md — LLM Intra Gateway

OpenResty (nginx + LuaJIT) API gateway that proxies OpenAI-compatible requests to an enterprise LLM API, injecting custom auth headers.

## Architecture

```
request → nginx.conf /v1/ location
           → access_by_lua_block: lua/auth.lua (IP whitelist), lua/upstream.lua (Content-Type validation)
           → rewrite_by_lua_block: lua/upstream.lua (resolve upstream, inject headers)
           → proxy_pass (buffered, inspects body before sending)

request → nginx.conf /v1/models location
           → access_by_lua_block: lua/auth.lua (IP whitelist)
           → content_by_lua_block: lua/models.lua (return curated model list)
```

- `lua/auth.lua` — IP whitelist check via `IP_WHITELIST` env var (comma-separated IPs/CIDRs). Empty = allow all. Client key validation via `FAKE_OPENAI_KEY` — when set, the client must present `Authorization: Bearer <FAKE_OPENAI_KEY>` or receive a `401`.
- `lua/upstream.lua` — Content-Type validation (only `application/json` accepted), builds upstream URL from `UPSTREAM_BASE_URL` (strips request URI by default; set `STRIP_REQUEST_PATH=false` to append it), injects `apikey` (from `UPSTREAM_API_KEY`, optional) and `Authorization: ACCESSCODE <PERSONAL_ACCESS_CODE>` headers, strips the client's original `Authorization`. When `UPSTREAM_MODE=inhouse` **(experimental)**, transforms the request body: renames `messages` → `contextMessage` and converts root-level keys from `snake_case` to `camelCase` (e.g. `max_tokens` → `maxTokens`). When `STREAM=true`, injects `"stream": true` into the request body.
- `lua/response_transform.lua` — response body post-processing.  Buffers JSON/SSE response bodies (openai mode only) and inspects them before the client receives data.  Applies SSE `content:""` → `null` transform when `delta.tool_calls` present.  Detects upstream error responses (200 with `"code"` field in body) and logs a warning.  When `code == "A1010"` (rate limit), clears the response body so the client sees an empty 200 and can retry.
- `lua/models.lua` — returns a curated subset of models (`DeepSeek-V4-Pro`, `GLM-5.1`). Edit the `MODELS` table to add/remove entries.
- `lua/rate_limit.lua` — API throttling via `RATE_LIMIT_REQUESTS` (max requests/minute) and `RATE_LIMIT_BODY_MB` (max total body MB/minute). Uses `lua_shared_dict gateway` for cross-worker counters with a fixed-window (per-minute) algorithm. When a limit is exceeded, returns `429 Too Many Requests` with an OpenAI-compatible error body. Rate-limit response headers (`x-ratelimit-limit-requests`, `x-ratelimit-remaining-requests`, `x-ratelimit-reset-requests`, `x-ratelimit-limit-mb`, `x-ratelimit-remaining-mb`) are included for transparency. The check runs in the rewrite phase so the upstream is never contacted for throttled requests. Set either env var to `0` or leave empty to disable the corresponding limit.
- `lua/trace.lua` — request/response tracing for debugging. When `TRACE` env var is set (`1`/`true`/`on`/`yes`), logs to error log: client request (headers + body), modified upstream request (injected headers + target URL + potentially transformed body), and upstream response (status + headers + full body).  Receives raw response chunks (before `response_transform` suppresses them).
- `conf/nginx.conf` — declares all env vars via `env` directive (required for `os.getenv()` in Lua) and defines `lua_package_path`.

## Commands

```bash
make build          # docker build -t llm-intra-gw:dev .
make run            # build + run foreground (needs env vars set in shell)
make up             # docker compose up -d
make logs           # docker logs -f llm-intra-gw
make health         # curl :8080/health
make test           # smoke test against a running gateway (health + 404)
make test-ratelimit       # same as test but with RATE_LIMIT_REQUESTS=3 (rate limit tests only)
make test-ratelimit-body  # same as test but with RATE_LIMIT_BODY_MB=0.001 (body size tests only)
make send           # send a sample request + display TRACE logs (gateway must be running with TRACE=1)
make clean          # docker compose down + image rm
```

`make test` starts a mock upstream API, launches the gateway via docker-compose pointed at the mock, runs integration tests (health, models, chat completions header injection, Content-Type validation, auth stripping, SSE content:null transform, upstream error code detection and A1010 body clearing), then tears everything down. It is self-contained — no pre-running gateway needed. Orchestration (mock + gateway lifecycle) lives in `scripts/test.sh`; the test cases themselves are in `scripts/test_cases.py`, and the mock upstream at `scripts/mock_api.py`.

`make send` sends a sample chat completions request to a running gateway and displays: the client request, the client response, and the gateway's TRACE logs (what it received from the client, what it sent upstream, and what the upstream returned). The gateway must be running with `TRACE=1`. The script is at `scripts/send_request.sh`.

## Gotchas

### nginx `env` directive is required
Environment variables must be declared in `conf/nginx.conf` under the `env` block (one `env VARNAME;` per variable). If you add a new env var consumed by Lua, you must add it there — `os.getenv()` in Lua won't see vars not declared.

### Resolver: 127.0.0.11 default
Uses Docker's embedded DNS by default. Override with `RESOLVER` env var when running outside Docker (e.g., set to `8.8.8.8`). The entrypoint script sed-substitutes it at container start.

### Streaming support toggle
`STREAM` env var (default: `auto`). Three modes:
- `auto` — gateway does not modify the `stream` field; client decides. Proxy timeout is 3600s to accommodate SSE streams.
- `true` — gateway forces `"stream": true` in the request body, sets `proxy_read_timeout 3600s`, adds `gzip off`.
- `false` — gateway forces `"stream": false`, `proxy_read_timeout 60s`.
Responses are fully buffered (`proxy_buffering on`, the nginx default) so the body can be inspected before the client receives any data.  SSE streams are delivered all at once after the upstream completes.

### No test framework
There are no unit tests, linters, or typecheckers for the Lua code. `make test` is just a curl smoke test against a running instance.

### nginx phase ordering: rewrite before access
`rewrite_by_lua_block` runs in the rewrite phase, which occurs **before** the access phase (`access_by_lua_block`). If you inject headers that overwrite the original `Authorization` header (e.g. `upstream.inject_headers()`), any client auth check in `access_by_lua_block` will see the **replaced** header, not the original. The FAKE_OPENAI_KEY check must therefore run in `rewrite_by_lua_block` **before** `inject_headers()`.

### Makefile requires env vars in shell
`make run` reads env vars from the shell (`$${VAR_NAME}` syntax). Set `UPSTREAM_BASE_URL`, `APIKEY`, and `PERSONAL_ACCESS_CODE` before running.
