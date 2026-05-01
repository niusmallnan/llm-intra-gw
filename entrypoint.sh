#!/bin/sh
# entrypoint.sh — startup validation and resolver override

set -e

# ------------------------------------------------------------------
# Resolver override
# ------------------------------------------------------------------
# If the user set RESOLVER, substitute the default 127.0.0.11 in nginx.conf.
if [ -n "$RESOLVER" ]; then
    echo ">> Setting DNS resolver to $RESOLVER"
    sed -i "s/resolver 127\.0\.0\.11/resolver $RESOLVER/" \
        /usr/local/openresty/nginx/conf/nginx.conf
fi

# ------------------------------------------------------------------
# Streaming support (optional, default: disabled)
# ------------------------------------------------------------------
if [ "${ENABLE_STREAMING:-}" = "true" ]; then
    echo ">> Streaming support enabled"
    sed -i "s/# @proxy_read_timeout@/proxy_read_timeout 3600s;/" \
        /usr/local/openresty/nginx/conf/nginx.conf
    sed -i "s/# @streaming_settings@/gzip off;/" \
        /usr/local/openresty/nginx/conf/nginx.conf
else
    echo ">> Streaming support disabled (use ENABLE_STREAMING=true to enable)"
    sed -i "s/# @proxy_read_timeout@/proxy_read_timeout 60s;/" \
        /usr/local/openresty/nginx/conf/nginx.conf
    sed -i "/# @streaming_settings@/d" \
        /usr/local/openresty/nginx/conf/nginx.conf
fi

# ------------------------------------------------------------------
# Validate required environment variables
# ------------------------------------------------------------------
fail() {
    echo "ERROR: $1" >&2
    exit 1
}

[ -n "$UPSTREAM_BASE_URL" ]     || fail "UPSTREAM_BASE_URL is required"
[ -n "$UPSTREAM_API_KEY" ]  || fail "UPSTREAM_API_KEY is required (get it from your internal API Platform)"
[ -n "$PERSONAL_ACCESS_CODE" ]  || fail "PERSONAL_ACCESS_CODE is required (your personal token from the LLM platform)"

echo ">> Configuration valid — upstream: $UPSTREAM_BASE_URL"
echo ">> UPSTREAM_API_KEY: [set]"
echo ">> PERSONAL_ACCESS_CODE: [set]"

# ------------------------------------------------------------------
# Start OpenResty
# ------------------------------------------------------------------
exec "$@"
