#!/usr/bin/env bash
# Check every config file in the repo. Run this before committing.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

PROM_IMAGE=prom/prometheus:v3.13.2
AM_IMAGE=prom/alertmanager:v0.34.0
ALLOY_IMAGE=grafana/alloy:v1.19.0

fails=0
step() { printf '\n\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[32mOK\033[0m   %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; fails=$((fails + 1)); }

# ── Prometheus ─────────────────────────────────────────────────────────────
step "Prometheus config and alert rules"
if out=$(docker run --rm --entrypoint promtool \
          -v "$PWD/config/prometheus:/etc/prometheus:ro" \
          "$PROM_IMAGE" check config /etc/prometheus/prometheus.yml 2>&1); then
  ok "$(grep -c SUCCESS <<<"$out") checks passed"
else
  bad "prometheus config"; echo "$out" | sed 's/^/       /'
fi

# ── Alertmanager ───────────────────────────────────────────────────────────
step "Alertmanager routing and templates"
if out=$(docker run --rm -v "$PWD/config/alertmanager:/c:ro" --entrypoint /bin/sh "$AM_IMAGE" -c '
      set -e
      sed -e "s|__SMTP_SMARTHOST__|smtp.example.com:587|g" \
          -e "s|__SMTP_FROM__|from@example.com|g" \
          -e "s|__SMTP_USER__|user|g" \
          -e "s|__SMTP_REQUIRE_TLS__|true|g" \
          -e "s|__OPS_EMAIL__|ops@example.com|g" \
          -e "s|__GRAFANA_URL__|https://example.com|g" \
          /c/alertmanager.yml.tmpl > /tmp/am.yml
      mkdir -p /tmp/templates
      for t in /c/templates/*.tmpl; do
        sed -e "s|__GRAFANA_URL__|https://example.com|g" "$t" > "/tmp/templates/$(basename "$t")"
      done
      : > /tmp/alertmanager-smtp-password
      amtool check-config /tmp/am.yml' 2>&1); then
  ok "$(grep -oE '[0-9]+ receivers' <<<"$out" | head -1), $(grep -oE '[0-9]+ inhibit rules' <<<"$out" | head -1)"
else
  bad "alertmanager config"; echo "$out" | sed 's/^/       /'
fi

# ── Alloy agent ────────────────────────────────────────────────────────────
step "Agent config"
if out=$(docker run --rm -v "$PWD/agent:/a:ro" \
          -e CLIENT_ID=validate -e HOST_NAME=validate \
          -e INGEST_URL=https://example.com -e INGEST_PASSWORD=x \
          "$ALLOY_IMAGE" validate /a/config.alloy 2>&1); then
  ok "agent/config.alloy"
else
  bad "agent/config.alloy"; echo "$out" | sed 's/^/       /'
fi

# ── Compose ────────────────────────────────────────────────────────────────
step "Docker Compose"
for f in docker-compose.yml docker-compose.dev.yml agent/docker-compose.yml; do
  dir=$(dirname "$f"); base=$(basename "$f")
  if out=$(cd "$dir" && CLIENT_ID=x HOST_NAME=x INGEST_URL=x INGEST_PASSWORD=x \
            docker compose -f "$base" config -q 2>&1); then
    ok "$f"
  else
    bad "$f"; echo "$out" | sed 's/^/       /'
  fi
done

# ── Dashboards ─────────────────────────────────────────────────────────────
step "Grafana dashboards"
for f in config/grafana/dashboards/*.json; do
  if out=$(python3 - "$f" <<'PY' 2>&1
import json, sys
d = json.load(open(sys.argv[1]))
for k in ("uid", "title", "panels", "templating"):
    assert k in d, f"missing key: {k}"
ids = [p["id"] for p in d["panels"]]
assert len(ids) == len(set(ids)), "duplicate panel ids"
for p in d["panels"]:
    assert "gridPos" in p, f"panel {p.get('title')} has no gridPos"
print(f"{d['title']} ({len(d['panels'])} panels)")
PY
  ); then
    ok "$out"
  else
    bad "$f"; echo "$out" | sed 's/^/       /'
  fi
done

# ── clients.yml is the source of truth; make sure it still generates ───────
step "clients.yml"
if out=$(docker run --rm -v "$PWD:/w" -w /w python:3.13-slim sh -c \
          "pip install --quiet --disable-pip-version-check pyyaml >/dev/null 2>&1 && python scripts/generate.py" 2>&1); then
  if grep -q "wrote " <<<"$out"; then
    bad "generated files are stale — run 'make generate' and commit the result"
    grep "wrote " <<<"$out" | sed 's/^/       /'
  else
    ok "all generated files are up to date"
  fi
else
  bad "clients.yml"; echo "$out" | sed 's/^/       /'
fi

# -- Runbook links ----------------------------------------------------------
step "Alert runbook"
if out=$(python3 scripts/check-runbook-links.py 2>&1); then
  ok "$out"
else
  bad "runbook"; echo "$out" | sed 's/^/       /'
fi

echo
if [ "$fails" -eq 0 ]; then
  printf '\033[32mAll checks passed.\033[0m\n'
else
  printf '\033[31m%d check(s) failed.\033[0m\n' "$fails"
fi
exit "$fails"
