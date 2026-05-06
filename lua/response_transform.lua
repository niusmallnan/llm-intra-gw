-- response_transform.lua — upstream response body transformation for OpenAI compatibility
--
-- When UPSTREAM_MODE is "openai" (or unset), transforms streaming SSE chunks:
--   In any chat.completion.chunk event, if a choice's delta has a tool_calls
--   key AND content is "" (empty string), change content to null.
--
-- This fixes compatibility with clients that reject empty-string content
-- when tool calls are present.

local cjson = require "cjson"

local _M = {}

-- Check whether the module should be active for this response.
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
-- clear Content-Length before headers are sent because the body_filter
-- may modify the body size (e.g. content:"" → content:null).
function _M.header_filter()
    if not active() then
        return
    end
    if is_sse() then
        ngx.header["Content-Length"] = nil
    end
end

-- Called from body_filter_by_lua_block at EOF.  Checks whether a 200 response
-- body conforms to an OpenAI-compatible format and logs a warning when it does not.
-- Non-200 responses and SSE streams are skipped — the client or upstream handles
-- those error paths.
function _M.validate_response(chunk, eof)
    if ngx.status ~= 200 then
        return
    end

    -- Accumulate the full body across chunks.
    if chunk then
        ngx.ctx.validate_buf = (ngx.ctx.validate_buf or "") .. chunk
    end
    if not eof then
        return
    end

    local body = ngx.ctx.validate_buf
    ngx.ctx.validate_buf = nil
    if not body or body == "" then
        return
    end

    -- Truncate for safe logging (some upstream errors return huge HTML pages).
    local safe = body
    local truncate_ok = pcall(function()
        safe = body:sub(1, 1000)
    end)
    if not truncate_ok then
        safe = "(binary/non-string body)"
    end

    local ct = ngx.header["Content-Type"] or ""

    -- SSE streaming responses are validated chunk-by-chunk by the client.
    if ct:find("text/event-stream", 1, true) then
        return
    end

    if ct:find("application/json", 1, true) then
        local ok, data = pcall(cjson.decode, body)
        if not ok or type(data) ~= "table" then
            ngx.log(ngx.WARN,
                "[NON-STANDARD] status=200, Content-Type=", ct,
                ", unparseable JSON body: ", safe)
            return
        end
        -- All OpenAI responses carry an "object" field
        -- (chat.completion, chat.completion.chunk, list, embedding, …).
        if type(data.object) == "string" then
            return
        end
        ngx.log(ngx.WARN,
            "[NON-STANDARD] status=200, Content-Type=", ct,
            ", non-OpenAI JSON body: ", safe)
        return
    end

    -- Non-JSON, non-SSE Content-Type on a 200 response (e.g. HTML error page).
    ngx.log(ngx.WARN,
        "[NON-STANDARD] status=200, Content-Type=", ct,
        ", body: ", safe)
end

-- Called from body_filter_by_lua_block.  Buffers SSE chunks, transforms
-- chat.completion.chunk events, and forwards immediately.  Non-SSE
-- responses pass through unchanged.
function _M.body_filter(chunk, eof)
    if not active() then
        return
    end

    if not is_sse() then
        return
    end

    local buf = ngx.ctx.response_transform_buf or ""

    if chunk then
        buf = buf .. chunk
    end

    local output, remainder = drain_sse(buf)
    ngx.ctx.response_transform_buf = remainder

    if eof and #remainder > 0 then
        -- Flush any remaining data (e.g. a partial event, DONE, or trailing newlines)
        output = output .. remainder
        ngx.ctx.response_transform_buf = nil
    end

    ngx.arg[1] = output
end

return _M
