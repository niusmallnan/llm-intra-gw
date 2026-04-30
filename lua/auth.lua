-- auth.lua — IP whitelist access control module
--
-- Reads IP_WHITELIST from the environment (comma-separated IPs or CIDR ranges).
-- If the list is empty or unset, all traffic is allowed.
-- Otherwise, the client IP must match at least one entry.

local _M = {}

-- Convert an IPv4 address string to a 32-bit integer.
local function ip_to_int(ip)
    local a, b, c, d = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    if not a then
        return nil
    end
    return ((tonumber(a) * 256 + tonumber(b)) * 256 + tonumber(c)) * 256 + tonumber(d)
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
    local mask = bits == 0 and 0 or (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF
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
        if net_int and (client_int & mask) == (net_int & mask) then
            return true
        end
    end

    return false
end

return _M
