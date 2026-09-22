#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# grafana-prometheus-loki agent installer
#
#   curl -fsSL https://raw.githubusercontent.com/ThomasGerr/GrafanaPrometheusLoki/main/agent/install.sh \
#     | sudo bash -s -- --client acme --ingest https://ingest.example.com --password 'secret'
#
# Monitor a database on this host by adding a connection URL. On a host that
# already has the agent, the client, ingest URL and password are remembered:
#
#   curl -fsSL .../agent/install.sh | sudo bash -s -- --db app=postgres://monitor:pw@app-db:5432/app
#
# Idempotent: re-running upgrades the config and restarts the agent.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

INSTALL_DIR=/opt/grafana-prometheus-loki-agent
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/ThomasGerr/GrafanaPrometheusLoki/main/agent}"

CLIENT_ID=""
INGEST_URL=""
INGEST_PASSWORD=""
HOST_NAME=""
DB_ADD=()
DB_REMOVE=()
DB_NETWORKS=()
CROWDSEC_MODE=""              # on, off, or empty to keep what the host has
CROWDSEC_ENROLL_ARG=""
CROWDSEC_WHITELIST_ARGS=()

die() { echo "error: $*" >&2; exit 1; }
info() { echo "==> $*"; }

usage() {
  cat >&2 <<USAGE
Usage: install.sh --client <id> --ingest <url> --password <password> [--host <name>]
                  [--db [name=]<url>]... [--remove-db <name>]... [--db-network <network>]...
                  [--crowdsec | --no-crowdsec] [--crowdsec-enroll-key <key>]
                  [--crowdsec-whitelist <ip or cidr,...>]

  --client    Client id, exactly as it appears in the central clients.yml
  --ingest    Ingest gateway URL, e.g. https://ingest.example.com
  --password  This client's password from the central INGEST_USERS variable
  --host      Name for this server in dashboards (default: this machine's hostname)
  --raw-base  Where to fetch config.alloy and docker-compose.yml from.
              Defaults to this repo's main branch. Pass it when installing
              from a pinned commit, so every file comes from that same commit
              instead of whatever main looks like right now.

Databases (repeatable; connections already on this host are kept):
  --db          Monitor a database. The engine follows from the URL:
                  postgres://user:pass@host:5432/dbname   (also Supabase)
                  mysql://user:pass@host:3306             (also mariadb://)
                  redis://:pass@host:6379                 (also rediss://)
                  mongodb://user:pass@host:27017/admin
                  sqlserver://user:pass@host:1433         (also mssql://)
                Prefix a name to tell several apart: --db shop=mysql://...
                The host can be a container name; the agent joins its network.
                Percent-encode special characters in the password (@ is %40).
  --remove-db   Stop monitoring the database with this name.
  --db-network  Also join this Docker network, when a database is reachable
                only on a network the automatic detection does not find.

CrowdSec (detects attacks in this host's logs and blocks them in its firewall):
  --crowdsec              Turn it on. Stays on for later runs until --no-crowdsec.
  --no-crowdsec           Turn it off and remove its firewall rules.
  --crowdsec-enroll-key   Link this server to app.crowdsec.net (turns it on).
  --crowdsec-whitelist    Addresses never to block, comma-separated IPs or
                          CIDRs. Added to earlier ones. The address you are
                          connected over SSH from is added automatically.

On a host where the agent is already installed, --client, --ingest,
--password and --host default to the values it was installed with.
USAGE
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --client)   CLIENT_ID="${2:-}";       shift 2 ;;
    --ingest)   INGEST_URL="${2:-}";      shift 2 ;;
    --password) INGEST_PASSWORD="${2:-}"; shift 2 ;;
    --host)     HOST_NAME="${2:-}";       shift 2 ;;
    --raw-base) RAW_BASE="${2:-}";        shift 2 ;;
    --db)         DB_ADD+=("${2:-}");      shift 2 ;;
    --remove-db)  DB_REMOVE+=("${2:-}");   shift 2 ;;
    --db-network) DB_NETWORKS+=("${2:-}"); shift 2 ;;
    --crowdsec)           CROWDSEC_MODE=on;  shift ;;
    --no-crowdsec)        CROWDSEC_MODE=off; shift ;;
    --crowdsec-enroll-key) CROWDSEC_ENROLL_ARG="${2:-}"; CROWDSEC_MODE="${CROWDSEC_MODE:-on}"; shift 2 ;;
    --crowdsec-whitelist) CROWDSEC_WHITELIST_ARGS+=("${2:-}"); shift 2 ;;
    -h|--help)  usage ;;
    *)          die "unknown option: $1" ;;
  esac
done

# ── Preconditions ───────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "run as root (use sudo)"

