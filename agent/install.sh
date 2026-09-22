#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# grafana-prometheus-loki agent installer — an optional helper.
#
# The agent is configured entirely by docker-compose.yml plus a .env (see the
# top of docker-compose.yml); you can deploy it that way yourself, with
# Dokploy or by hand. This script writes that same .env for you and runs
# Compose, and adds what a script can do better: it finds the host's journal
# and the Docker networks your databases are on, whitelists the address you
# are connected from, validates everything before changing anything, and
# checks the result.
#
#   sudo ./install.sh --client acme --ingest https://ingest.example.com --password 'secret'
#
# Re-running is how you change anything: settings you do not pass keep their
# current value.
#
#   sudo ./install.sh --db app=postgres://monitor:pw@app-db:5432/app
#   sudo ./install.sh --crowdsec --crowdsec-whitelist 203.0.113.7
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

INSTALL_DIR=/opt/grafana-prometheus-loki-agent
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/ThomasGerr/GrafanaPrometheusLoki/main/agent}"
AGENT=grafana-prometheus-loki-agent

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
BACKUP_MODE=""                # on, off, or empty to keep what the host has
BACKUP_REPO_ARG=""
BACKUP_PASSWORD_ARG=""
BACKUP_PATHS_ARG=""
BACKUP_VOLUMES_ARG=""
BACKUP_SCHEDULE_ARG=""
BACKUP_ENV_ARGS=()

die() { echo "error: $*" >&2; exit 1; }
info() { echo "==> $*"; }

usage() {
  cat >&2 <<USAGE
Usage: install.sh [--client <id>] [--ingest <url>] [--password <password>] [--host <name>]
                  [--db [name=]<url>]... [--remove-db <name>]... [--db-network <network>]...
                  [--crowdsec | --no-crowdsec] [--crowdsec-enroll-key <key>]
                  [--crowdsec-whitelist <ip or cidr,...>]
                  [--backup | --no-backup] [--backup-repository <restic repo>]
                  [--backup-password <password>] [--backup-paths <path,...>]
                  [--backup-volumes] [--backup-schedule <cron>] [--backup-env KEY=VALUE]...

  --client    Client id, exactly as it appears in the central clients.yml
  --ingest    Ingest gateway URL, e.g. https://ingest.example.com
  --password  This client's password from the central INGEST_USERS variable
  --host      Name for this server in dashboards (default: this machine's hostname)
  --raw-base  Where to download the agent's files from, when this script is
              not run from a checkout of the repository.

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

Backups with restic (host paths, Docker volumes, a dump of every database):
  --backup              Turn them on. Stays on for later runs until --no-backup.
  --no-backup           Turn them off. The repository and its snapshots stay.
  --backup-repository   Where they go, as restic expects it: s3:https://…/bucket,
                        b2:bucket:path, sftp:user@host:/path, rest:https://…
  --backup-password     The repository's password. Generated if there is none
                        yet, and printed once: without it the backups are lost.
  --backup-paths        Host directories to back up, comma-separated: /etc,/opt
  --backup-volumes      Also back up every Docker volume.
  --backup-schedule     When, as a cron line in UTC (default: 0 3 * * *).
  --backup-env          A variable the storage needs, e.g. its credentials:
                        --backup-env AWS_ACCESS_KEY_ID=… (repeatable)

Settings not given keep their current value: from this host's install, or
from an agent that was started with docker compose by hand, which this
script then takes over.
USAGE
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --client)     CLIENT_ID="${2:-}";       shift 2 ;;
    --ingest)     INGEST_URL="${2:-}";      shift 2 ;;
    --password)   INGEST_PASSWORD="${2:-}"; shift 2 ;;
    --host)       HOST_NAME="${2:-}";       shift 2 ;;
    --raw-base)   RAW_BASE="${2:-}";        shift 2 ;;
    --db)         DB_ADD+=("${2:-}");       shift 2 ;;
    --remove-db)  DB_REMOVE+=("${2:-}");    shift 2 ;;
    --db-network) DB_NETWORKS+=("${2:-}");  shift 2 ;;
    --crowdsec)            CROWDSEC_MODE=on;  shift ;;
    --no-crowdsec)         CROWDSEC_MODE=off; shift ;;
    --crowdsec-enroll-key) CROWDSEC_ENROLL_ARG="${2:-}"; CROWDSEC_MODE="${CROWDSEC_MODE:-on}"; shift 2 ;;
    --crowdsec-whitelist)  CROWDSEC_WHITELIST_ARGS+=("${2:-}"); shift 2 ;;
    --backup)              BACKUP_MODE=on;  shift ;;
    --no-backup)           BACKUP_MODE=off; shift ;;
    --backup-repository)   BACKUP_REPO_ARG="${2:-}";     BACKUP_MODE="${BACKUP_MODE:-on}"; shift 2 ;;
    --backup-password)     BACKUP_PASSWORD_ARG="${2:-}"; shift 2 ;;
    --backup-paths)        BACKUP_PATHS_ARG="${2:-}";    shift 2 ;;
    --backup-volumes)      BACKUP_VOLUMES_ARG=true;      shift ;;
    --backup-schedule)     BACKUP_SCHEDULE_ARG="${2:-}"; shift 2 ;;
    --backup-env)          BACKUP_ENV_ARGS+=("${2:-}");  shift 2 ;;
    -h|--help)    usage ;;
    *)            die "unknown option: $1" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "run as root (use sudo)"
