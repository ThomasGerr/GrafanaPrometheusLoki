#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# grafana-prometheus-loki agent — start-up
#
# The agent configures itself from its environment, every time it starts:
#
#   DB_<NAME>=<url>          one database to monitor, e.g.
#                            DB_APP=postgres://monitor:pw@app-db:5432/app
#   COMPOSE_PROFILES         containing "crowdsec": collect CrowdSec's metrics;
#                            without "backup": clear old backup results
#
# From those it writes connections.alloy (which database and CrowdSec
# components to run) and one credentials file per database, then starts
# Alloy. Nothing is kept between starts, so changing a variable and
# recreating the container is all a change takes.
#
#   entrypoint.sh check      only validate the DB_* variables and exit;
#                            install.sh runs this before it changes anything.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

CONNECTIONS=/etc/alloy/connections.alloy
SECRETS=/run/agent-secrets
# shellcheck source=lib/db-url.sh
. /usr/local/lib/db-url.sh

log() { echo "agent: $*" >&2; }

# ── check mode ──────────────────────────────────────────────────────────────
if [[ "${1:-}" == check ]]; then
  bad=0
  while IFS='=' read -r key url; do
    name="$(db_name "$key")"
    if problem="$(db_problem "$name" "$url")" && [[ -n "$problem" ]]; then
      echo "$key: $problem"; bad=1
    else
      parse_url "$url"; echo "$key: ok, $(db_engine "$U_SCHEME") database '$name' host=$U_HOST"
    fi
  done < <(db_vars)
  exit "$bad"
fi

# ── Generate connections.alloy ──────────────────────────────────────────────
rm -rf "$SECRETS"
mkdir -p "$SECRETS"
chmod 700 "$SECRETS"
cat > "$CONNECTIONS" <<'EOF'
// Generated at start-up by entrypoint.sh from the DB_* and COMPOSE_PROFILES
// variables. Each block is one of the components in databases.alloy or
// crowdsec.alloy.
EOF

# Writes one database's credentials in the form its exporter expects, and
# its block in connections.alloy.
add_db() {
  local name="$1" url="$2" engine host label secret="$SECRETS/$1" local_db="" query user
  parse_url "$url"
  engine="$(db_engine "$U_SCHEME")"
  host="$U_HOST"
  # The agent's own loopback is not the host's. host.docker.internal is the
  # host as seen from the container (extra_hosts in docker-compose.yml).
  if [[ "$host" =~ ^($LOCAL_HOSTS)$ ]]; then
    host=host.docker.internal; U_BRACKETS=""; local_db=1
  fi
  [[ -n "$U_BRACKETS" ]] && host="[$host]"
  label="db_${name//-/_}"
  umask 077
  case "$engine" in
    postgres)
      # lib/pq defaults to sslmode=require, which a database on the same
      # host (a container name, or localhost) rarely offers.
      query="$U_QUERY"
      if [[ ( -n "$local_db" || "$U_HOST" != *.* ) && "$query" != *sslmode=* ]]; then
        query="${query:-?}"; [[ "$query" == "?" ]] || query="$query&"
        query="${query}sslmode=disable"
      fi
      printf '%s' "postgresql://$U_USERINFO@$host${U_PORT:+:$U_PORT}$U_PATH$query" > "$secret" ;;
    mysql)
      # A Go DSN, not a URL, with the credentials decoded.
      printf '%s' "$(urldecode "$U_USER"):$(urldecode "$U_PASS")@tcp($host:${U_PORT:-3306})/${U_QUERY}" > "$secret" ;;
    redis)
      printf '%s' "$(urldecode "$U_PASS")" > "$secret" ;;
    mongodb)
      printf '%s' "mongodb://$U_USERINFO@$host${U_PORT:+:$U_PORT}${U_PATH:-/}$U_QUERY" > "$secret" ;;
    mssql)
      printf '%s' "sqlserver://$U_USERINFO@$host:${U_PORT:-1433}$U_PATH$U_QUERY" > "$secret" ;;
  esac
  {
    echo
    echo "database_$engine \"$label\" {"
    echo "  name        = \"$name\""
    if [[ "$engine" == redis ]]; then
      echo "  address     = \"$U_SCHEME://$host:${U_PORT:-6379}\""
      if [[ -n "$U_USER" ]]; then
        user="$(urldecode "$U_USER")"; user="${user//\\/\\\\}"
        echo "  user        = \"${user//\"/\\\"}\""
      fi
    fi
    echo "  secret_file = \"$secret\""
    echo "  forward_to  = [prometheus.remote_write.central.receiver]"
    echo "}"
  } >> "$CONNECTIONS"
  log "monitoring $engine database '$name'"
}

# A bad variable skips that one database, loudly, rather than keeping the
# whole agent (host metrics and logs included) from starting.
while IFS='=' read -r key url; do
  name="$(db_name "$key")"
  if problem="$(db_problem "$name" "$url")" && [[ -n "$problem" ]]; then
    log "ERROR skipping $key: $problem"
    continue
  fi
  add_db "$name" "$url"
done < <(db_vars)

if [[ ",${COMPOSE_PROFILES:-}," == *,crowdsec,* ]]; then
  cat >> "$CONNECTIONS" <<'EOF'

crowdsec_metrics "local" {
  forward_to = [prometheus.remote_write.central.receiver]
}
EOF
  log "collecting CrowdSec metrics"
fi

# Backups off: clear the last run's results, or the agent would keep
# reporting them, and "backup too old" would fire forever.
if [[ ",${COMPOSE_PROFILES:-}," != *,backup,* ]]; then
  rm -f /var/lib/node-textfile/restic.prom
fi

exec /bin/alloy "$@"
