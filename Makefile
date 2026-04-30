# Makefile — LLM Intra Gateway

.PHONY: build run stop test health logs clean

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
		-e APIKEY="$${APIKEY}" \
		-e PERSONAL_ACCESS_CODE="$${PERSONAL_ACCESS_CODE}" \
		-e IP_WHITELIST="$${IP_WHITELIST:-}" \
		-e EXTRA_HEADERS="$${EXTRA_HEADERS:-}" \
		-e RESOLVER="$${RESOLVER:-}" \
		$(IMAGE):$(TAG)

# ---- Docker Compose ----
up:
	docker compose up -d

down:
	docker compose down

# ---- Health check ----
health:
	curl -s http://localhost:$(PORT)/health | jq .

# ---- Quick smoke test with a dummy upstream ----
test:
	@echo ">>> Health check ..."
	@curl -sf http://localhost:$(PORT)/health || (echo "FAIL: health check" && exit 1)
	@echo "OK"
	@echo ">>> Unknown path should return 404 ..."
	@test "$$(curl -s -o /dev/null -w '%{http_code}' http://localhost:$(PORT)/unknown)" = "404" \
		|| (echo "FAIL: expected 404" && exit 1)
	@echo "OK"

# ---- Logs ----
logs:
	docker logs -f llm-intra-gw

# ---- Clean ----
clean:
	docker compose down -v --rmi local 2>/dev/null || true
	docker rmi $(IMAGE):$(TAG) 2>/dev/null || true
