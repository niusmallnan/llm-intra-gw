-- response_transform.lua — upstream response body transformation for OpenAI compatibility
--
-- When UPSTREAM_MODE is "openai" (or unset), transforms streaming SSE chunks:
--   In any chat.completion.chunk event, if a choice's delta has a tool_calls
--   key AND content is "" (empty string), change content to null.
--
-- This fixes compatibility with clients that reject empty-string content
-- when tool calls are present.
--
-- Also detects upstream error responses (200 with JSON "code" field).  When
-- code equals "A1010" (rate limit), the response body is cleared so the
-- client can retry.

local cjson = require "cjson"

local _M = {}

-- Check whether the SSE transform should be active for this response.
local function active()
    local mode = os.getenv("UPSTREAM_MODE")
    if mode and mode ~= "" and mode:lower() ~= "openai" then
        return false
    end
    return true
end

-- Determine if the response is SSE (streaming).
local function is_sse()
    local ct = ngx.header["Content-Type"]
    return ct and ct:find("text/event-stream", 1, true) ~= nil
end

-- Transform a single delta object in-place. Returns true if modified.
local function transform_delta(delta)
    if not delta or type(delta) ~= "table" then
        return false
    end
    local tool_calls = delta.tool_calls
    if not tool_calls or type(tool_calls) ~= "table" then
        return false
    end
    if delta.content ~= "" then
        return false
    end
    delta.content = cjson.null
    return true
end

-- Transform a parsed JSON object (chat.completion.chunk). Returns new JSON
-- string if modified, or nil if unchanged.
local function transform_chunk(data)
    if type(data) ~= "table" then
        return nil
    end
    if data.object ~= "chat.completion.chunk" then
        return nil
    end

    local choices = data.choices
    if not choices or type(choices) ~= "table" then
        return nil
    end

    local modified = false
    for _, choice in ipairs(choices) do
        if choice and type(choice) == "table" then
            if transform_delta(choice.delta) then
                modified = true
            end
        end
    end

    if not modified then
        return nil
    end

    return cjson.encode(data)
end

-- Process buffered SSE data, returning (output, remaining_buffer).
-- Splits on \n\n boundaries, transforms data: events, and passes
-- everything else through unchanged.
local function drain_sse(buf)
    local output = ""
    local pos

    while true do
        pos = buf:find("\n\n", 1, true)
        if not pos then
            break
        end

        -- Extract one complete event (including the trailing \n\n)
        local event = buf:sub(1, pos + 1)
        buf = buf:sub(pos + 2)

        -- Match: data: <json>\n\n
        local json_str = event:match("^data:%s*(.+)\n\n$")
        if not json_str then
            output = output .. event
        else
            local ok, data = pcall(cjson.decode, json_str)
            if not ok then
                output = output .. event
            else
                local transformed = transform_chunk(data)
                if transformed then
                    output = output .. "data: " .. transformed .. "\n\n"
                else
                    output = output .. event
                end
            end
        end
    end

    return output, buf
end

-- Called from header_filter_by_lua_block.  For SSE responses we must
-- clear Content-Length because the body_filter may modify the body size
-- (content:"" → content:null or A1010 body clearing).
function _M.header_filter()
    if is_sse() then
        ngx.header["Content-Length"] = nil
    end
end

-- Called from body_filter_by_lua_block for every response chunk.
-- For JSON and SSE responses: accumulates raw chunks, suppresses output
-- until EOF, then inspects for upstream error codes, applies SSE
-- transform if needed, and outputs (or clears body on A1010).
-- Non-JSON/non-SSE responses pass through unchanged.
function _M.body_filter(chunk, eof)
    local ct = ngx.header["Content-Type"] or ""
    local is_sse_resp = ct:find("text/event-stream", 1, true) ~= nil
    local is_json = ct:find("application/json", 1, true) ~= nil

    -- Only buffer and inspect JSON / SSE responses.
    if not is_sse_resp and not is_json then
        return
    end

    -- Accumulate raw chunks; suppress output until EOF.
    if chunk then
        ngx.ctx.response_buf = (ngx.ctx.response_buf or "") .. chunk
    end
    ngx.arg[1] = ""

    if not eof then
        return
    end

    local body = ngx.ctx.response_buf or ""
    ngx.ctx.response_buf = nil
    if body == "" then
        return
    end

    -- Check for upstream error codes on 200 responses.
    if ngx.status == 200 then
        if is_json then
            local ok, data = pcall(cjson.decode, body)
            if ok and type(data) == "table" and data.code ~= nil then
                local safe = body
                pcall(function() safe = body:sub(1, 1000) end)
                ngx.log(ngx.WARN,
                    "[UPSTREAM-ERROR] status=200, code=", tostring(data.code),
                    ", body: ", safe)
                if tostring(data.code) == "A1010" then
                    return  -- body was cleared (ngx.arg[1] remains "")
                end
            end
        else  -- SSE
            for json_str in body:gmatch("data:%s*(.-)\n") do
                local ok, data = pcall(cjson.decode, json_str)
                if ok and type(data) == "table" and data.code ~= nil then
                    local safe = json_str
                    pcall(function() safe = json_str:sub(1, 1000) end)
                    ngx.log(ngx.WARN,
                        "[UPSTREAM-ERROR] status=200, SSE chunk, code=", tostring(data.code),
                        ", body: ", safe)
                    if tostring(data.code) == "A1010" then
                        return  -- body cleared for retry
                    end
                end
            end
        end
    end

    -- Apply SSE content:"" → null transform (openai mode only).
    if is_sse_resp and active() then
        local output, _ = drain_sse(body)
        ngx.arg[1] = output
    else
        ngx.arg[1] = body
    end
end

return _M
