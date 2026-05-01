-- trace.lua — request/response tracing for debugging
--
-- When TRACE env var is set (to "1", "true", "on", or "yes"), the gateway logs:
--   1. Original client request  (headers + body)
--   2. Gateway-modified request  (headers sent to upstream + target URL)
--   3. Upstream response         (status + headers + body)
--
-- All trace output goes to the nginx error log at WARN level.

local _M = {}

function _M.enabled()
    local val = os.getenv("TRACE")
    if not val then
        return false
    end
    val = val:lower()
    return val == "1" or val == "true" or val == "on" or val == "yes"
end

local function read_body()
    ngx.req.read_body()
    local body = ngx.req.get_body_data()
    if not body then
        local file = ngx.req.get_body_file()
        if file then
            local f = io.open(file, "r")
            if f then
                body = f:read("*all")
                f:close()
            end
        end
    end
    return body
end

-- Log the incoming client request (original headers + body).
-- Must be called *before* inject_headers() strips/modifies request headers.
function _M.log_original_request()
    if not _M.enabled() then return end

    local body = read_body()

    ngx.log(ngx.WARN, "[TRACE] ═══ CLIENT REQUEST ═══")
    ngx.log(ngx.WARN, "[TRACE]   method: ", ngx.req.get_method())
    ngx.log(ngx.WARN, "[TRACE]   uri:    ", ngx.var.request_uri)

    ngx.log(ngx.WARN, "[TRACE]   headers:")
    local h = ngx.req.get_headers(100)
    for k, v in pairs(h) do
        ngx.log(ngx.WARN, "[TRACE]     ", k, ": ", v)
    end

    if body then
        -- Replace newlines so the body stays on a single log line
        -- (multi-line bodies produce continuation lines without [TRACE])
        body = string.gsub(body, "\n", " ")
        ngx.log(ngx.WARN, "[TRACE]   body: ", body)
    else
        ngx.log(ngx.WARN, "[TRACE]   body: (empty)")
    end
end

-- Log the gateway-modified request headers and body (after injection, before proxy_pass).
-- Must be called *after* inject_headers() and *after* transform_body() (if applicable).
function _M.log_modified_request()
    if not _M.enabled() then return end

    ngx.log(ngx.WARN, "[TRACE] ═══ UPSTREAM REQUEST ═══")
    ngx.log(ngx.WARN, "[TRACE]   url: ", ngx.var.upstream_target)

    ngx.log(ngx.WARN, "[TRACE]   headers:")
    local h = ngx.req.get_headers(100)
    for k, v in pairs(h) do
        ngx.log(ngx.WARN, "[TRACE]     ", k, ": ", v)
    end

    local body = read_body()
    if body then
        body = string.gsub(body, "\n", " ")
        ngx.log(ngx.WARN, "[TRACE]   body: ", body)
    else
        ngx.log(ngx.WARN, "[TRACE]   body: (empty)")
    end
end

-- Log the upstream response status line and headers.
-- Called from header_filter_by_lua_block.
function _M.log_response_headers()
    if not _M.enabled() then return end

    ngx.log(ngx.WARN, "[TRACE] ═══ UPSTREAM RESPONSE ═══")
    ngx.log(ngx.WARN, "[TRACE]   status: ", ngx.status)

    ngx.log(ngx.WARN, "[TRACE]   headers:")
    local h = ngx.resp.get_headers()
    for k, v in pairs(h) do
        ngx.log(ngx.WARN, "[TRACE]     ", k, ": ", v)
    end
end

-- Accumulate response body chunks and log the full body at EOF.
-- Called from body_filter_by_lua_block.  Does NOT modify ngx.arg[1],
-- so the chunk passes through to the client unaltered.
function _M.body_filter(chunk, eof)
    if not _M.enabled() then return end

    if chunk then
        ngx.ctx.trace_buf = (ngx.ctx.trace_buf or "") .. chunk
    end

    if eof and ngx.ctx.trace_buf then
        local buf = string.gsub(ngx.ctx.trace_buf, "\n", " ")
        ngx.log(ngx.WARN, "[TRACE]   body: ", buf)
        ngx.ctx.trace_buf = nil
    end
end

return _M
