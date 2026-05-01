-- auth.lua — IP whitelist and client key access control module
--
-- Reads IP_WHITELIST and FAKE_OPENAI_KEY from the environment.
-- If IP_WHITELIST is empty or unset, all IPs are allowed.
-- If FAKE_OPENAI_KEY is empty or unset, no client key check is performed.
-- When FAKE_OPENAI_KEY is set, the client must present a matching
-- Authorization: Bearer <FAKE_OPENAI_KEY> header.

local bit = require "bit"

local _M = {}

-- Convert an IPv4 address string to a 32-bit integer.
local function ip_to_int(ip)
    local a, b, c, d = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    if not a then
        return nil
    end
    return bit.bor(bit.lshift(tonumber(a), 24),
                   bit.lshift(tonumber(b), 16),
                   bit.lshift(tonumber(c), 8),
                   tonumber(d))
end

-- Parse a CIDR string like "192.168.1.0/24" into (net_int, mask_int).
local function parse_cidr(cidr)
    local ip_str, bits_str = cidr:match("^(.+)/(%d+)$")
    if not ip_str then
        -- Plain IP (no prefix)
        local ip_int = ip_to_int(cidr)
        if not ip_int then
            return nil
        end
        return ip_int, 0xFFFFFFFF
    end
    local ip_int = ip_to_int(ip_str)
    if not ip_int then
        return nil
    end
    local bits = tonumber(bits_str)
    if bits < 0 or bits > 32 then
        return nil
    end
    local mask = bits == 0 and 0 or bit.band(bit.lshift(0xFFFFFFFF, 32 - bits), 0xFFFFFFFF)
    return ip_int, mask
end

-- Check whether a client IP matches any entry in the whitelist.
function _M.check(client_ip)
    local whitelist_str = os.getenv("IP_WHITELIST")
    if not whitelist_str or whitelist_str == "" then
        return true -- no whitelist configured, allow all
    end

    local client_int = ip_to_int(client_ip)
    if not client_int then
        ngx.log(ngx.WARN, "failed to parse client IP: ", client_ip)
        return false
    end

    for entry in whitelist_str:gmatch("[^,%s]+") do
        local net_int, mask = parse_cidr(entry)
        if net_int and bit.band(client_int, mask) == bit.band(net_int, mask) then
            return true
        end
    end

    return false
end

-- Check whether the client presents a valid FAKE_OPENAI_KEY.
-- Returns true if no key is configured, or if the client's Authorization
-- header matches "Bearer <FAKE_OPENAI_KEY>".
function _M.check_client_key()
    local fake_openai_key = os.getenv("FAKE_OPENAI_KEY")
    if not fake_openai_key or fake_openai_key == "" then
        return true  -- no key configured, allow all
    end

    local headers = ngx.req.get_headers()
    local auth_header = headers["Authorization"] or headers["authorization"]
    local expected = "Bearer " .. fake_openai_key

    if auth_header == expected then
        return true
    end

    return false
end

return _M
