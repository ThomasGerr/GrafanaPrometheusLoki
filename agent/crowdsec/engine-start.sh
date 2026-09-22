#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# CrowdSec engine start-up, around the image's own /docker_start.sh.
#
# Everything the engine needs per host comes from the environment:
#
#   BOUNCER_KEY_firewall    key the firewall bouncer authenticates with
#                           (CROWDSEC_BOUNCER_KEY in .env)
#   CROWDSEC_WHITELIST      comma-separated IPs/CIDRs never to block
#   CROWDSEC_ENROLL_KEY     optional: link to app.crowdsec.net
#   HOST_NAME, CLIENT_ID    how the host appears in the console
#
# Before the engine starts, this writes which logs to read and makes sure it
# can start even when CrowdSec's central API is unreachable. Once its local
# API answers, a background step registers the bouncer, brings the allowlist
# in line with CROWDSEC_WHITELIST and enrolls in the console. The
# healthcheck waits for that step, so the bouncer only starts once its key
# is registered.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

CONF=/etc/crowdsec
READY=/tmp/grafana-prometheus-loki-setup-done
ALLOWLIST=grafana-prometheus-loki
log() { echo "grafana-prometheus-loki: $*" >&2; }
rm -f "$READY"

if [[ -z "${BOUNCER_KEY_firewall:-}" ]]; then
  log "ERROR CROWDSEC_BOUNCER_KEY is not set, so nothing could block."
  log "      Set it in .env (generate one with: openssl rand -hex 32) and redeploy."
  exit 1
fi

# First start: the config volume is empty. Stage the default config the way
# docker_start.sh would, so cscli works before it runs.
if [[ ! -e "$CONF/config.yaml" ]]; then
  mkdir -p "$CONF"
  rsync -a --ignore-existing /staging/etc/crowdsec/ "$CONF/"
fi

# ── Which logs to read ──────────────────────────────────────────────────────
# Every source is optional: a host without a journal, Traefik or nginx simply
# has less to read.
{
  echo "# Written at start-up by engine-start.sh: the logs CrowdSec reads."
  if compgen -G "/var/log/journal/*/*.journal" >/dev/null; then
    cat <<'EOF'
# sshd, from the host's journal. OpenSSH 9.8+ logs as sshd-session.
source: journalctl
journalctl_filter:
  - "_COMM=sshd"
  - "_COMM=sshd-session"
labels:
  type: syslog
---
EOF
  else
    log "no systemd journal mounted: SSH attacks will not be detected"
  fi
  cat <<'EOF'
# Web servers and reverse proxies logging to stdout, by container name.
source: docker
container_name_regexp:
  - "(?i)traefik"
labels:
  type: traefik
---
source: docker
container_name_regexp:
  - "(?i)nginx"
labels:
  type: nginx
---
source: docker
container_name_regexp:
  - "(?i)apache"
  - "(?i)httpd"
labels:
  type: apache2
EOF
  # A web server installed on the host, logging to files.
  for dir in apache2 httpd; do
    if compgen -G "/var/log/host/$dir/*access*log*" >/dev/null; then
      printf -- '---\nsource: file\nfilenames:\n  - /var/log/host/%s/*access*log*\n  - /var/log/host/%s/*error*log*\nlabels:\n  type: apache2\n' "$dir" "$dir"
    fi
  done
  if compgen -G "/var/log/host/nginx/*access*log*" >/dev/null; then
    printf -- '---\nsource: file\nfilenames:\n  - /var/log/host/nginx/*access*log*\n  - /var/log/host/nginx/*error*log*\nlabels:\n  type: nginx\n'
  fi
  if [[ -f /var/log/traefik/access.log ]]; then
    cat <<'EOF'
---
# Dokploy's Traefik access log.
source: file
filenames:
  - /var/log/traefik/access.log
labels:
  type: traefik
EOF
  fi
} > "$CONF/acquis.yaml"

