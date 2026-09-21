#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# grafana-prometheus-loki agent installer
#
#   curl -fsSL https://raw.githubusercontent.com/ThomasGerr/GrafanaPrometheusLoki/main/agent/install.sh \
#     | sudo bash -s -- --client acme --ingest https://ingest.example.com --password 'secret'
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

die() { echo "error: $*" >&2; exit 1; }
info() { echo "==> $*"; }

usage() {
  cat >&2 <<USAGE
Usage: install.sh --client <id> --ingest <url> --password <password> [--host <name>]

  --client    Client id, exactly as it appears in the central clients.yml
  --ingest    Ingest gateway URL, e.g. https://ingest.example.com
  --password  This client's password from the central INGEST_USERS variable
  --host      Name for this server in dashboards (default: this machine's hostname)
  --raw-base  Where to fetch config.alloy and docker-compose.yml from.
              Defaults to this repo's main branch. Pass it when installing
              from a pinned commit, so every file comes from that same commit
              instead of whatever main looks like right now.
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
    -h|--help)  usage ;;
    *)          die "unknown option: $1" ;;
  esac
done

# ── Preconditions ───────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "run as root (use sudo)"
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
    cp "$SCRIPT_DIR/$name" "$INSTALL_DIR/$name"
  else
    info "downloading $name"
    curl -fsSL "$RAW_BASE/$name" -o "$INSTALL_DIR/$name" \
      || die "could not download $name from $RAW_BASE
  If the repository is private, raw.githubusercontent.com returns 404 for
  every unauthenticated request. Either run this from a git checkout, or
  pass --raw-base pointing somewhere this host can actually read."
  fi
}

fetch config.alloy
fetch docker-compose.yml

# ── Credentials ─────────────────────────────────────────────────────────────
umask 077
cat > "$INSTALL_DIR/.env" <<ENVEOF
CLIENT_ID=$CLIENT_ID
HOST_NAME=$HOST_NAME
INGEST_URL=$INGEST_URL
INGEST_PASSWORD=$INGEST_PASSWORD
JOURNAL_DIR=$JOURNAL_DIR
ENVEOF
chmod 600 "$INSTALL_DIR/.env"

# ── Start ───────────────────────────────────────────────────────────────────
info "starting agent"
cd "$INSTALL_DIR"
docker compose pull --quiet 2>/dev/null || docker compose pull
docker compose up -d --remove-orphans

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
# wrong password or a firewall immediately instead of a day later.
if docker compose logs --tail 200 2>/dev/null | grep -qiE 'non-recoverable error.*(401|403)|authentication'; then
  echo >&2
  echo "The agent started but the ingest gateway rejected its credentials." >&2
  echo "Check that '$CLIENT_ID' exists in the central INGEST_USERS and that the" >&2
  echo "password matches, then re-run this installer." >&2
  exit 1
fi

echo
info "done — $HOST_NAME is reporting as client '$CLIENT_ID'"
echo
echo "  logs:     docker compose -f $INSTALL_DIR/docker-compose.yml logs -f"
echo "  restart:  docker compose -f $INSTALL_DIR/docker-compose.yml restart"
echo "  remove:   docker compose -f $INSTALL_DIR/docker-compose.yml down -v && rm -rf $INSTALL_DIR"
echo
