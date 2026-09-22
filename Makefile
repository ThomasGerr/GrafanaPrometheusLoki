# grafana-prometheus-loki — everyday operations
#
# Nothing here needs anything installed on your machine except Docker.

SHELL       := /bin/bash
# Local work always uses the dev file, the one that publishes ports.
# docker-compose.yml is the Dokploy/production stack and publishes none.
COMPOSE     := docker compose -f docker-compose.dev.yml
PY_IMAGE    := python:3.13-slim
PROM_IMAGE  := prom/prometheus:v3.13.2
AM_IMAGE    := prom/alertmanager:v0.34.0
ALLOY_IMAGE := grafana/alloy:v1.19.0
RENDER_IMAGE := grafana/grafana-image-renderer:v5.12.4

# Run a throwaway Python container with PyYAML, so the generator has no
# dependency on whatever Python happens to be on this machine.
PYRUN = docker run --rm -v "$(CURDIR):/w" -w /w $(PY_IMAGE) sh -c \
        "pip install --quiet --disable-pip-version-check pyyaml >/dev/null 2>&1 && $(1)"

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this help
	@echo "grafana-prometheus-loki"
	@echo
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "Typical flow:  edit clients.yml -> make generate -> make validate -> commit -> redeploy"

# ── Configuration ──────────────────────────────────────────────────────────

.PHONY: generate
generate: ## Rebuild every per-client config from clients.yml
	@$(call PYRUN,python scripts/generate.py)

.PHONY: validate
validate: ## Check every config file before you deploy a mistake
	@./scripts/validate.sh

# ── Running ────────────────────────────────────────────────────────────────

.PHONY: up
up: ## Start the whole stack locally
	@test -f .env || { echo "No .env — copy .env.example and fill it in first."; exit 1; }
	$(COMPOSE) up -d --build
	@echo
	@echo "  Grafana       http://localhost:3000"
	@echo "  Prometheus    http://localhost:9090"
	@echo "  Alertmanager  http://localhost:9093"

.PHONY: down
down: ## Stop the stack (data volumes are kept)
	$(COMPOSE) down

.PHONY: destroy
destroy: ## Stop the stack AND delete all stored metrics, logs and dashboards
	@read -p "This deletes all monitoring history. Type yes to continue: " a; [ "$$a" = yes ]
	$(COMPOSE) down -v

.PHONY: ps
ps: ## Show container status
	$(COMPOSE) ps

.PHONY: logs
logs: ## Follow logs (make logs S=prometheus for one service)
	$(COMPOSE) logs -f --tail=100 $(S)

.PHONY: reload
reload: ## Local stack: apply config edits without restarting Prometheus
	@docker exec em-prometheus wget -q --post-data='' -O- http://localhost:9090/-/reload \
	  && echo "prometheus reloaded"
	@$(COMPOSE) restart alertmanager && echo "alertmanager restarted"

# ── Grafana ────────────────────────────────────────────────────────────────

.PHONY: bootstrap
bootstrap: ## Create/update Grafana Orgs, logins, data sources and dashboards
	@python3 scripts/bootstrap_grafana.py

.PHONY: bootstrap-server
bootstrap-server: ## Same, run ON the monitoring host over the internal network
	@# Grafana publishes no port and sits behind Cloudflare, so neither
	@# localhost nor the public URL works from the server itself. Join the
	@# stack's own network instead and address the container directly. The
	@# script is stdlib-only, so a bare Python image is enough.
	@docker run --rm --network em-monitor -v "$(CURDIR):/w" -w /w \
	  -e GRAFANA_URL=http://grafana:3000 \
	  -e GRAFANA_ADMIN_USER -e GRAFANA_ADMIN_PASSWORD \
	  -e GF_SECURITY_ADMIN_USER -e GF_SECURITY_ADMIN_PASSWORD \
	  $(PY_IMAGE) python3 scripts/bootstrap_grafana.py