# ── Central API: never a reason not to start ────────────────────────────────
# docker_start.sh registers with CrowdSec's central API on first start and
# exits if that fails — an outage, a rate limit, blocked outbound traffic —
# leaving the host unprotected because *sharing* failed. Register here first;
# on failure, start without the central API this time (local detection and
# blocking still work) and try again at the next start.
creds="$CONF/online_api_credentials.yaml"
if ! grep -q '^login:' "$creds" 2>/dev/null; then
  if cscli capi register -f "$creds.new" >/dev/null 2>&1 && grep -q '^login:' "$creds.new"; then
    mv "$creds.new" "$creds"
    yq -i ".api.server.online_client.credentials_path = \"$creds\"" "$CONF/config.yaml"
    log "registered with CrowdSec's central API"
  else
    rm -f "$creds.new"
    export DISABLE_ONLINE_API=true
    log "WARNING could not register with CrowdSec's central API; running without it (no community blocklist, nothing shared). Retrying at the next start."
  fi
fi

# ── After the local API is up ───────────────────────────────────────────────
# Does this key authenticate against the local API? A plain HTTP request over
# bash's /dev/tcp; the image has no curl.
key_works() {
  local status
  exec 3<>/dev/tcp/127.0.0.1/8080 || return 1
  printf 'GET /v1/decisions?ip=127.0.0.1 HTTP/1.0\r\nX-Api-Key: %s\r\n\r\n' "$1" >&3
  read -r _ status _ <&3
  exec 3<&-
  [[ "$status" == 200 ]]
}

setup() {
  for _ in $(seq 100); do cscli lapi status >/dev/null 2>&1 && break; sleep 3; done

  # The bouncer, under the key from the environment. CrowdSec keeps an
  # existing registration across restarts, so a key that changed (a new
  # .env, a reset volume) would be refused for good; re-register only then.
  if ! key_works "$BOUNCER_KEY_firewall"; then
    cscli bouncers delete firewall >/dev/null 2>&1 || true
    if cscli bouncers add firewall --key "$BOUNCER_KEY_firewall" >/dev/null; then
      log "firewall bouncer registered"
    else
      log "ERROR could not register the firewall bouncer"
    fi
  fi

  # The allowlist, as a diff so there is never a moment without it. It
  # covers every source of decisions: local detection, the community
  # blocklist, the console and cscli.
  cscli allowlists inspect "$ALLOWLIST" >/dev/null 2>&1 \
    || cscli allowlists create "$ALLOWLIST" -d "Never block: CROWDSEC_WHITELIST" >/dev/null
  local want have
  want="$(tr ', ' '\n\n' <<<"${CROWDSEC_WHITELIST:-}" | grep -v '^$' | sort -u)"
  have="$(cscli allowlists inspect "$ALLOWLIST" -o raw 2>/dev/null | awk -F, 'NR > 1 { print $3 }' | sort -u)"
  local add remove
  add="$(comm -23 <(echo "$want") <(echo "$have") | grep -v '^$' || true)"
  remove="$(comm -13 <(echo "$want") <(echo "$have") | grep -v '^$' || true)"
  # shellcheck disable=SC2086
  [[ -z "$add" ]] || cscli allowlists add "$ALLOWLIST" $add -d "CROWDSEC_WHITELIST" >/dev/null
  # shellcheck disable=SC2086
  [[ -z "$remove" ]] || cscli allowlists remove "$ALLOWLIST" $remove >/dev/null
  log "never blocking: ${want//$'\n'/, }"

  # Console enrollment, once per key. A bad key is a warning: CrowdSec
  # protects the host either way.
  if [[ -n "${CROWDSEC_ENROLL_KEY:-}" ]]; then
    local marker="$CONF/.grafana-prometheus-loki-enrolled" sum
    sum="$(printf '%s' "$CROWDSEC_ENROLL_KEY" | sha256sum | cut -d' ' -f1)"
    if [[ "$(cat "$marker" 2>/dev/null)" != "$sum" ]]; then
      if out="$(cscli console enroll --overwrite --name "${HOST_NAME:-}" --tags "${CLIENT_ID:-}" "$CROWDSEC_ENROLL_KEY" 2>&1)"; then
        echo "$sum" > "$marker"
        log "console enrollment sent: accept '${HOST_NAME:-this host}' at app.crowdsec.net"
      else
        log "WARNING console enrollment failed: $(tail -n 1 <<<"$out")"
      fi
    fi
  fi

  touch "$READY"
}
setup &

exec /bin/bash /docker_start.sh "$@"