# Re-running on an installed host: anything not given keeps its current value,
# so adding a database does not mean digging up the ingest password again.
# Read the file as data; never source it.
env_value() {
  [[ -f "$INSTALL_DIR/.env" ]] || return 0
  sed -n "s/^$1=//p" "$INSTALL_DIR/.env" | head -n 1
}
CLIENT_ID="${CLIENT_ID:-$(env_value CLIENT_ID)}"
INGEST_URL="${INGEST_URL:-$(env_value INGEST_URL)}"
INGEST_PASSWORD="${INGEST_PASSWORD:-$(env_value INGEST_PASSWORD)}"
HOST_NAME="${HOST_NAME:-$(env_value HOST_NAME)}"

[[ -n "$CLIENT_ID" ]]       || usage
[[ -n "$INGEST_URL" ]]      || usage
[[ -n "$INGEST_PASSWORD" ]] || usage

command -v docker >/dev/null 2>&1 || die "docker is not installed"
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is not installed"

# The client id becomes a metric label, a Loki tenant and a username. Catch a
# typo here rather than after a week of data has landed under the wrong name.
[[ "$CLIENT_ID" =~ ^[a-z0-9][a-z0-9_-]*$ ]] \
  || die "client id '$CLIENT_ID' must match [a-z0-9][a-z0-9_-]*"

INGEST_URL="${INGEST_URL%/}"
[[ "$INGEST_URL" =~ ^https:// ]] \
  || echo "warning: ingest URL is not https — credentials will cross the network in the clear" >&2

HOST_NAME="${HOST_NAME:-$(hostname -s 2>/dev/null || hostname)}"

# Where does journald keep its logs? On disk (/var/log/journal) is the usual
# case, but some distributions keep them in memory only (/run/log/journal).
# Never mount a path that does not exist: Docker would create it, and an empty
# /var/log/journal quietly switches journald to on-disk storage.
if [[ -d /var/log/journal ]]; then
  JOURNAL_DIR=/var/log/journal
elif [[ -d /run/log/journal ]]; then
  JOURNAL_DIR=/run/log/journal
else
  JOURNAL_DIR="$INSTALL_DIR/no-journal"
  mkdir -p "$JOURNAL_DIR"
  echo "warning: no systemd journal found — system logs and security alerts will not work on this host" >&2
fi

info "client:  $CLIENT_ID"
info "host:    $HOST_NAME"
info "ingest:  $INGEST_URL"
info "journal: $JOURNAL_DIR"

# ── Databases: parsing ──────────────────────────────────────────────────────
# Connection URLs are kept one per file in db-connections/<name>.url, root-only.
# Every run rebuilds everything the agent reads from those files, so adding,
# changing and removing a database are all the same operation.
DB_DIR="$INSTALL_DIR/db-connections"
LOCAL_HOSTS="localhost|127\.0\.0\.1|::1"

# Percent-decoding for the engines that do not take a URL. Backslashes are
# doubled first so printf %b cannot read them as escapes.
urldecode() {
  local s="${1//\\/\\\\}"
  printf '%b' "${s//%/\\x}"
}

# Splits a URL into U_* globals. The userinfo match is greedy, so an unencoded
# @ in the password still works; the host is whatever follows the last @.
parse_url() {
  local url="$1" hostport
  [[ "$url" =~ ^([a-zA-Z][a-zA-Z0-9+.-]*)://((.*)@)?([^/?@]*)(/[^?]*)?(\?.*)?$ ]] \
    || return 1
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
    # A MongoDB seed list. Kept whole so validate_db can explain the problem.
    U_HOST="$hostport"; U_PORT=""
  else
    return 1
  fi
  [[ -n "$U_HOST" ]]
}

db_engine() {
  case "$1" in
    postgres|postgresql)   echo postgres ;;
    mysql|mariadb)         echo mysql ;;
    redis|rediss)          echo redis ;;
    mongodb)               echo mongodb ;;
    sqlserver|mssql)       echo mssql ;;
    *)                     return 1 ;;
  esac
}

# "name=url" or just "url". Without a name, the host's first label is used:
# postgres://…@app-db:5432 becomes "app-db".
split_db_arg() {
  local arg="$1"
  if [[ "$arg" =~ ^([a-zA-Z0-9_-]+)=(.+)$ ]]; then
    DB_NAME="${BASH_REMATCH[1],,}"; DB_URL="${BASH_REMATCH[2]}"
  else
    DB_URL="$arg"
    parse_url "$DB_URL" || die "--db: not a connection URL (expected scheme://user:password@host:port)"
    DB_NAME="${U_HOST%%.*}"
    DB_NAME="${DB_NAME,,}"
    DB_NAME="${DB_NAME//[^a-z0-9_-]/-}"
    if [[ "$U_HOST" =~ ^($LOCAL_HOSTS)$ ]]; then
      DB_NAME="$(db_engine "$U_SCHEME" || echo db)"
    fi
  fi
}