.PHONY: render
render: ## Export panels as PNG (make render C=acme FROM=now-30d) into renders/
	@# The renderer is a headless Chromium, so it only exists for the length of
	@# this run: started here, removed on the way out even if a render fails.
	@# Grafana is permanently pointed at http://em-renderer:8081 and simply
	@# gets "connection refused" in between. GOMEMLIMIT stays well under the
	@# container limit because Chromium needs the headroom, not the Go service.
	@# AUTH_TOKEN must match Grafana's RENDERER_TOKEN: taken from the
	@# environment, else from .env.
	@docker rm -f em-renderer >/dev/null 2>&1 || true
	@token="$${RENDERER_TOKEN:-$$(sed -n 's/^RENDERER_TOKEN=//p' .env 2>/dev/null)}"; \
	[ -n "$$token" ] || { echo "Set RENDERER_TOKEN (the same value Grafana has)."; exit 1; }; \
	docker run --rm -d --name em-renderer --network em-monitor \
	  --memory 1g --cpus 1 -e GOMEMLIMIT=128MiB -e RATE_LIMIT_MAX_LIMIT=1 \
	  -e AUTH_TOKEN="$$token" $(RENDER_IMAGE) >/dev/null
	@status=0; \
	docker run --rm --network em-monitor -v "$(CURDIR):/w" -w /w \
	  --user "$$(id -u):$$(id -g)" \
	  -e GRAFANA_URL=http://grafana:3000 -e RENDERER_URL=http://em-renderer:8081 \
	  -e GRAFANA_ADMIN_USER -e GRAFANA_ADMIN_PASSWORD \
	  -e GF_SECURITY_ADMIN_USER -e GF_SECURITY_ADMIN_PASSWORD \
	  $(PY_IMAGE) python3 scripts/render.py \
	    $(if $(C),--client $(C)) --from $(or $(FROM),now-7d) --to $(or $(TO),now) \
	  || status=$$?; \
	docker rm -f em-renderer >/dev/null 2>&1; \
	exit $$status

# ── Verification ───────────────────────────────────────────────────────────

.PHONY: check-tenancy
check-tenancy: ## Prove a client's data source cannot see another client's data
	@./scripts/check-tenancy.sh

.PHONY: routes
routes: ## Show where an alert would be delivered (make routes C=acme SEV=critical)
	@docker run --rm -v "$(CURDIR)/config/alertmanager:/c:ro" --entrypoint /bin/sh $(AM_IMAGE) -c \
	  'sed -e "s|__SMTP_SMARTHOST__|smtp:587|;s|__SMTP_FROM__|a@b.c|;s|__SMTP_USER__|u|;s|__SMTP_REQUIRE_TLS__|true|;s|__OPS_EMAIL__|ops@b.c|;s|__GRAFANA_URL__|http://x|" /c/alertmanager.yml.tmpl > /tmp/am.yml; \
	   amtool config routes test --config.file=/tmp/am.yml client=$(or $(C),acme) severity=$(or $(SEV),critical)'

# ── Server access ──────────────────────────────────────────────────────────
# The production stack publishes no ports, so there is nothing for `ssh -L` to
# forward to. These start a throwaway proxy on the server's loopback for as
# long as you need it, which you then tunnel to normally.

.PHONY: tunnel
tunnel: ## Expose Prometheus + Alertmanager on the server's 127.0.0.1 (temporary)
	@docker run --rm -d --name em-tunnel-prometheus --network em-monitor \
	  -p 127.0.0.1:9090:9090 alpine/socat \
	  tcp-listen:9090,fork,reuseaddr tcp-connect:prometheus:9090 >/dev/null
	@docker run --rm -d --name em-tunnel-alertmanager --network em-monitor \
	  -p 127.0.0.1:9093:9093 alpine/socat \
	  tcp-listen:9093,fork,reuseaddr tcp-connect:alertmanager:9093 >/dev/null
	@echo "Open from your machine with:"
	@echo "  ssh -L 9090:localhost:9090 -L 9093:localhost:9093 <server>"
	@echo "Close again with: make untunnel"

.PHONY: untunnel
untunnel: ## Remove the temporary proxies started by `make tunnel`
	@docker rm -f em-tunnel-prometheus em-tunnel-alertmanager 2>/dev/null || true
	@echo "tunnels closed"
