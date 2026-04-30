-- models.lua — curated model list for /v1/models
--
-- Returns the subset of models available through the internal LLM API.
-- Add or remove model IDs as the upstream API expands.
--
-- Default creation timestamp is per OpenAPI spec for deterministic responses.

local cjson = require "cjson"

local _M = {}

local MODELS = {
    "DeepSeek-v4-Pro",
    "GLM-5.1",
}

-- Arbitrary fixed timestamp (2026-01-01) for deterministic output.
local CREATED = 1767225600

function _M.list()
    local data = {}
    for _, id in ipairs(MODELS) do
        data[#data + 1] = {
            id      = id,
            object  = "model",
            created = CREATED,
            owned_by = "llm-intra-gw",
        }
    end
    ngx.header["Content-Type"] = "application/json"
    ngx.say(cjson.encode({
        object = "list",
        data   = data,
    }))
    ngx.exit(200)
end

return _M