# Checks everything that can be checked without touching the host. Error
# messages never repeat the URL: it holds a password, and this output tends to
# be pasted into chats and tickets.
validate_db() {
  local name="$1" url="$2" engine
  [[ "$name" =~ ^[a-z0-9][a-z0-9_-]*$ ]] \
    || die "database name '$name' must match [a-z0-9][a-z0-9_-]*"
  parse_url "$url" || die "--db $name: not a valid connection URL"
  if [[ "$U_SCHEME" == "mongodb+srv" ]]; then
    die "--db $name: mongodb+srv:// is for hosted clusters; the agent monitors
  one server directly. Use mongodb://user:pass@host:27017/admin."
  fi
  engine="$(db_engine "$U_SCHEME")" \
    || die "--db $name: unsupported scheme '$U_SCHEME://' (postgres, mysql, mariadb, redis, rediss, mongodb, sqlserver, mssql)"
  if [[ "$U_HOST" == *,* ]]; then
    die "--db $name: several hosts in one URL. Give each server its own --db,
  on the host it runs on — the agent monitors a server, not a cluster."
  fi
  if [[ "$engine" != redis && -z "$U_USER" ]]; then
    die "--db $name: the URL has no user. See docs/databases.md for creating a
  read-only monitoring user."
  fi
}

# ── Databases: connecting ───────────────────────────────────────────────────
# Which Docker networks must the agent join to reach this host name? Tries a
# container name, then a Compose service name, then a Swarm service (Dokploy's
# own databases are Swarm services on dokploy-network). Prints one network per
# line; prints nothing for an address outside Docker, and the single line
# "@host" for a container that uses the host's own network stack.
db_networks_for() {
  local host="$1" ids id nets
  if nets=$(docker inspect --type container \
              -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$host" 2>/dev/null); then
    :
  elif ids=$(docker ps -q --filter "label=com.docker.compose.service=$host") && [[ -n "$ids" ]]; then
    [[ $(wc -w <<<"$ids") -eq 1 ]] \
      || echo "warning: several containers run a Compose service called '$host'; joining the networks of all of them" >&2
    nets=$(for id in $ids; do
             docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$id"
           done)
  elif ids=$(docker service inspect -f '{{range .Spec.TaskTemplate.Networks}}{{.Target}} {{end}}' "$host" 2>/dev/null); then
    nets=$(for id in $ids; do docker network inspect -f '{{.Name}}' "$id"; done)
  else
    return 0
  fi
  for id in $nets; do
    case "$id" in
      host) echo "@host" ;;
      bridge|none) ;;
      *) echo "$id" ;;
    esac
  done
}

# Turns one stored URL into what the agent reads: a secret file in the form
# the engine's exporter expects, and a block in connections.alloy.
build_db() {
  local name="$1" url="$2" engine host nets="" label local_db="" user
  local secret="$INSTALL_DIR/db-secrets/$1"
  parse_url "$url"
  engine="$(db_engine "$U_SCHEME")"
  host="$U_HOST"

  if [[ "$host" =~ ^($LOCAL_HOSTS)$ ]]; then
    local_db=1
  else
    nets="$(db_networks_for "$host")"
    if [[ "$nets" == *@host* ]]; then
      local_db=1
      nets=""
    elif [[ -n "$nets" ]]; then
      while read -r net; do DB_AUTO_NETWORKS+=("$net"); done <<<"$nets"
    elif docker inspect --type container "$host" >/dev/null 2>&1; then
      echo "warning: database $name: container '$host' is only on Docker's default bridge," >&2
      echo "  where names do not resolve. Put it on a user-defined network, or" >&2
      echo "  publish its port and connect to localhost instead." >&2
    fi
  fi
  # The agent's own loopback is not the host's. host.docker.internal is the
  # host as seen from the container (extra_hosts in docker-compose.yml).
  if [[ -n "$local_db" ]]; then
    host=host.docker.internal
    U_BRACKETS=""
    DB_LOCAL_NAMES+=("$name")
  fi
  [[ -n "$U_BRACKETS" ]] && host="[$host]"

  label="db_${name//-/_}"
  : > "$secret"
  case "$engine" in
    postgres)
      # lib/pq defaults to sslmode=require, which a database on the same host
      # rarely offers. Only for those, and only when the URL does not say.
      local query="$U_QUERY"
      if [[ ( -n "$local_db" || -n "$nets" ) && "$query" != *sslmode=* ]]; then
        query="${query:-?}"; [[ "$query" == "?" ]] || query="$query&"
        query="${query}sslmode=disable"
      fi
      printf '%s' "postgresql://$U_USERINFO@$host${U_PORT:+:$U_PORT}$U_PATH$query" > "$secret"
      ;;
    mysql)
      # The exporter wants a Go DSN, not a URL, and the credentials decoded.
      printf '%s' "$(urldecode "$U_USER"):$(urldecode "$U_PASS")@tcp($host:${U_PORT:-3306})/${U_QUERY}" > "$secret"
      ;;
    redis)
      printf '%s' "$(urldecode "$U_PASS")" > "$secret"
      ;;
    mongodb)
      printf '%s' "mongodb://$U_USERINFO@$host${U_PORT:+:$U_PORT}${U_PATH:-/}$U_QUERY" > "$secret"
      ;;
    mssql)
      printf '%s' "sqlserver://$U_USERINFO@$host:${U_PORT:-1433}$U_PATH$U_QUERY" > "$secret"
      ;;
  esac

  {
    echo
    echo "database_$engine \"$label\" {"
    echo "  name        = \"$name\""
    if [[ "$engine" == redis ]]; then
      echo "  address     = \"$U_SCHEME://$host:${U_PORT:-6379}\""
      if [[ -n "$U_USER" ]]; then
        user="$(urldecode "$U_USER")"
        user="${user//\\/\\\\}"
        echo "  user        = \"${user//\"/\\\"}\""
      fi
    fi
    echo "  secret_file = \"/etc/alloy-secrets/$name\""
    echo "  forward_to  = [prometheus.remote_write.central.receiver]"
    echo "}"
  } >> "$INSTALL_DIR/connections.alloy"
  DB_ENGINES["$name"]="$engine"
  DB_LABELS["$name"]="$label"
}

