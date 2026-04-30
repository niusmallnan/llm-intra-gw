# AGENTS.md — LLM Intra Gateway

OpenResty (nginx + LuaJIT) API gateway that proxies OpenAI-compatible requests to an enterprise LLM API, injecting custom auth headers.

## Architecture

```
request → nginx.conf /v1/ location
           → access_by_lua_block: lua/auth.lua (IP whitelist), lua/upstream.lua (Content-Type validation)
           → rewrite_by_lua_block: lua/upstream.lua (resolve upstream, inject headers)
           → proxy_pass (chunked, unbuffered)

request → nginx.conf /v1/models location
           → access_by_lua_block: lua/auth.lua (IP whitelist)
           → content_by_lua_block: lua/models.lua (return curated model list)
```

- `lua/auth.lua` — IP whitelist check via `IP_WHITELIST` env var (comma-separated IPs/CIDRs). Empty = allow all.
- `lua/upstream.lua` — Content-Type validation (only `application/json` accepted), builds upstream URL from `UPSTREAM_BASE_URL` (strips request URI by default; set `STRIP_REQUEST_PATH=false` to append it), injects `apikey` and `Authorization: ACCESSCODE <PERSONAL_ACCESS_CODE>` headers, strips the client's original `Authorization`.
- `lua/models.lua` — returns a curated subset of models (`DeepSeek-v4-Pro`, `GLM-5.1`). Edit the `MODELS` table to add/remove entries.
- `conf/nginx.conf` — declares all env vars via `env` directive (required for `os.getenv()` in Lua) and defines `lua_package_path`.

## Commands

```bash
make build          # docker build -t llm-intra-gw:dev .
make run            # build + run foreground (needs env vars set in shell)
make up             # docker compose up -d
make logs           # docker logs -f llm-intra-gw
make health         # curl :8080/health
make test           # smoke test against a running gateway (health + 404)
make clean          # docker compose down + image rm
```

`make test` starts a mock upstream API, launches the gateway via docker-compose pointed at the mock, runs integration tests (health, models, chat completions header injection, Content-Type validation, auth stripping), then tears everything down. It is self-contained — no pre-running gateway needed. The test script lives at `scripts/test.sh` and the mock upstream at `scripts/mock_api.py`.

## Gotchas

### nginx `env` directive is required
Environment variables must be declared in `conf/nginx.conf` under the `env` block (one `env VARNAME;` per variable). If you add a new env var consumed by Lua, you must add it there — `os.getenv()` in Lua won't see vars not declared.

### Resolver: 127.0.0.11 default
Uses Docker's embedded DNS by default. Override with `RESOLVER` env var when running outside Docker (e.g., set to `8.8.8.8`). The entrypoint script sed-substitutes it at container start.

### Streaming support toggle
Streaming (`stream: true`) is disabled by default. Set `ENABLE_STREAMING=true` to enable it — the entrypoint script adjusts `proxy_read_timeout` (3600s) and adds `gzip off`. The `proxy_buffering off` directive is always set. The gateway itself doesn't inspect request bodies; streaming is a client/upstream concern — the toggle only tunes nginx for long-lived SSE connections.

### No test framework
There are no unit tests, linters, or typecheckers for the Lua code. `make test` is just a curl smoke test against a running instance.

### Makefile requires env vars in shell
`make run` reads env vars from the shell (`$${VAR_NAME}` syntax). Set `UPSTREAM_BASE_URL`, `APIKEY`, and `PERSONAL_ACCESS_CODE` before running.
