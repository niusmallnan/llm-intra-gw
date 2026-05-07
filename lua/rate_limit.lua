-- rate_limit.lua — API throttling via request count and body throughput limits
--
-- Uses lua_shared_dict "gateway" (10m) for cross-worker counters with a
-- fixed-window (per-minute) algorithm.  Keys auto-expire after 60s so a
-- fresh window always starts on the next minute boundary.
--
-- Configured via environment variables:
--   RATE_LIMIT_REQUESTS   — max requests per minute (0 = unlimited)
--   RATE_LIMIT_BODY_MB    — max total request body MB per minute (0 = unlimited)
--
-- Returns 429 Too Many Requests with an OpenAI-compatible error body when
-- a limit is exceeded.  The check runs in the rewrite phase so the upstream
-- is never contacted for throttled requests.

local cjson = require "cjson"

local _M = {}

-- Configuration (0 = no limit).  Both nil and "" env-var values are treated as 0.
local function env_int(name)
    local raw = os.getenv(name)
    if not raw or raw == "" then
        return 0
    end
    return tonumber(raw) or 0
end

local max_requests = env_int("RATE_LIMIT_REQUESTS")
local max_body_mb   = env_int("RATE_LIMIT_BODY_MB")

function _M.active()
    return max_requests > 0 or max_body_mb > 0
end

-- Return the current fixed-window key (epoch second / 60).
local function window_key(suffix)
    return "rl:" .. math.floor(ngx.time() / 60) .. ":" .. suffix
end

-- Check request-count limit.  Returns true or false, err_msg.
local function check_requests()
    if max_requests <= 0 then
        return true
    end

    local dict = ngx.shared.gateway
    if not dict then
        return true  -- no shared dict configured; skip silently
    end

    local key    = window_key("req")
    local used, _ = dict:incr(key, 1, 0, 60)

    local remaining = max_requests - used
    if remaining < 0 then
        remaining = 0
    end

    -- Set response headers for transparency (OpenAI-like).
    ngx.header["x-ratelimit-limit-requests"]     = tostring(max_requests)
    ngx.header["x-ratelimit-remaining-requests"]  = tostring(remaining)
    ngx.header["x-ratelimit-reset-requests"]      = tostring(60 - (ngx.time() % 60) .. "s")

    if used > max_requests then
        ngx.log(ngx.WARN, "[RATE-LIMIT] request count exceeded: ",
            used, "/", max_requests, " requests/min",
            " (", tostring(remaining), " remaining)")
        return false, "request rate limit exceeded: " ..
            max_requests .. " requests per minute"
    end
    return true
end

-- Check body-throughput limit.  Returns true or false, err_msg.
local function check_body_size(body_len)
    if max_body_mb <= 0 or not body_len or body_len <= 0 then
        return true
    end

    local dict = ngx.shared.gateway
    if not dict then
        return true
    end

    local key      = window_key("body")
    local used, _  = dict:incr(key, body_len, 0, 60)

    local max_bytes   = max_body_mb * 1024 * 1024
    local remaining   = max_bytes - used
    if remaining < 0 then
        remaining = 0
    end

    ngx.header["x-ratelimit-limit-mb"]    = tostring(max_body_mb)
    ngx.header["x-ratelimit-remaining-mb"] = tostring(math.floor(remaining / 1024 / 1024 * 100 + 0.5) / 100)

    if used > max_bytes then
        ngx.log(ngx.WARN, "[RATE-LIMIT] body throughput exceeded: ",
            used, " bytes / ", max_bytes, " bytes limit (",
            remaining, " bytes remaining)")
        return false, "body throughput limit exceeded: " ..
            max_body_mb .. " MB per minute"
    end
    return true
end

--  Main entry point.  Call during rewrite/access phase before proxying.
--  body_len is the raw request body length in bytes (nil / 0 → skip body check).
--  Returns true if allowed; on denial calls ngx.exit(429) and does not return.
function _M.check(body_len)
    if not _M.active() then
        return true
    end

    local ok, err = check_requests()
    if not ok then
        ngx.status = 429
        ngx.header["Content-Type"] = "application/json"
        ngx.say(cjson.encode({
            error = {
                message = err,
                type    = "rate_limit_error",
                code    = "rate_limit_exceeded",
            }
        }))
        ngx.exit(429)
    end

    ok, err = check_body_size(body_len)
    if not ok then
        ngx.status = 429
        ngx.header["Content-Type"] = "application/json"
        ngx.say(cjson.encode({
            error = {
                message = err,
                type    = "rate_limit_error",
                code    = "rate_limit_exceeded",
            }
        }))
        ngx.exit(429)
    end

    return true
end

return _M