# Check every database flag now, before anything on this host changes.
ADD_NAMES=(); ADD_URLS=()
for arg in "${DB_ADD[@]+"${DB_ADD[@]}"}"; do
  split_db_arg "$arg"
  validate_db "$DB_NAME" "$DB_URL"
  for n in "${ADD_NAMES[@]+"${ADD_NAMES[@]}"}"; do
    [[ "$n" != "$DB_NAME" ]] || die "two --db flags are both called '$DB_NAME'; name them: --db other=…"
  done
  ADD_NAMES+=("$DB_NAME"); ADD_URLS+=("$DB_URL")
done
for n in "${DB_REMOVE[@]+"${DB_REMOVE[@]}"}"; do
  [[ "$n" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || die "--remove-db: '$n' is not a database name"
done
for n in "${DB_NETWORKS[@]+"${DB_NETWORKS[@]}"}"; do
  [[ "$n" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] || die "--db-network: '$n' is not a Docker network name"
done

# ── CrowdSec: settings ──────────────────────────────────────────────────────
# Everything is kept in .env, so a later run without CrowdSec flags leaves it
# exactly as it was. Enabled means COMPOSE_PROFILES=crowdsec there, which is
# what makes Compose start its two services at all.
CROWDSEC_WAS_ON=""
[[ "$(env_value COMPOSE_PROFILES)" == *crowdsec* ]] && CROWDSEC_WAS_ON=1
case "$CROWDSEC_MODE" in
  on)  CROWDSEC_ON=1 ;;
  off) CROWDSEC_ON="" ;;
  *)   CROWDSEC_ON="$CROWDSEC_WAS_ON" ;;
esac

valid_ip_or_cidr() {
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/([0-9]|[12][0-9]|3[0-2]))?$ ]] \
    || [[ "$1" == *:* && "$1" =~ ^[0-9a-fA-F:]+(/[0-9]{1,3})?$ ]]
}

# Addresses whoever is running this is logged in from over SSH. sudo drops
# SSH_CLIENT from the environment, so `who` is the reliable source; both are
# tried. Never banning the person who just turned the firewall on is the one
# lockout that matters most.
admin_ips() {
  [[ -n "${SSH_CLIENT:-}" ]] && echo "${SSH_CLIENT%% *}"
  who 2>/dev/null | awk -v u="${SUDO_USER:-$(logname 2>/dev/null || true)}" \
    '$1 == u && match($0, /\(([0-9a-fA-F.:]+)\)/) { print substr($0, RSTART + 1, RLENGTH - 2) }'
}

