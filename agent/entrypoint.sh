#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# grafana-prometheus-loki agent — start-up
#
# The agent configures itself from its environment, every time it starts:
#
#   DB_<NAME>=<url>          one database to monitor, e.g.
#                            DB_APP=postgres://monitor:pw@app-db:5432/app
#   COMPOSE_PROFILES         containing "crowdsec": collect CrowdSec's metrics
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
LOCAL_HOSTS="localhost|127\.0\.0\.1|::1"

log() { echo "agent: $*" >&2; }

# Percent-decoding for the engines that do not take a URL. Backslashes are
# doubled first so printf %b cannot read them as escapes.
urldecode() {
  local s="${1//\\/\\\\}"
  printf '%b' "${s//%/\\x}"
}

# Splits a URL into U_* globals. The userinfo match is greedy, so an
# unencoded @ in the password still works; the host is what follows the
# last @.
parse_url() {
  local hostport
  [[ "$1" =~ ^([a-zA-Z][a-zA-Z0-9+.-]*)://((.*)@)?([^/?@]*)(/[^?]*)?(\?.*)?$ ]] || return 1
  U_SCHEME="${BASH_REMATCH[1],,}"
  U_USERINFO="${BASH_REMATCH[3]}"
  hostport="${BASH_REMATCH[4]}"
  U_PATH="${BASH_REMATCH[5]}"
  U_QUERY="${BASH_REMATCH[6]}"
  U_USER="${U_USERINFO%%:*}"
  U_PASS=""
  [[ "$U_USERINFO" == *:* ]] && U_PASS="${U_USERINFO#*:}"
  U_BRACKETS=""
  if [[ "$hostport" =~ ^\[([^]]*)\](:([0-9]+))?$ ]]; then
    U_HOST="${BASH_REMATCH[1]}"; U_PORT="${BASH_REMATCH[3]}"; U_BRACKETS=1
  elif [[ "$hostport" =~ ^([^:]*)(:([0-9]+))?$ ]]; then
    U_HOST="${BASH_REMATCH[1]}"; U_PORT="${BASH_REMATCH[3]}"
  elif [[ "$hostport" == *,* ]]; then
    U_HOST="$hostport"; U_PORT=""     # a MongoDB seed list; rejected below
  else
    return 1
  fi
  [[ -n "$U_HOST" ]]
}

db_engine() {
  case "$1" in
    postgres|postgresql) echo postgres ;;
    mysql|mariadb)       echo mysql ;;
    redis|rediss)        echo redis ;;
    mongodb)             echo mongodb ;;
    sqlserver|mssql)     echo mssql ;;
    *)                   return 1 ;;
  esac
}

# DB_MY_SHOP -> my-shop: the name dashboards and alerts show.
db_name() {
  local n="${1#DB_}"
  n="${n,,}"
  echo "${n//_/-}"
}

# Prints why a database cannot be used, or nothing. Never repeats the URL:
# it holds a password, and this output ends up in logs and chats.
db_problem() {
  local name="$1" url="$2" engine
  [[ "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]] || { echo "name must be letters, digits and _"; return; }
  parse_url "$url" || { echo "not a connection URL (scheme://user:password@host:port)"; return; }
  [[ "$U_SCHEME" != "mongodb+srv" ]] || { echo "mongodb+srv:// is for hosted clusters; use mongodb://user:pass@host:27017/admin"; return; }
  engine="$(db_engine "$U_SCHEME")" \
    || { echo "unsupported scheme '$U_SCHEME://' (postgres, mysql, mariadb, redis, rediss, mongodb, sqlserver, mssql)"; return; }
  [[ "$U_HOST" != *,* ]] || { echo "several hosts in one URL; give each server its own DB_ variable"; return; }
  [[ "$engine" == redis || -n "$U_USER" ]] || { echo "the URL has no user; see docs/databases.md for a monitoring user"; return; }
}

# The DB_* variables, sorted, as NAME=value lines (values may hold anything
# but a newline).
db_vars() {
  while IFS='=' read -r -d '' key value; do
    [[ "$key" =~ ^DB_[A-Za-z0-9_]+$ ]] && printf '%s=%s\n' "$key" "$value"
  done < <(env -0) | sort
}

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

exec /bin/alloy "$@"
