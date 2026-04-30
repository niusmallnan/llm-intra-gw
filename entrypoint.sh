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
# Validate required environment variables
# ------------------------------------------------------------------
fail() {
    echo "ERROR: $1" >&2
    exit 1
}

[ -n "$UPSTREAM_BASE_URL" ]     || fail "UPSTREAM_BASE_URL is required"
[ -n "$APIKEY" ]                || fail "APIKEY is required (get it from your internal API Platform)"
[ -n "$PERSONAL_ACCESS_CODE" ]  || fail "PERSONAL_ACCESS_CODE is required (your personal token from the LLM platform)"

echo ">> Configuration valid — upstream: $UPSTREAM_BASE_URL"
echo ">> APIKEY: [set]"
echo ">> PERSONAL_ACCESS_CODE: [set]"

# ------------------------------------------------------------------
# Start OpenResty
# ------------------------------------------------------------------
exec "$@"
