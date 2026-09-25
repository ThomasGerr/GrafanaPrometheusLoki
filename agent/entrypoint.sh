#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# grafana-prometheus-loki agent — start-up
#
# The agent configures itself from its environment, every time it starts:
#
#   DB_<NAME>=<url>          one database to monitor, e.g.
#                            DB_APP=postgres://monitor:pw@app-db:5432/app
#   PROCESS_GROUP_<NAME>     processes whose command line matches this regular
#                            expression are reported as <name>, e.g.
#                            PROCESS_GROUP_API='node .*/api/server\.js'
#   LOG_FILE_<NAME>          host log files to read, as a path or glob, e.g.
#                            LOG_FILE_PM2=/home/deploy/.pm2/logs/*.log
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
PROCESSES=/etc/alloy/processes.alloy
LOGFILES=/etc/alloy/logfiles.alloy
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

# ── Generate processes.alloy ────────────────────────────────────────────────
# Processes are grouped by the name of their executable, which is all the
# kernel offers: every pm2-managed app is "node", every Python service is
# "python3", and the name is cut off at 15 characters. PROCESS_GROUP_<NAME>
# gives a group its own name by matching the command line instead, and is
# tried before that fallback — first match wins.
{
  echo "// Generated at start-up by entrypoint.sh. PROCESS_GROUP_* variables"
  echo "// name groups of processes; everything else falls back to the name of"
  echo "// its executable."
  echo
  echo 'prometheus.exporter.process "processes" {'
  echo '  procfs_path = "/rootfs/proc"'
  echo
  echo "  // Reading /proc/<pid>/smaps_rollup for every process on every scrape"
  echo "  // is by far the most expensive thing this exporter can do, and the"
  echo "  // memory figures come from the cheap /proc/<pid>/stat instead."
  echo "  gather_smaps = false"
} > "$PROCESSES"

named=0
while IFS='=' read -r -d '' key pattern; do
  [[ "$key" =~ ^PROCESS_GROUP_[A-Za-z0-9_]+$ ]] || continue
  name="${key#PROCESS_GROUP_}"
  name="$(tr '[:upper:]_' '[:lower:]-' <<<"$name")"
  if [[ -z "$pattern" ]]; then
    log "ERROR skipping $key: it has no pattern to match a command line with"
    continue
  fi
  # Alloy reads this file as one config: a stray quote or backslash would
  # stop the whole agent, so the pattern is escaped into a string literal.
  escaped="${pattern//\\/\\\\}"
  escaped="${escaped//\"/\\\"}"
  {
    echo
    echo "  matcher {"
    echo "    cmdline = [\"$escaped\"]"
    echo "    name    = \"$name\""
    echo "  }"
  } >> "$PROCESSES"
  log "processes matching '$pattern' are reported as '$name'"
  named=$((named + 1))
done < <(env -0 | sort -z)

{
  echo
  echo "  // Everything else, under the name of its executable."
  echo "  matcher {"
  echo '    cmdline = [".+"]'
  echo '    name    = "{{.Comm}}"'
  echo "  }"
  echo "}"
} >> "$PROCESSES"
[[ "$named" == 0 ]] || log "$named named process group(s)"

# ── Generate logfiles.alloy ─────────────────────────────────────────────────
# Docker containers and the systemd journal are read without being asked. A
# program that writes its own log file — pm2, or anything started from
# rc.local — is invisible to both, so LOG_FILE_<NAME> names files to read.
# They are labelled program="<name>", which is the label the Logs dashboard
# already filters journal entries by.
rm -f "$LOGFILES"
targets=()
while IFS='=' read -r -d '' key glob; do
  [[ "$key" =~ ^LOG_FILE_[A-Za-z0-9_]+$ ]] || continue
  name="${key#LOG_FILE_}"
  name="$(tr '[:upper:]_' '[:lower:]-' <<<"$name")"
  if [[ "$glob" != /* || "$glob" == *..* || "$glob" == *'"'* ]]; then
    log "ERROR skipping $key: '$glob' must be an absolute path, without .. or quotes"
    continue
  fi
  # The host's filesystem is mounted read-only at /rootfs, so that is where
  # its paths are from in here.
  targets+=("    {__path__ = \"/rootfs$glob\", client = \"$CLIENT_ID\", instance = \"$HOST_NAME\", job = \"file\", program = \"$name\"},")
  log "reading $glob as '$name'"
done < <(env -0 | sort -z)

if [[ ${#targets[@]} -gt 0 ]]; then
  {
    echo "// Generated at start-up by entrypoint.sh from the LOG_FILE_* variables."
    echo
    echo 'local.file_match "extra" {'
    echo "  path_targets = ["
    printf '%s\n' "${targets[@]}"
    echo "  ]"
    echo
    echo "  // Files come and go (pm2 rotates, a deploy makes new ones), so the"
    echo "  // set is re-read rather than fixed at start-up."
    echo '  sync_period = "30s"'
    echo "}"
    echo
    echo 'loki.source.file "extra" {'
    echo "  targets    = local.file_match.extra.targets"
    echo "  forward_to = [loki.relabel.extra.receiver]"
    echo
    echo "  // From the end: a log file that has been written to for months"
    echo "  // would otherwise be replayed in full the first time it is read."
    echo "  tail_from_end = true"
    echo "}"
    echo
    echo "// The host's filesystem is mounted at /rootfs, which is the agent's"
    echo "// business and not the reader's: the filename label says where the"
    echo "// file is on the host."
    echo 'loki.relabel "extra" {'
    echo "  forward_to = [loki.process.enrich.receiver]"
    echo
    echo "  rule {"
    echo '    source_labels = ["filename"]'
    echo '    regex         = "/rootfs(.*)"'
    echo '    target_label  = "filename"'
    echo '    replacement   = "$1"'
    echo "  }"
    echo "}"
  } > "$LOGFILES"
  log "${#targets[@]} log file pattern(s)"
fi

exec /bin/alloy "$@"
