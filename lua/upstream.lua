-- upstream.lua — upstream resolver and header injection module
--
-- Reads UPSTREAM_BASE_URL, UPSTREAM_API_KEY, PERSONAL_ACCESS_CODE, and EXTRA_HEADERS
-- from the environment at init time.
--
-- Injects two enterprise-required headers into every proxied request:
--   1. apikey         — upstream key from the internal API Platform
--   2. Authorization  — composed as "ACCESSCODE <PERSONAL_ACCESS_CODE>" where
--                       "ACCESSCODE" is a fixed prefix and PERSONAL_ACCESS_CODE
--                       is a personal token obtained from the LLM platform.
--
-- Provides:
--   resolve()        — build the full upstream URL for the current request
--   inject_headers() — attach enterprise-required headers to the proxied request
--   transform_body() — convert request body fields for in-house API (UPSTREAM_MODE=inhouse)
--   apply_stream()   — inject stream:true into the request body when STREAM is enabled

local cjson = require "cjson"

local _M = {}

-- ---------------------------------------------------------------------------
-- Configuration (loaded once at module load time)
-- ---------------------------------------------------------------------------

local upstream_base_url = os.getenv("UPSTREAM_BASE_URL")

local upstream_api_key   = os.getenv("UPSTREAM_API_KEY")
local personal_access_code = os.getenv("PERSONAL_ACCESS_CODE")

-- When true (default), proxy to UPSTREAM_BASE_URL directly.
-- When false, append the original request URI.
local strip_request_path   = os.getenv("STRIP_REQUEST_PATH") ~= "false"

-- Optional additional headers
local extra_headers_raw = os.getenv("EXTRA_HEADERS")

-- Parse EXTRA_HEADERS JSON once
local extra_headers = {}
if extra_headers_raw and extra_headers_raw ~= "" then
    local ok, decoded = pcall(cjson.decode, extra_headers_raw)
    if ok and type(decoded) == "table" then
        extra_headers = decoded
    else
        ngx.log(ngx.WARN, "failed to parse EXTRA_HEADERS JSON: ", extra_headers_raw)
    end
end

-- Remove trailing slash from base URL for consistent concatenation
if upstream_base_url then
    upstream_base_url = upstream_base_url:gsub("/+$", "")
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- Extract the host:port portion from UPSTREAM_BASE_URL.
-- Used to set the Host header for the proxied request.
function _M.get_upstream_host()
    if not upstream_base_url then
        return nil
    end
    -- Strip scheme (https:// or http://) and path
    local host = upstream_base_url:match("^https?://([^/]+)")
    return host
end

-- Build the full upstream target URL for the current request.
-- Returns nil and sets ngx.status on error.
function _M.resolve()
    if not upstream_base_url then
        ngx.status = 500
        ngx.header["Content-Type"] = "application/json"
        ngx.say(cjson.encode({
            error = {
                message = "UPSTREAM_BASE_URL is not configured",
                type = "server_error"
            }
        }))
        ngx.exit(500)
        return nil
    end

    if strip_request_path then
        ngx.req.set_uri("/")
    end
    return upstream_base_url .. ngx.var.uri
end

-- Inject enterprise-required headers into the outgoing proxy request.
function _M.inject_headers()
    -- 1. Strip the agent's own Authorization header (e.g. OpenAI API key)
    --    to prevent it from leaking to the internal API.
    ngx.req.clear_header("Authorization")

    -- 2. Inject the upstream API key (header: apikey).
    if upstream_api_key and upstream_api_key ~= "" then
        ngx.req.set_header("apikey", upstream_api_key)
    end

    -- 3. Compose and inject the enterprise Authorization header.
    --    Format: "ACCESSCODE <PERSONAL_ACCESS_CODE>"
    if personal_access_code and personal_access_code ~= "" then
        ngx.req.set_header("Authorization", "ACCESSCODE " .. personal_access_code)
    end

    -- 4. Apply any additional user-configured headers.
    --    apikey and Authorization are skipped here — they are handled above.
    for k, v in pairs(extra_headers) do
        local key_lower = k:lower()
        if key_lower ~= "apikey" and key_lower ~= "authorization" then
            ngx.req.set_header(k, tostring(v))
        end
    end
end

-- Reject requests with non-JSON Content-Type.
-- Requests without a Content-Type header (e.g. GET) are allowed through.
function _M.validate_content_type()
    local ct = ngx.var.http_content_type
    if not ct or ct == "" then
        return true
    end
    local ct_lower = ct:lower()
    if ct_lower:find("application/json", 1, true) == 1 then
        return true
    end
    ngx.status = 415
    ngx.header["Content-Type"] = "application/json"
    ngx.say(cjson.encode({
        error = {
            message = "unsupported content-type: " .. ct .. ". only application/json is accepted",
            type = "invalid_request_error"
        }
    }))
    ngx.exit(415)
    return false
end

-- Transform the request body for the in-house API.
-- Rules:
--   1. Root-level key "messages" → "contextMessage"
--   2. Root-level keys in snake_case → camelCase (e.g. "max_tokens" → "maxTokens")
--   3. Append "modelCode" with the value of the "model" field
--   4. Append "question" with a fixed space value (backend workaround)
--   4. All non-matching keys and all values are kept as-is.
-- Only applies when UPSTREAM_MODE is set to "inhouse".
function _M.transform_body()
    local mode = os.getenv("UPSTREAM_MODE")
    if not mode or mode == "" then
        return
    end
    if mode:lower() ~= "inhouse" then
        return
    end

    ngx.req.read_body()
    local body = ngx.req.get_body_data()
    if not body or body == "" then
        return
    end

    local ok, data = pcall(cjson.decode, body)
    if not ok or type(data) ~= "table" then
        return
    end

    local result = {}
    for k, v in pairs(data) do
        local new_key
        if k == "messages" then
            new_key = "contextMessage"
        else
            new_key = k:gsub("_(%l)", function(c) return c:upper() end)
        end
        result[new_key] = v
    end

    result["modelCode"] = result["model"]
    result["question"] = " "

    ngx.req.set_body_data(cjson.encode(result))
end

-- Inject or override "stream" in the request body based on the STREAM env var:
--   "auto"  (default) — do nothing; client controls streaming
--   "true"  — force "stream": true  (enable SSE streaming)
--   "false" — force "stream": false (disable SSE streaming)
function _M.apply_stream()
    local val = os.getenv("STREAM")
    if not val or val == "" then
        val = "auto"
    end
    val = val:lower()

    if val == "auto" then
        return
    end

    local stream_val
    if val == "true" or val == "1" or val == "on" or val == "yes" then
        stream_val = true
    elseif val == "false" or val == "0" or val == "off" or val == "no" then
        stream_val = false
    else
        return  -- unrecognised value, treat as auto
    end

    ngx.req.read_body()
    local body = ngx.req.get_body_data()
    if not body or body == "" then
        return
    end

    local ok, data = pcall(cjson.decode, body)
    if not ok or type(data) ~= "table" then
        return
    end

    data["stream"] = stream_val
    ngx.req.set_body_data(cjson.encode(data))
end

-- Validate that required configuration is present.
function _M.validate()
    if not upstream_base_url then
        return false, "UPSTREAM_BASE_URL is required but not set"
    end
    if not upstream_api_key or upstream_api_key == "" then
        return false, "UPSTREAM_API_KEY is required but not set"
    end
    if not personal_access_code or personal_access_code == "" then
        return false, "PERSONAL_ACCESS_CODE is required but not set"
    end
    return true, nil
end

return _M