command -v docker >/dev/null 2>&1 || die "docker is not installed"
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is not installed"

# ── Current settings ────────────────────────────────────────────────────────
# All settings live in one .env, the same file you would write by hand. Read
# it as data; never source it.
ENV_FILE="$INSTALL_DIR/.env"

# Compose expands $ in unquoted .env values, so a password with a $ in it
# would be silently mangled. Values that need it are single-quoted, which
# Compose takes literally; a value with a ' in it cannot be, so refuse it.
env_line() {
  local key="$1" value="$2"
  if [[ "$value" =~ [\$\ \#\"\\] ]]; then
    [[ "$value" != *"'"* ]] || die "$key contains both a ' and characters that need quoting; percent-encode it"
    echo "$key='$value'"
  else
    echo "$key=$value"
  fi
}
unquote() {
  local v="$1"
  if [[ "$v" =~ ^\'(.*)\'$ || "$v" =~ ^\"(.*)\"$ ]]; then v="${BASH_REMATCH[1]}"; fi
  printf '%s' "$v"
}

declare -A CUR=()
if [[ -f "$ENV_FILE" ]]; then
  while IFS='=' read -r key value; do
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] && CUR["$key"]="$(unquote "$value")"
  done < "$ENV_FILE"
fi

# An agent started with docker compose somewhere else (by hand, or as a
# Dokploy app) has its settings in its container's environment. Take them
# over, so the flags you did not pass keep working, and replace it below.
ADOPT_DIR=""
if [[ ! -f "$ENV_FILE" ]] && docker inspect "$AGENT" >/dev/null 2>&1; then
  ADOPT_DIR="$(docker inspect "$AGENT" -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}')"
  while IFS='=' read -r key value; do
    [[ "$key" =~ ^(CLIENT_ID|HOST_NAME|INGEST_URL|INGEST_PASSWORD|JOURNAL_DIR|AGENT_DB_NETWORK|COMPOSE_PROFILES|CROWDSEC_[A-Z_]+|RESTIC_[A-Z_]+|BACKUP_[A-Za-z0-9_]+|DB_[A-Za-z0-9_]+)$ ]] \
      && CUR["$key"]="$value"
  done < <(docker inspect "$AGENT" -f '{{range .Config.Env}}{{println .}}{{end}}')
  info "taking over the agent started from ${ADOPT_DIR:-an unknown directory}"
fi

# Older installs kept each database URL in db-connections/<name>.url.
if [[ -d "$INSTALL_DIR/db-connections" ]]; then
  for f in "$INSTALL_DIR"/db-connections/*.url; do
    [[ -e "$f" ]] || continue
    n="$(basename "$f" .url)"; n="${n^^}"
    CUR["DB_${n//-/_}"]="$(head -n 1 "$f")"
  done
fi

CLIENT_ID="${CLIENT_ID:-${CUR[CLIENT_ID]:-}}"
INGEST_URL="${INGEST_URL:-${CUR[INGEST_URL]:-}}"
INGEST_PASSWORD="${INGEST_PASSWORD:-${CUR[INGEST_PASSWORD]:-}}"
HOST_NAME="${HOST_NAME:-${CUR[HOST_NAME]:-$(hostname -s 2>/dev/null || hostname)}}"

missing=()
[[ -n "$CLIENT_ID" ]]       || missing+=(--client)
[[ -n "$INGEST_URL" ]]      || missing+=(--ingest)
[[ -n "$INGEST_PASSWORD" ]] || missing+=(--password)
if [[ ${#missing[@]} -gt 0 ]]; then
  die "missing ${missing[*]}
  No agent is installed on this host yet, so the first run needs them all:
    install.sh --client <id> --ingest <url> --password <password> [other options]
  Later runs remember them. See install.sh --help."
fi

# The client id becomes a metric label, a Loki tenant and a username. Catch a
# typo here rather than after a week of data has landed under the wrong name.
[[ "$CLIENT_ID" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || die "client id '$CLIENT_ID' must match [a-z0-9][a-z0-9_-]*"
INGEST_URL="${INGEST_URL%/}"
# Compose needs these before .env is written, for the validation build.
export CLIENT_ID HOST_NAME INGEST_URL INGEST_PASSWORD
[[ "$INGEST_URL" =~ ^https:// ]] \
  || echo "warning: ingest URL is not https — credentials will cross the network in the clear" >&2

# Where does journald keep its logs? Never mount a path that does not exist:
# Docker would create it, and an empty /var/log/journal quietly switches
# journald to on-disk storage.
if [[ -d /var/log/journal ]]; then
  JOURNAL_DIR=/var/log/journal
elif [[ -d /run/log/journal ]]; then
  JOURNAL_DIR=/run/log/journal
else
  JOURNAL_DIR="$INSTALL_DIR/no-journal"
  mkdir -p "$JOURNAL_DIR"
  echo "warning: no systemd journal found — system logs and security alerts will not work on this host" >&2
fi

# ── Databases ───────────────────────────────────────────────────────────────
# --db name=url becomes DB_NAME=url in .env, exactly what you would write.
# Without a name, the host's first label is used: …@app-db:5432 → app-db.
db_var() { local n="${1^^}"; echo "DB_${n//-/_}"; }

declare -A DBS=()
for key in "${!CUR[@]}"; do [[ "$key" == DB_* ]] && DBS["$key"]="${CUR[$key]}"; done
for n in "${DB_REMOVE[@]+"${DB_REMOVE[@]}"}"; do
  [[ "$n" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "--remove-db: '$n' is not a database name"
  if [[ -n "${DBS[$(db_var "$n")]+x}" ]]; then
    unset "DBS[$(db_var "$n")]"; info "database $n: removed"
  else
    echo "warning: --remove-db $n: no database of that name on this host" >&2
  fi
done
ADDED=()
for arg in "${DB_ADD[@]+"${DB_ADD[@]}"}"; do
  if [[ "$arg" =~ ^([a-zA-Z0-9-]+)=(.+)$ ]]; then
    name="${BASH_REMATCH[1],,}"; url="${BASH_REMATCH[2]}"
  else
    url="$arg"
    [[ "$url" =~ ^[a-zA-Z][a-zA-Z0-9+.-]*://([^@]*@)?\[?([^]/:?@,]+) ]] \
      || die "--db: not a connection URL (expected scheme://user:password@host:port)"
    name="${BASH_REMATCH[2]%%.*}"; name="${name,,}"; name="${name//[^a-z0-9-]/-}"
    [[ "$name" =~ ^(localhost|127-0-0-1|--1)$ ]] && name="${url%%:*}"
  fi
  [[ "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "database name '$name' must be lowercase letters, digits and -"
  for a in "${ADDED[@]+"${ADDED[@]}"}"; do
    [[ "$a" != "$name" ]] || die "two --db flags are both called '$name'; name them: --db other=…"
  done
  ADDED+=("$name")
  DBS["$(db_var "$name")"]="$url"
done
for n in "${DB_NETWORKS[@]+"${DB_NETWORKS[@]}"}"; do
  [[ "$n" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] || die "--db-network: '$n' is not a Docker network name"
done

# ── CrowdSec settings ───────────────────────────────────────────────────────
CROWDSEC_WAS_ON=""
[[ ",${CUR[COMPOSE_PROFILES]:-}," == *,crowdsec,* ]] && CROWDSEC_WAS_ON=1
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
# SSH_CLIENT, so `who` is the reliable source; both are tried. Never banning
# the person who just turned the firewall on is the lockout that matters most.
admin_ips() {
  [[ -n "${SSH_CLIENT:-}" ]] && echo "${SSH_CLIENT%% *}"
  who 2>/dev/null | awk -v u="${SUDO_USER:-$(logname 2>/dev/null || true)}" \
    '$1 == u && match($0, /\(([0-9a-fA-F.:]+)\)/) { print substr($0, RSTART + 1, RLENGTH - 2) }'
}

# Kept even while CrowdSec is off, so turning it back on restores them.
CROWDSEC_WHITELIST="${CUR[CROWDSEC_WHITELIST]:-}"
CROWDSEC_BOUNCER_KEY="${CUR[CROWDSEC_BOUNCER_KEY]:-}"
CROWDSEC_ENROLL_KEY="${CROWDSEC_ENROLL_ARG:-${CUR[CROWDSEC_ENROLL_KEY]:-}}"
CROWDSEC_LAPI_PORT="${CUR[CROWDSEC_LAPI_PORT]:-}"
CROWDSEC_TRAEFIK_DIR="${CUR[CROWDSEC_TRAEFIK_DIR]:-}"
AUTO_WHITELISTED=""
if [[ -n "$CROWDSEC_ON" ]]; then
  entries=()
  IFS=',' read -r -a entries <<<"$CROWDSEC_WHITELIST"
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
    entries+=("$ip"); AUTO_WHITELISTED="$AUTO_WHITELISTED $ip"
  done < <(admin_ips | sort -u)
  CROWDSEC_WHITELIST="$(printf '%s\n' "${entries[@]+"${entries[@]}"}" | grep -v '^$' | sort -u | paste -sd, - || true)"

  [[ -n "$CROWDSEC_BOUNCER_KEY" ]] \
    || CROWDSEC_BOUNCER_KEY="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"

  # The local API is published on the host's loopback for the bouncer, so
  # its port must be free there. Keep the current one, else the first free
  # one from 8089.
  if [[ -z "$CROWDSEC_LAPI_PORT" ]]; then
    for port in $(seq 8089 8099); do
      if ! (command -v ss >/dev/null && ss -ltnH "sport = :$port" | grep -q .); then
        CROWDSEC_LAPI_PORT=$port; break
      fi
    done
    [[ -n "$CROWDSEC_LAPI_PORT" ]] || die "no free port between 8089 and 8099 for CrowdSec's local API"
  fi
  # Dokploy's Traefik writes its access log to a file rather than stdout.
  [[ -n "$CROWDSEC_TRAEFIK_DIR" || ! -f /etc/dokploy/traefik/dynamic/access.log ]] \
    || CROWDSEC_TRAEFIK_DIR=/etc/dokploy/traefik/dynamic
fi

# ── Backup settings ─────────────────────────────────────────────────────────
BACKUP_WAS_ON=""
[[ ",${CUR[COMPOSE_PROFILES]:-}," == *,backup,* ]] && BACKUP_WAS_ON=1
case "$BACKUP_MODE" in
  on)  BACKUP_ON=1 ;;
  off) BACKUP_ON="" ;;
  *)   BACKUP_ON="$BACKUP_WAS_ON" ;;
esac
# Kept even while backups are off: the password above all, since without it
# the existing snapshots cannot be read.
RESTIC_REPOSITORY="${BACKUP_REPO_ARG:-${CUR[RESTIC_REPOSITORY]:-}}"
RESTIC_PASSWORD="${BACKUP_PASSWORD_ARG:-${CUR[RESTIC_PASSWORD]:-}}"
BACKUP_PATHS="${BACKUP_PATHS_ARG:-${CUR[BACKUP_PATHS]:-}}"
BACKUP_DOCKER_VOLUMES="${BACKUP_VOLUMES_ARG:-${CUR[BACKUP_DOCKER_VOLUMES]:-}}"
BACKUP_SCHEDULE="${BACKUP_SCHEDULE_ARG:-${CUR[BACKUP_SCHEDULE]:-}}"
declare -A BACKUP_ENV=()
for kv in "${BACKUP_ENV_ARGS[@]+"${BACKUP_ENV_ARGS[@]}"}"; do
  [[ "$kv" =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]] || die "--backup-env: expected KEY=VALUE, got '${kv%%=*}…'"
  BACKUP_ENV["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
done
GENERATED_BACKUP_PASSWORD=""
if [[ -n "$BACKUP_ON" ]]; then
  [[ -n "$RESTIC_REPOSITORY" ]] || die "backups need --backup-repository: where restic stores them (see docs/backups.md)"
  if [[ -z "$RESTIC_PASSWORD" ]]; then
    RESTIC_PASSWORD="$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    GENERATED_BACKUP_PASSWORD=1
  fi
  for p in ${BACKUP_PATHS//,/ }; do
    [[ "$p" == /* ]] || die "--backup-paths: '$p' is not an absolute path"
  done
fi

info "client:  $CLIENT_ID"
info "host:    $HOST_NAME"
info "ingest:  $INGEST_URL"
info "journal: $JOURNAL_DIR"

# ── Fetch the agent ─────────────────────────────────────────────────────────
mkdir -p "$INSTALL_DIR"

# Run from a checkout of the repo: copy the files next to this script, so
# changes can be tested before they are pushed. Piped through `curl | bash`
# there is no file on disk and BASH_SOURCE is unset: download instead.
SCRIPT_SRC="${BASH_SOURCE[0]:-}"
SCRIPT_DIR=""
[[ -n "$SCRIPT_SRC" && -f "$SCRIPT_SRC" ]] && SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_SRC")" && pwd)"

fetch() {
  local name="$1"
  mkdir -p "$(dirname "$INSTALL_DIR/$name")"
  if [[ -n "$SCRIPT_DIR" && -f "$SCRIPT_DIR/$name" ]]; then
    cp "$SCRIPT_DIR/$name" "$INSTALL_DIR/$name"
  else
    curl -fsSL "$RAW_BASE/$name" -o "$INSTALL_DIR/$name" \
      || die "could not download $name from $RAW_BASE
  If the repository is private, raw.githubusercontent.com returns 404 for
  every unauthenticated request. Run this from a checkout of the repository
  instead, or pass --raw-base pointing somewhere this host can read."
  fi
}
for f in docker-compose.yml Dockerfile .dockerignore entrypoint.sh lib/db-url.sh \
         config.alloy databases.alloy crowdsec.alloy \
         backup/Dockerfile backup/backup.sh backup/backup-entrypoint.sh \
         crowdsec/engine.Dockerfile crowdsec/engine-start.sh crowdsec/bouncer.Dockerfile \
         crowdsec/firewall-bouncer.yaml crowdsec/.dockerignore; do
  fetch "$f"
done
mkdir -p "$INSTALL_DIR/crowdsec/no-traefik"
info "agent files in $INSTALL_DIR"

# ── Validate the databases, before anything changes ─────────────────────────
# With the agent's own start-up script, so there is one parser, not two.
cd "$INSTALL_DIR"
docker compose build --quiet alloy >/dev/null
DB_HOSTS=()
if [[ ${#DBS[@]} -gt 0 ]]; then
  env_args=()
  for key in "${!DBS[@]}"; do env_args+=(-e "$key=${DBS[$key]}"); done
  if ! check="$(docker run --rm "${env_args[@]}" grafana-prometheus-loki/agent check)"; then
    die "database settings rejected:
$(grep -v ': ok,' <<<"$check" | sed 's/^/  /')"
  fi
  while read -r h; do DB_HOSTS+=("$h"); done < <(sed -n 's/.* host=//p' <<<"$check")
fi

# ── Networks the databases are on ───────────────────────────────────────────
# A database in another container is reachable only on a network it shares
# with the agent. Try each host as a container name, a Compose service name
# and a Swarm service (Dokploy's own databases are Swarm services on
# dokploy-network). Prints one network per line.
networks_for() {
  local host="$1" ids id nets
  if nets=$(docker inspect --type container \
              -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$host" 2>/dev/null); then
    :
  elif ids=$(docker ps -q --filter "label=com.docker.compose.service=$host") && [[ -n "$ids" ]]; then
    nets=$(for id in $ids; do
             docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$id"
           done)
  elif ids=$(docker service inspect -f '{{range .Spec.TaskTemplate.Networks}}{{.Target}} {{end}}' "$host" 2>/dev/null); then
    nets=$(for id in $ids; do docker network inspect -f '{{.Name}}' "$id"; done)
  else
    return 0
  fi
  for id in $nets; do
    case "$id" in host|bridge|none) ;; *) echo "$id" ;; esac
  done
}
JOIN=()
while read -r net; do
  [[ -n "$net" ]] || continue
  if docker network inspect "$net" >/dev/null 2>&1; then
    JOIN+=("$net")
  else
    echo "warning: Docker network '$net' does not exist; not joining it" >&2
  fi
done < <({
  for h in "${DB_HOSTS[@]+"${DB_HOSTS[@]}"}"; do networks_for "$h"; done
  printf '%s\n' "${DB_NETWORKS[@]+"${DB_NETWORKS[@]}"}"
  tr ',' '\n' <<<"${CUR[AGENT_NETWORKS]:-}"
} | sort -u)
AGENT_NETWORKS="$(printf '%s\n' "${JOIN[@]+"${JOIN[@]}"}" | paste -sd, - || true)"

if [[ ${#JOIN[@]} -gt 0 ]]; then
  info "joining Docker network(s) to reach databases: ${JOIN[*]}"
  {
    echo "# Written by install.sh: the networks the agent joins to reach databases."
    echo "services:"
    for svc in alloy backup; do
      echo "  $svc:"
      echo "    networks:"
      echo "      - default"
      for net in "${JOIN[@]}"; do echo "      - \"$net\""; done
    done
    echo "networks:"
    for net in "${JOIN[@]}"; do printf '  "%s":\n    external: true\n' "$net"; done
  } > docker-compose.override.yml
else
  rm -f docker-compose.override.yml
fi

# ── Write .env ──────────────────────────────────────────────────────────────
# Lines this script does not manage (anything you added by hand) are kept.
MANAGED='^(CLIENT_ID|HOST_NAME|INGEST_URL|INGEST_PASSWORD|JOURNAL_DIR|AGENT_NETWORKS|COMPOSE_PROFILES|CROWDSEC_[A-Z_]+|DB_[A-Za-z0-9_]+|RESTIC_REPOSITORY|RESTIC_PASSWORD|BACKUP_PATHS|BACKUP_DOCKER_VOLUMES|BACKUP_SCHEDULE)='
umask 077
{
  echo "# Agent settings. Written by install.sh; editing by hand works too (then"
  echo "# run: docker compose up -d --build). See the top of docker-compose.yml."
  env_line CLIENT_ID "$CLIENT_ID"
  env_line HOST_NAME "$HOST_NAME"
  env_line INGEST_URL "$INGEST_URL"
  env_line INGEST_PASSWORD "$INGEST_PASSWORD"
  env_line JOURNAL_DIR "$JOURNAL_DIR"
  [[ -z "$AGENT_NETWORKS" ]] || echo "AGENT_NETWORKS=$AGENT_NETWORKS"
  for key in $(printf '%s\n' "${!DBS[@]}" | sort); do env_line "$key" "${DBS[$key]}"; done
  profiles=()
  [[ -z "$CROWDSEC_ON" ]] || profiles+=(crowdsec)
  [[ -z "$BACKUP_ON" ]] || profiles+=(backup)
  [[ ${#profiles[@]} -eq 0 ]] || echo "COMPOSE_PROFILES=$(IFS=,; echo "${profiles[*]}")"
  [[ -z "$RESTIC_REPOSITORY" ]]     || env_line RESTIC_REPOSITORY "$RESTIC_REPOSITORY"
  [[ -z "$RESTIC_PASSWORD" ]]       || env_line RESTIC_PASSWORD "$RESTIC_PASSWORD"
  [[ -z "$BACKUP_PATHS" ]]          || env_line BACKUP_PATHS "$BACKUP_PATHS"
  [[ -z "$BACKUP_DOCKER_VOLUMES" ]] || echo "BACKUP_DOCKER_VOLUMES=$BACKUP_DOCKER_VOLUMES"
  [[ -z "$BACKUP_SCHEDULE" ]]       || env_line BACKUP_SCHEDULE "$BACKUP_SCHEDULE"
  for key in $(printf '%s\n' "${!BACKUP_ENV[@]}" | sort); do env_line "$key" "${BACKUP_ENV[$key]}"; done
  [[ -z "$CROWDSEC_BOUNCER_KEY" ]] || echo "CROWDSEC_BOUNCER_KEY=$CROWDSEC_BOUNCER_KEY"
  [[ -z "$CROWDSEC_WHITELIST" ]]   || echo "CROWDSEC_WHITELIST=$CROWDSEC_WHITELIST"
  [[ -z "$CROWDSEC_ENROLL_KEY" ]]  || env_line CROWDSEC_ENROLL_KEY "$CROWDSEC_ENROLL_KEY"
  [[ -z "$CROWDSEC_LAPI_PORT" ]]   || echo "CROWDSEC_LAPI_PORT=$CROWDSEC_LAPI_PORT"
  [[ -z "$CROWDSEC_TRAEFIK_DIR" ]] || echo "CROWDSEC_TRAEFIK_DIR=$CROWDSEC_TRAEFIK_DIR"
  # Keys given with --backup-env replace their earlier value.
  extra="^($(IFS='|'; echo "${!BACKUP_ENV[*]+"${!BACKUP_ENV[*]}"}"))="
  [[ "$extra" != "^()=" ]] || extra='^$'
  [[ -f "$ENV_FILE" ]] && grep -vE "$MANAGED" "$ENV_FILE" | grep -vE "$extra" | grep -vE '^# (Agent settings|run: docker)' || true
} > "$ENV_FILE.new"
mv "$ENV_FILE.new" "$ENV_FILE"
chmod 600 "$ENV_FILE"

# Leftovers from older installs, which kept config and credentials in files.
rm -rf db-connections db-secrets connections.alloy crowdsec/acquis.yaml crowdsec/Dockerfile

# ── Start ───────────────────────────────────────────────────────────────────
STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# A hand-started agent holds the container name; make way for this one.
if [[ -n "$ADOPT_DIR" && "$ADOPT_DIR" != "$INSTALL_DIR" ]]; then
  docker rm -f "$AGENT" grafana-prometheus-loki-crowdsec grafana-prometheus-loki-crowdsec-bouncer grafana-prometheus-loki-backup >/dev/null 2>&1 || true
  echo "note: the old agent in $ADOPT_DIR is replaced. Delete that directory, or" >&2
  echo "      the Dokploy app it came from, so it is not started again." >&2
fi
# Turned off: Compose leaves a service outside the active profiles running,
# so remove CrowdSec's containers here. Stopping the bouncer removes its
# firewall rules; the volumes are kept, so turning it on again resumes.
if [[ -n "$CROWDSEC_WAS_ON" && -z "$CROWDSEC_ON" ]]; then
  info "turning CrowdSec off"
  COMPOSE_PROFILES=crowdsec docker compose rm --stop --force crowdsec crowdsec-firewall-bouncer
fi
if [[ -n "$BACKUP_WAS_ON" && -z "$BACKUP_ON" ]]; then
  info "turning backups off (the repository and its snapshots stay)"
  COMPOSE_PROFILES=backup docker compose rm --stop --force backup
fi

info "starting agent"
docker compose pull --quiet --ignore-buildable 2>/dev/null || docker compose pull --ignore-pull-failures
# Compose recreates exactly what changed: a changed setting in .env, or a
# changed file in the agent's images. Not fatal: if CrowdSec fails to become
# healthy its bouncer cannot start and `up` exits non-zero, but the agent is
# running; the checks below report what failed.
docker compose up -d --build --remove-orphans \
  || echo "warning: not every service started; see the checks below" >&2

# ── Check ───────────────────────────────────────────────────────────────────
info "waiting for the agent to settle"
sleep 12

if ! docker ps --filter "name=^$AGENT\$" --filter status=running --format '{{.Names}}' | grep -q .; then
  echo "The agent is not running. Recent logs:" >&2
  docker compose logs --tail 40 alloy >&2
  die "agent failed to start"
fi
docker compose logs alloy 2>/dev/null | grep '^[^|]*| agent: ERROR' | sed 's/^[^|]*| agent: /  /' || true

# Alloy logs a remote_write error on every failed push, so this catches a
# wrong password or a firewall immediately. Database components are left
# out: a wrong database password also says "authentication".
if docker compose logs --tail 200 alloy 2>/dev/null | grep -v 'component_path=/database_' \
     | grep -qiE 'non-recoverable error.*(401|403)|authentication'; then
  echo "The agent started but the ingest gateway rejected its credentials." >&2
  echo "Check that '$CLIENT_ID' exists in the central INGEST_USERS and that the" >&2
  echo "password matches, then re-run this installer." >&2
  exit 1
fi

# Each exporter connects on its first scrape, within 30 seconds of the start.
FAILED=""
if [[ ${#DBS[@]} -gt 0 ]]; then
  info "checking database connections"
  sleep 35
  logs="$(docker compose logs --since "$STARTED_AT" alloy 2>/dev/null | grep 'level=error' \
          | grep -v 'was collected before' || true)"
  for key in $(printf '%s\n' "${!DBS[@]}" | sort); do
    name="${key#DB_}"; name="${name,,}"; name="${name//_/-}"
    err="$(grep -E "component_path=/database_[a-z]+\.db_${name//-/_} " <<<"$logs" | tail -n 1 \
           | sed -nE 's/.* (err|error)="((\\.|[^"\\])*)".*/\2/p' | sed 's/\\"/"/g' | cut -c1-200 || true)"
    if [[ -z "$err" ]]; then
      echo "  ok      $name"
    else
      FAILED=1
      echo "  FAILING $name: $err"
    fi
  done
fi

# CrowdSec: healthy means its local API answers and the start-up step has
# registered the bouncer and applied the whitelist. Then the bouncer must
# have pulled decisions since this run started: detection without a working
# bouncer blocks nothing, and that is easy to miss.
if [[ -n "$CROWDSEC_ON" ]]; then
  info "checking CrowdSec"
  cs() { docker exec grafana-prometheus-loki-crowdsec cscli "$@"; }
  health=""
  for _ in $(seq 60); do
    health="$(docker inspect -f '{{.State.Health.Status}}' grafana-prometheus-loki-crowdsec 2>/dev/null || true)"
    [[ "$health" == healthy ]] && break
    sleep 3
  done
  if [[ "$health" != healthy ]]; then
    FAILED=1
    echo "  FAILING crowdsec: not healthy. docker logs grafana-prometheus-loki-crowdsec"
  else
    echo "  ok      crowdsec: never blocking ${CROWDSEC_WHITELIST:-(nothing whitelisted)}"
    [[ -z "$AUTO_WHITELISTED" ]] || echo "          (whitelisted automatically, you are connected from:$AUTO_WHITELISTED)"
    docker logs grafana-prometheus-loki-crowdsec 2>&1 | grep -E '^grafana-prometheus-loki: (WARNING|ERROR)' | sed 's/^grafana-prometheus-loki: /          /' | sort -u || true
    pulled=""
    for _ in $(seq 20); do
      # CrowdSec records a bouncer connecting from a new address under a
      # second entry, firewall@<ip>, so take the latest pull of either.
      last="$(cs bouncers list -o raw 2>/dev/null \
              | awk -F, '$1 == "firewall" || $1 ~ /^firewall@/ { print $4 }' | sort | tail -n 1)"
      if [[ -n "$last" && ! "$last" < "$STARTED_AT" ]]; then pulled=1; break; fi
      sleep 3
    done
    if [[ -n "$pulled" ]]; then
      echo "  ok      firewall bouncer: pulling decisions, blocking in nftables"
    else
      FAILED=1
      echo "  FAILING firewall bouncer: has not fetched decisions. docker logs grafana-prometheus-loki-crowdsec-bouncer"
    fi
  fi
fi

# Backups: can the container reach and open the repository? That catches a
# wrong URL, password or credential now rather than at 3 in the morning.
if [[ -n "$BACKUP_ON" ]]; then
  info "checking backups"
  if out="$(docker exec grafana-prometheus-loki-backup backup check 2>&1 | tail -n 1)" && [[ "$out" == ok:* ]]; then
    echo "  ok      restic: ${out#ok: }"
    echo "          schedule: ${BACKUP_SCHEDULE:-0 3 * * *} (UTC). Run one now: docker exec grafana-prometheus-loki-backup backup"
  else
    FAILED=1
    echo "  FAILING restic: ${out:-the backup container is not running}. docker logs grafana-prometheus-loki-backup"
  fi
  if [[ -n "$GENERATED_BACKUP_PASSWORD" ]]; then
    echo
    echo "  The backup repository's password, generated just now:"
    echo
    echo "      $RESTIC_PASSWORD"
    echo
    echo "  Store it somewhere other than this server, now. It is also in $ENV_FILE,"
    echo "  but if this server is lost, so is that file, and without the password"
    echo "  the backups cannot be read by anyone."
  fi
fi

echo
info "done — $HOST_NAME is reporting as client '$CLIENT_ID'"
echo
echo "  settings: $ENV_FILE  (edit, then: docker compose up -d --build)"
echo "  logs:     docker compose -f $INSTALL_DIR/docker-compose.yml logs -f"
echo "  remove:   docker compose -f $INSTALL_DIR/docker-compose.yml down -v && rm -rf $INSTALL_DIR"
echo
if [[ -n "$FAILED" ]]; then
  echo "Something above is FAILING. Fix it and re-run this installer; a database can"
  echo "be corrected with --db <name>=<url> or dropped with --remove-db <name>."
  echo
fi
