# Dockerfile — LLM Intra Gateway
#
# Build:
#   docker build -t llm-intra-gw .
#
# Run (minimal):
#   docker run --rm -p 8080:8080 \
#     -e UPSTREAM_BASE_URL=https://internal-llm.company.com \
#     -e AUTH_HEADER_NAME=X-Enterprise-Auth \
#     -e AUTH_HEADER_VALUE="$TOKEN" \
#     llm-intra-gw

FROM openresty/openresty:alpine

LABEL org.opencontainers.image.title="llm-intra-gw"
LABEL org.opencontainers.image.description="LLM Intra Gateway — OpenAI-compatible proxy for enterprise LLM APIs"

# Copy application code
COPY conf/nginx.conf /usr/local/openresty/nginx/conf/nginx.conf
COPY lua/             /app/lua/

# Copy entrypoint script
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 8080

STOPSIGNAL SIGQUIT

ENTRYPOINT ["/entrypoint.sh"]
CMD ["/usr/local/openresty/bin/openresty", "-g", "daemon off;"]
