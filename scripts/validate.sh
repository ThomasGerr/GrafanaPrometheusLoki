#!/usr/bin/env bash
# Check every config file in the repo. Run this before committing.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

PROM_IMAGE=prom/prometheus:v3.13.2
AM_IMAGE=prom/alertmanager:v0.34.0
ALLOY_IMAGE=grafana/alloy:v1.19.0
LOKI_IMAGE=grafana/loki:3.7.6

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

# ── Loki security rules ────────────────────────────────────────────────────
# The only real parser for LogQL rules is Loki itself, so start a throwaway
# instance with the generated rules and ask its ruler what it loaded. A rule
# file Loki cannot parse loads nothing, which shows up as a count mismatch.
step "Loki security rules"
net="validate-loki-$$"
docker network create "$net" >/dev/null
docker run -d --rm --name "$net" --network "$net" --network-alias loki \
  -v "$PWD/config/loki/loki.yml:/etc/loki/loki.yml:ro" \
  -v "$PWD/config/loki/rules:/etc/loki/rules:ro" \
  --tmpfs /loki:uid=10001 "$LOKI_IMAGE" -config.file=/etc/loki/loki.yml >/dev/null
if out=$(docker run --rm -i --network "$net" -v "$PWD/config/loki:/c:ro" python:3.13-slim python - <<'PY' 2>&1
import pathlib, time, urllib.request
def get(path, tenant=None):
    headers = {"X-Scope-OrgID": tenant} if tenant else {}
    with urllib.request.urlopen(urllib.request.Request("http://loki:3100" + path, headers=headers), timeout=5) as r:
        return r.read().decode()
for _ in range(60):
    try:
        get("/ready"); break
    except Exception:
        time.sleep(1)
else:
    raise SystemExit("Loki did not become ready")
tenants = sorted(d for d in pathlib.Path("/c/rules").iterdir() if d.is_dir())
problems, total = [], 0
for d in tenants:
    want = sum(f.read_text().count("- alert:") for f in d.glob("*.yml"))
    for _ in range(15):
        try:
            got = get("/loki/api/v1/rules", d.name).count("- alert:")
        except Exception:
            got = 0
        if got == want:
            break
        time.sleep(1)
    total += got
    if got != want:
        problems.append(f"{d.name}: Loki loaded {got} of {want} rules")
if problems:
    raise SystemExit("\n".join(problems))
print(f"{total} rules loaded across {len(tenants)} tenant(s)")
PY
); then
  ok "$out"
else
  bad "loki rules"; echo "$out" | sed 's/^/       /'
  docker logs "$net" 2>&1 | grep -iE "rule|parse" | grep -iv "alertmanager" | tail -5 | sed 's/^/       /'
fi
docker rm -f "$net" >/dev/null 2>&1
docker network rm "$net" >/dev/null 2>&1

# ── Alloy agent ────────────────────────────────────────────────────────────
# On a host the agent loads config.alloy, databases.alloy and the
# connections.alloy that install.sh writes, as one directory. Validate them
# the same way, with a connection of every engine, so a wrong argument in a
# database component fails here rather than on a client's server.
step "Agent config"
agent_dir=$(mktemp -d)
cp agent/config.alloy agent/databases.alloy agent/crowdsec.alloy "$agent_dir/"
{
  for engine in postgres mysql redis mongodb mssql; do
    printf 'database_%s "db_%s" {\n  name = "%s"\n' "$engine" "$engine" "$engine"
    [ "$engine" = redis ] && printf '  address = "redis://redis:6379"\n'
    printf '  secret_file = "/dev/null"\n  forward_to = [prometheus.remote_write.central.receiver]\n}\n'
  done
  printf 'crowdsec_metrics "local" {\n  forward_to = [prometheus.remote_write.central.receiver]\n}\n'
} > "$agent_dir/connections.alloy"
if out=$(docker run --rm -v "$agent_dir:/a:ro" \
          -e CLIENT_ID=validate -e HOST_NAME=validate \
          -e INGEST_URL=https://example.com -e INGEST_PASSWORD=x \
          "$ALLOY_IMAGE" validate /a 2>&1); then
  ok "agent/config.alloy + databases.alloy (all five engines) + crowdsec.alloy"
else
  bad "agent config"; echo "$out" | sed 's/^/       /'
fi
rm -rf "$agent_dir"

# ── Compose ────────────────────────────────────────────────────────────────
step "Docker Compose"
for f in docker-compose.yml docker-compose.dev.yml agent/docker-compose.yml; do
  dir=$(dirname "$f"); base=$(basename "$f")
  # Dummy values for what the stack requires at start, so the check does not
  # depend on a local .env (a fresh clone has none).
  if out=$(cd "$dir" && CLIENT_ID=x HOST_NAME=x INGEST_URL=x INGEST_PASSWORD=x RENDERER_TOKEN=x \
            docker compose -f "$base" config -q 2>&1); then
    ok "$f"
  else
    bad "$f"; echo "$out" | sed 's/^/       /'
  fi
done
# The agent again, with CrowdSec's optional services switched on.
if out=$(cd agent && CLIENT_ID=x HOST_NAME=x INGEST_URL=x INGEST_PASSWORD=x COMPOSE_PROFILES=crowdsec \
          docker compose config -q 2>&1); then
  ok "agent/docker-compose.yml with the crowdsec profile"
else
  bad "agent/docker-compose.yml with the crowdsec profile"; echo "$out" | sed 's/^/       /'
fi

# Dokploy builds these on every deploy; a Dockerfile that COPYs a file that
# is not there should fail here, not on the server.
step "Production images"
if out=$(RENDERER_TOKEN=x docker compose -f docker-compose.yml build --quiet 2>&1); then
  ok "every service in docker-compose.yml builds"
else
  bad "production image build"; echo "$out" | grep -v "level=warning" | tail -15 | sed 's/^/       /'
fi
# Built on each monitored host where CrowdSec is on.
if out=$(docker build -q agent/crowdsec 2>&1); then
  ok "agent/crowdsec (firewall bouncer) builds"
else
  bad "agent/crowdsec build"; echo "$out" | tail -15 | sed 's/^/       /'
fi

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
  if grep -qE "wrote |removed " <<<"$out"; then
    bad "generated files are stale — run 'make generate' and commit the result"
    grep -E "wrote |removed " <<<"$out" | sed 's/^/       /'
  else
    ok "all generated files are up to date"
  fi
else
  bad "clients.yml"; echo "$out" | sed 's/^/       /'
fi

# ── Metric allowlist ───────────────────────────────────────────────────────
# The agent drops every metric its allowlists do not name, so a rule or panel
# on anything else would show nothing and alert on nothing, silently.
step "Agent metric allowlist"
if out=$(docker run --rm -v "$PWD:/w" -w /w python:3.13-slim sh -c \
          "pip install --quiet --disable-pip-version-check pyyaml >/dev/null 2>&1 && python scripts/check-metric-allowlist.py" 2>&1); then
  ok "$out"
else
  bad "metric allowlist"; echo "$out" | sed 's/^/       /'
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
