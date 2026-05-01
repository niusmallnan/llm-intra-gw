# Makefile — LLM Intra Gateway

.PHONY: build run stop test health logs clean send

IMAGE ?= llm-intra-gw
TAG   ?= dev
PORT  ?= 8080

# ---- Build ----
build:
	docker build -t $(IMAGE):$(TAG) .

# ---- Run (foreground, Ctrl-C to stop) ----
run: build
	docker run --rm -it \
		-p $(PORT):8080 \
		-e UPSTREAM_BASE_URL="$${UPSTREAM_BASE_URL}" \
		-e UPSTREAM_API_KEY="$${UPSTREAM_API_KEY}" \
		-e PERSONAL_ACCESS_CODE="$${PERSONAL_ACCESS_CODE}" \
		-e IP_WHITELIST="$${IP_WHITELIST:-}" \
		-e EXTRA_HEADERS="$${EXTRA_HEADERS:-}" \
		-e RESOLVER="$${RESOLVER:-}" \
		-e FAKE_OPENAI_KEY="$${FAKE_OPENAI_KEY:-}" \
		$(IMAGE):$(TAG)

# ---- Docker Compose ----
up:
	docker compose up -d

down:
	docker compose down

# ---- Health check ----
health:
	curl -s http://localhost:$(PORT)/health | jq .

# ---- Integration tests (mock upstream + gateway + test cases) ----
test: build
	@bash scripts/test.sh

# ---- Sample request for troubleshooting (gateway must be running, TRACE=1) ----
send:
	@GATEWAY_URL=$${GATEWAY_URL:-http://localhost:8080} \
	 FAKE_OPENAI_KEY=$${FAKE_OPENAI_KEY:-} \
	 MODEL_ID=$${MODEL_ID:-DeepSeek-v4-Pro} \
	 CONTAINER_NAME=$${CONTAINER_NAME:-llm-intra-gw} \
	 bash scripts/send_request.sh "$$GATEWAY_URL" "$$FAKE_OPENAI_KEY"

# ---- Logs ----
logs:
	docker logs -f llm-intra-gw

# ---- Clean ----
clean:
	docker compose down -v --rmi local 2>/dev/null || true
	docker rmi $(IMAGE):$(TAG) 2>/dev/null || true