CROWDSEC_WHITELIST=""
CROWDSEC_AUTO_WHITELISTED=""
if [[ -n "$CROWDSEC_ON" ]]; then
  entries=()
  IFS=',' read -r -a entries <<<"$(env_value CROWDSEC_WHITELIST)"
  for arg in "${CROWDSEC_WHITELIST_ARGS[@]+"${CROWDSEC_WHITELIST_ARGS[@]}"}"; do
    IFS=',' read -r -a more <<<"$arg"
    for e in "${more[@]+"${more[@]}"}"; do
      e="${e//[[:space:]]/}"
      [[ -n "$e" ]] || continue
      valid_ip_or_cidr "$e" || die "--crowdsec-whitelist: '$e' is not an IP address or CIDR range"
      entries+=("$e")
    done
  done
  while read -r ip; do
    [[ -n "$ip" ]] && valid_ip_or_cidr "$ip" || continue
    [[ ",$(IFS=,; echo "${entries[*]+"${entries[*]}"}")," == *",$ip,"* ]] && continue
    entries+=("$ip")
    CROWDSEC_AUTO_WHITELISTED="$CROWDSEC_AUTO_WHITELISTED $ip"
  done < <(admin_ips | sort -u)
  CROWDSEC_WHITELIST="$(printf '%s\n' "${entries[@]+"${entries[@]}"}" | grep -v '^$' | sort -u | paste -sd, - || true)"

  # The bouncer's key for CrowdSec's local API: made once, then kept.
  CROWDSEC_BOUNCER_KEY="$(env_value CROWDSEC_BOUNCER_KEY)"
  [[ -n "$CROWDSEC_BOUNCER_KEY" ]] \
    || CROWDSEC_BOUNCER_KEY="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"

  # The local API is published on the host's loopback for the bouncer, so
  # its port must be free there. Keep the one already in use; otherwise take
  # the first free one from 8089.
  CROWDSEC_LAPI_PORT="$(env_value CROWDSEC_LAPI_PORT)"
  if [[ -z "$CROWDSEC_LAPI_PORT" ]]; then
    for port in $(seq 8089 8099); do
      if ! (command -v ss >/dev/null && ss -ltnH "sport = :$port" | grep -q .); then
        CROWDSEC_LAPI_PORT=$port
        break
      fi
    done
    [[ -n "$CROWDSEC_LAPI_PORT" ]] || die "no free port between 8089 and 8099 for CrowdSec's local API"
  fi

  # Dokploy's Traefik writes its access log to a file rather than stdout.
  CROWDSEC_TRAEFIK_DIR=""
  [[ -f /etc/dokploy/traefik/dynamic/access.log ]] && CROWDSEC_TRAEFIK_DIR=/etc/dokploy/traefik/dynamic
else
  # Off: keep the settings, so turning it back on later restores the same
  # whitelist and key rather than starting over.
  CROWDSEC_WHITELIST="$(env_value CROWDSEC_WHITELIST)"
  CROWDSEC_BOUNCER_KEY="$(env_value CROWDSEC_BOUNCER_KEY)"
  CROWDSEC_LAPI_PORT="$(env_value CROWDSEC_LAPI_PORT)"
  CROWDSEC_TRAEFIK_DIR="$(env_value CROWDSEC_TRAEFIK_DIR)"
fi

# ── Fetch config ────────────────────────────────────────────────────────────
mkdir -p "$INSTALL_DIR"

# Where did this script come from? Piped through `curl | bash` there is no
# file on disk at all, and BASH_SOURCE is unset — which `set -u` treats as a
# fatal error. Resolve it only when it really points at a file; anything else
# leaves SCRIPT_DIR empty so `fetch` downloads instead. The previous form fell
# back to $PWD, which would silently install a stray config.alloy sitting in
# whatever directory the client happened to run from.
SCRIPT_SRC="${BASH_SOURCE[0]:-}"
if [[ -n "$SCRIPT_SRC" && -f "$SCRIPT_SRC" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_SRC")" && pwd)"
else
  SCRIPT_DIR=""
fi

fetch() {
  local name="$1"
  # Running from a git checkout? Use the local file so you can test changes
  # before pushing them.
  if [[ -n "$SCRIPT_DIR" && -f "$SCRIPT_DIR/$name" ]]; then
    info "using local $name"
    mkdir -p "$(dirname "$INSTALL_DIR/$name")"
    cp "$SCRIPT_DIR/$name" "$INSTALL_DIR/$name"
  else
    info "downloading $name"
    mkdir -p "$(dirname "$INSTALL_DIR/$name")"
    curl -fsSL "$RAW_BASE/$name" -o "$INSTALL_DIR/$name" \
      || die "could not download $name from $RAW_BASE
  If the repository is private, raw.githubusercontent.com returns 404 for
  every unauthenticated request. Either run this from a git checkout, or
  pass --raw-base pointing somewhere this host can actually read."
  fi
}

fetch config.alloy
fetch databases.alloy
fetch crowdsec.alloy
fetch docker-compose.yml
fetch crowdsec/Dockerfile
fetch crowdsec/firewall-bouncer.yaml

# ── Credentials ─────────────────────────────────────────────────────────────
umask 077
cat > "$INSTALL_DIR/.env" <<ENVEOF
CLIENT_ID=$CLIENT_ID
HOST_NAME=$HOST_NAME
INGEST_URL=$INGEST_URL
INGEST_PASSWORD=$INGEST_PASSWORD
JOURNAL_DIR=$JOURNAL_DIR
ENVEOF
[[ -z "$CROWDSEC_ON" ]] || echo "COMPOSE_PROFILES=crowdsec" >> "$INSTALL_DIR/.env"
if [[ -n "$CROWDSEC_BOUNCER_KEY" ]]; then
  cat >> "$INSTALL_DIR/.env" <<ENVEOF
CROWDSEC_BOUNCER_KEY=$CROWDSEC_BOUNCER_KEY
CROWDSEC_WHITELIST=$CROWDSEC_WHITELIST
CROWDSEC_LAPI_PORT=$CROWDSEC_LAPI_PORT
CROWDSEC_TRAEFIK_DIR=$CROWDSEC_TRAEFIK_DIR
ENVEOF
fi
chmod 600 "$INSTALL_DIR/.env"

# ── CrowdSec: what to read ──────────────────────────────────────────────────
# Written every run, used only when it is on. Every source is optional: a
# host without a journal, Traefik or nginx simply has less to read.
mkdir -p "$INSTALL_DIR/crowdsec/no-traefik"
{
  echo "# Written by install.sh: the logs CrowdSec reads on this host."
  if [[ "$JOURNAL_DIR" != "$INSTALL_DIR/no-journal" ]]; then
    cat <<'ACQEOF'
# sshd, from the host's journal. OpenSSH 9.8+ logs as sshd-session.
source: journalctl
journalctl_filter:
  - "_COMM=sshd"
  - "_COMM=sshd-session"
labels:
  type: syslog
---
ACQEOF
  fi
  cat <<'ACQEOF'
# Reverse proxies logging to stdout, by container name.
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
ACQEOF
  if [[ -n "${CROWDSEC_TRAEFIK_DIR:-}" ]]; then
    cat <<'ACQEOF'
---
# Dokploy's Traefik access log.
source: file
filenames:
  - /var/log/traefik/access.log
labels:
  type: traefik
ACQEOF
  fi
} > "$INSTALL_DIR/crowdsec/acquis.yaml"

# ── Databases ───────────────────────────────────────────────────────────────
mkdir -p "$DB_DIR"
chmod 700 "$DB_DIR"

for n in "${DB_REMOVE[@]+"${DB_REMOVE[@]}"}"; do
  if [[ -f "$DB_DIR/$n.url" ]]; then
    rm -f "$DB_DIR/$n.url"
    info "database $n: removed"
  else
    echo "warning: --remove-db $n: no database of that name on this host" >&2
  fi
done
for i in "${!ADD_NAMES[@]}"; do
  printf '%s\n' "${ADD_URLS[$i]}" > "$DB_DIR/${ADD_NAMES[$i]}.url"
  info "database ${ADD_NAMES[$i]}: $(db_engine "$(parse_url "${ADD_URLS[$i]}"; echo "$U_SCHEME")")"
done
if [[ ${#DB_NETWORKS[@]} -gt 0 ]]; then
  printf '%s\n' "${DB_NETWORKS[@]}" >> "$DB_DIR/networks"
fi

# Rebuild everything derived from db-connections/ from scratch, so a removed
# database leaves no secret or component behind. Empty the directory rather
# than replacing it: a running agent has this exact directory bind-mounted,
# and a new one in its place would be invisible to it.
mkdir -p "$INSTALL_DIR/db-secrets"
chmod 700 "$INSTALL_DIR/db-secrets"
find "$INSTALL_DIR/db-secrets" -mindepth 1 -delete
cat > "$INSTALL_DIR/connections.alloy" <<'ALLOYEOF'
// Written by install.sh from db-connections/ — edit with --db / --remove-db.
// Each block is one of the components in databases.alloy.
ALLOYEOF

declare -A DB_ENGINES=() DB_LABELS=()
DB_AUTO_NETWORKS=(); DB_LOCAL_NAMES=(); DB_ALL=()
for f in "$DB_DIR"/*.url; do
  [[ -e "$f" ]] || continue
  name="$(basename "$f" .url)"
  build_db "$name" "$(head -n 1 "$f")"
  DB_ALL+=("$name")
done

if [[ -n "$CROWDSEC_ON" ]]; then
  cat >> "$INSTALL_DIR/connections.alloy" <<'ALLOYEOF'

crowdsec_metrics "local" {
  forward_to = [prometheus.remote_write.central.receiver]
}
ALLOYEOF
fi

# Networks to join: those found for each database plus any given by hand.
# One that no longer exists would stop `docker compose up`, so skip it loudly.
JOIN=()
while read -r net; do
  [[ -n "$net" ]] || continue
  if docker network inspect "$net" >/dev/null 2>&1; then
    JOIN+=("$net")
  else
    echo "warning: Docker network '$net' does not exist; not joining it" >&2
  fi
done < <({ printf '%s\n' "${DB_AUTO_NETWORKS[@]+"${DB_AUTO_NETWORKS[@]}"}"; cat "$DB_DIR/networks" 2>/dev/null; } | sort -u)

if [[ ${#JOIN[@]} -gt 0 ]]; then
  info "joining Docker network(s) to reach databases: ${JOIN[*]}"
  {
    echo "# Written by install.sh: the networks the agent joins to reach databases."
    echo "services:"
    echo "  alloy:"
    echo "    networks:"
    echo "      - default"
    for net in "${JOIN[@]}"; do echo "      - \"$net\""; done
    echo "networks:"
    for net in "${JOIN[@]}"; do
      echo "  \"$net\":"
      echo "    external: true"
    done
  } > "$INSTALL_DIR/docker-compose.override.yml"
else
  rm -f "$INSTALL_DIR/docker-compose.override.yml"
fi

# ── Start ───────────────────────────────────────────────────────────────────
info "starting agent"
cd "$INSTALL_DIR"
STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
# The bouncer is built here, not pulled, so leave it out of the pull.
docker compose pull --quiet --ignore-buildable 2>/dev/null \
  || docker compose pull --ignore-pull-failures
# Turned off: remove CrowdSec's containers. Compose would otherwise leave
# them running, since a service outside the active profiles is not an
# orphan. Stopping the bouncer removes its firewall rules; its volumes are
# kept, so turning it back on resumes with the same decisions.
if [[ -n "$CROWDSEC_WAS_ON" && -z "$CROWDSEC_ON" ]]; then
  info "turning CrowdSec off"
  COMPOSE_PROFILES=crowdsec docker compose rm --stop --force crowdsec crowdsec-firewall-bouncer
fi
# Always recreate. Alloy does not watch its config files, and Compose leaves
# a container alone when its definition is unchanged — so without this a
# re-run with new databases, or a new config.alloy, would change nothing.
# --build builds the CrowdSec bouncer when that is on, and rebuilds it when
# its Dockerfile changed.
#
# Not fatal: if CrowdSec fails to become healthy, its bouncer cannot start
# and `up` exits non-zero, but the agent itself is running. The checks below
# report exactly what failed instead of the installer stopping here.
docker compose up -d --remove-orphans --force-recreate --build \
  || echo "warning: not every service started; see the checks below" >&2

# ── Verify ──────────────────────────────────────────────────────────────────
info "waiting for the agent to settle"
sleep 12

if ! docker ps --filter name=grafana-prometheus-loki-agent --filter status=running --format '{{.Names}}' \
     | grep -q grafana-prometheus-loki-agent; then
  echo >&2
  echo "The agent is not running. Recent logs:" >&2
  docker compose logs --tail 40 >&2
  die "agent failed to start"
fi

# Alloy logs a remote_write error on every failed push, so this catches a
# wrong password or a firewall immediately instead of a day later. Database
# components are left out: a wrong database password also says
# "authentication", and is reported separately below.
if docker compose logs --tail 200 alloy 2>/dev/null | grep -v 'component_path=/database_' \
     | grep -qiE 'non-recoverable error.*(401|403)|authentication'; then
  echo >&2
  echo "The agent started but the ingest gateway rejected its credentials." >&2
  echo "Check that '$CLIENT_ID' exists in the central INGEST_USERS and that the" >&2
  echo "password matches, then re-run this installer." >&2
  exit 1
fi

# Each exporter first connects on its first scrape, within 30 seconds of the
# start. Wait for that, then report every database: a typo in a password is
# far cheaper to fix now than when DatabaseDown fires tonight.
DB_FAILED=0
if [[ ${#DB_ALL[@]} -gt 0 ]]; then
  info "checking database connections"
  sleep 35
  logs="$(docker compose logs --since "$STARTED_AT" alloy 2>/dev/null | grep 'level=error' \
          | grep -v 'was collected before' || true)"
  for name in "${DB_ALL[@]}"; do
    engine="${DB_ENGINES[$name]}"
    err="$(grep -F "component_path=/database_$engine.${DB_LABELS[$name]} " <<<"$logs" | tail -n 1 \
           | sed -nE 's/.* (err|error)="((\\.|[^"\\])*)".*/\2/p' | sed 's/\\"/"/g' | cut -c1-200 || true)"
    if [[ -z "$err" ]]; then
      echo "  ok      $name ($engine)"
    else
      DB_FAILED=1
      echo "  FAILING $name ($engine): $err"
      for l in "${DB_LOCAL_NAMES[@]+"${DB_LOCAL_NAMES[@]}"}"; do
        [[ "$l" != "$name" ]] || echo "          reached as host.docker.internal: the database must listen on the Docker bridge, not only on 127.0.0.1"
      done
    fi
  done
fi

# CrowdSec: wait until its local API answers, bring the allowlist in line
# with CROWDSEC_WHITELIST, then confirm the bouncer is actually pulling
# decisions. Detection without a working bouncer blocks nothing, and that is
# easy to miss.
CROWDSEC_FAILED=0
if [[ -n "$CROWDSEC_ON" ]]; then
  info "checking CrowdSec"
  cs() { docker exec grafana-prometheus-loki-crowdsec cscli "$@"; }
  for _ in $(seq 60); do cs lapi status >/dev/null 2>&1 && break; sleep 3; done
  if ! cs lapi status >/dev/null 2>&1; then
    CROWDSEC_FAILED=1
    echo "  FAILING crowdsec: its local API did not come up. docker logs grafana-prometheus-loki-crowdsec"
  else
    # Recreated from scratch each run, so a removed address really goes.
    # An allowlist covers every source of decisions: this host's own
    # detections, the community blocklist, the console and cscli.
    cs allowlists delete grafana-prometheus-loki >/dev/null 2>&1 || true
    cs allowlists create grafana-prometheus-loki -d "Never block: install.sh --crowdsec-whitelist" >/dev/null
    if [[ -n "$CROWDSEC_WHITELIST" ]]; then
      # shellcheck disable=SC2046
      cs allowlists add grafana-prometheus-loki $(tr ',' ' ' <<<"$CROWDSEC_WHITELIST") -d "install.sh" >/dev/null
    fi
    echo "  ok      crowdsec: detecting, never blocking: ${CROWDSEC_WHITELIST:-nothing whitelisted}"
    [[ -z "$CROWDSEC_AUTO_WHITELISTED" ]] \
      || echo "          (whitelisted automatically, you are connected from:$CROWDSEC_AUTO_WHITELISTED)"

    # Console enrollment happens once, when a key is given. A bad key is a
    # warning, not a failure: CrowdSec protects the host either way.
    if [[ -n "$CROWDSEC_ENROLL_ARG" ]]; then
      if out="$(cs console enroll --overwrite --name "$HOST_NAME" --tags "$CLIENT_ID" "$CROWDSEC_ENROLL_ARG" 2>&1)"; then
        docker restart grafana-prometheus-loki-crowdsec >/dev/null
        for _ in $(seq 60); do cs lapi status >/dev/null 2>&1 && break; sleep 3; done
        echo "  ok      console: enrollment sent; accept '$HOST_NAME' at app.crowdsec.net"
      else
        echo "  WARNING console: enrollment failed, CrowdSec runs without it: $(tail -n 1 <<<"$out" | cut -c1-160)"
      fi
    fi

    # Register the bouncer under the key in .env, every run. CrowdSec keeps
    # an existing registration when it restarts, so if the key ever changes
    # (a lost .env, a reset volume) the bouncer would be refused for good.
    cs bouncers delete firewall >/dev/null 2>&1 || true
    cs bouncers add firewall --key "$CROWDSEC_BOUNCER_KEY" >/dev/null
    docker restart grafana-prometheus-loki-crowdsec-bouncer >/dev/null 2>&1 || true

    # A pull from before this run proves nothing, so compare against the
    # start time. Both are UTC ISO 8601, which sorts as text.
    pulled=""
    for _ in $(seq 20); do
      last="$(cs bouncers list -o raw 2>/dev/null | awk -F, '$1 == "firewall" { print $4 }')"
      if [[ -n "$last" && ! "$last" < "$STARTED_AT" ]]; then
        pulled=1; break
      fi
      sleep 3
    done
    if [[ -n "$pulled" ]]; then
      echo "  ok      firewall bouncer: pulling decisions, blocking in nftables"
    else
      CROWDSEC_FAILED=1
      echo "  FAILING firewall bouncer: has not contacted CrowdSec. docker logs grafana-prometheus-loki-crowdsec-bouncer"
    fi
  fi
fi

echo
info "done — $HOST_NAME is reporting as client '$CLIENT_ID'"
echo
echo "  logs:     docker compose -f $INSTALL_DIR/docker-compose.yml logs -f"
echo "  restart:  docker compose -f $INSTALL_DIR/docker-compose.yml restart"
echo "  remove:   docker compose -f $INSTALL_DIR/docker-compose.yml down -v && rm -rf $INSTALL_DIR"
echo
if [[ "$DB_FAILED" -ne 0 ]]; then
  echo "Fix the failing database with --db <name>=<corrected url>, or drop it with --remove-db <name>."
  echo
fi
if [[ "$CROWDSEC_FAILED" -ne 0 ]]; then
  echo "CrowdSec is not protecting this host yet. Its logs say why; re-run this installer"
  echo "once fixed, or turn it off with --no-crowdsec."
  echo
fi
