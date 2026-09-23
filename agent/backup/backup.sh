#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# One backup run, with restic. Run by crond on BACKUP_SCHEDULE, or by hand:
#
#   docker exec grafana-prometheus-loki-backup backup              a full run now
#   docker exec grafana-prometheus-loki-backup backup schedule x   one schedule's run
#   docker exec grafana-prometheus-loki-backup backup check        repository reachable?
#
# A schedule comes from the backup API (the Backups dashboard) and says what
# to back up: the whole machine, paths, Docker volumes or databases. Without
# any schedules, the BACKUP_* variables below are used instead.
#
# A run backs up, in separate snapshots tagged by kind:
#   files   BACKUP_PATHS (host paths) and, with BACKUP_DOCKER_VOLUMES=true,
#           every Docker volume
#   db      one dump per database: BACKUP_DB_<NAME>, or DB_<NAME> when that
#           user may read the data. Streamed straight into restic, never
#           written to disk; a dump that fails fails its snapshot.
# then applies retention (BACKUP_KEEP_*), checks the repository, and writes
# the results to /metrics/restic.prom for the agent to report.
#
# The host's filesystem is mounted at /rootfs, so snapshot paths start with
# /rootfs: /rootfs/etc is the host's /etc.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

# crond starts jobs with an empty environment; the entrypoint saved it here.
# shellcheck disable=SC1091
[[ -f /run/backup.env ]] && . /run/backup.env
# shellcheck source=../lib/db-url.sh
. /usr/local/lib/db-url.sh

METRICS=/metrics/restic.prom
HOST="${HOST_NAME:?HOST_NAME is required}"
log() { echo "backup: $*" >&2; }

# ── Metrics ─────────────────────────────────────────────────────────────────
# Written as a whole to a temporary file and renamed, so the agent never
# reads half a file. A value this run did not produce keeps its last one.
declare -A M=()
load_metrics() {
  [[ -f "$METRICS" ]] || return 0
  while read -r name value; do
    [[ "$name" =~ ^restic_ ]] && M["$name"]="$value"
  done < "$METRICS"
}
write_metrics() {
  local tmp="$METRICS.tmp"
  M[restic_backup_max_age_seconds]=$(( ${BACKUP_MAX_AGE_HOURS:-26} * 3600 ))
  for key in $(printf '%s\n' "${!M[@]}" | sort); do
    echo "$key ${M[$key]}"
  done > "$tmp"
  mv "$tmp" "$METRICS"
}

# ── Repository ──────────────────────────────────────────────────────────────
repo_ready() {
  if restic cat config >/dev/null 2>&1; then return 0; fi
  log "no repository at RESTIC_REPOSITORY yet; initialising it"
  restic init >/dev/null
}

# The newest snapshot of this host, as a Unix timestamp: the real "last
# successful backup", also after a restart of this container.
latest_snapshot_time() {
  # restic writes e.g. 2026-09-22T03:00:01.123456789Z (this container runs
  # in UTC); jq's date parser wants it without the fraction.
  restic snapshots --host "$HOST" --json 2>/dev/null \
    | jq -r '[.[].time | sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601] | max // empty' \
    || true
}

if [[ "${1:-}" == check ]]; then
  repo_ready || { echo "FAILING: cannot reach or initialise the repository"; exit 1; }
  echo "ok: repository reachable, $(restic snapshots --host "$HOST" --json | jq length) snapshot(s) of $HOST"
  exit 0
fi

if [[ "${1:-}" == init-metrics ]]; then
  load_metrics
  M[restic_backup_enabled_since_timestamp_seconds]="${M[restic_backup_enabled_since_timestamp_seconds]:-$(date +%s)}"
  if t="$(latest_snapshot_time)" && [[ -n "$t" ]]; then
    M[restic_backup_last_success_timestamp_seconds]="$t"
  fi
  write_metrics
  exit 0
fi

# ── What this run backs up ──────────────────────────────────────────────────
# Either one schedule from the API, or the BACKUP_* variables.
SPECS=/run/backup-schedules.json
RUN_LABEL=manual
SCHEDULE_PATHS=(); SCHEDULE_VOLUMES=(); SCHEDULE_DATABASES=(); SCHEDULE_MACHINE=false
USING_SCHEDULE=""
if [[ "${1:-}" == schedule ]]; then
  RUN_LABEL="${2:?a schedule name is required}"
  [[ -f "$SPECS" ]] || { log "ERROR no schedules from the API yet"; exit 1; }
  spec="$(jq -c --arg n "$RUN_LABEL" '.[] | select(.name == $n)' "$SPECS")"
  [[ -n "$spec" ]] || { log "ERROR no schedule called $RUN_LABEL"; exit 1; }
  USING_SCHEDULE=1
  SCHEDULE_MACHINE="$(jq -r '.sources.machine // false' <<<"$spec")"
  mapfile -t SCHEDULE_PATHS     < <(jq -r '.sources.paths[]?' <<<"$spec")
  mapfile -t SCHEDULE_VOLUMES   < <(jq -r '.sources.volumes[]?' <<<"$spec")
  mapfile -t SCHEDULE_DATABASES < <(jq -r '.sources.databases[]?' <<<"$spec")
  BACKUP_KEEP_DAILY="$(jq -r '.keep.daily' <<<"$spec")"
  BACKUP_KEEP_WEEKLY="$(jq -r '.keep.weekly' <<<"$spec")"
  BACKUP_KEEP_MONTHLY="$(jq -r '.keep.monthly' <<<"$spec")"
fi

# ── A run ───────────────────────────────────────────────────────────────────
exec 9>/run/backup.lock
flock -n 9 || { log "a backup is already running; skipping this one"; exit 0; }

load_metrics
started=$(date +%s)
M[restic_backup_last_run_timestamp_seconds]=$started
ok=1

restic unlock >/dev/null 2>&1 || true
if ! repo_ready; then
  log "ERROR cannot reach or initialise the repository"
  M[restic_backup_success]=0
  M[restic_backup_duration_seconds]=$(( $(date +%s) - started ))
  write_metrics
  exit 1
fi

# Files: host paths and Docker volumes.
paths=(); extra_excludes=()
if [[ -n "$USING_SCHEDULE" ]]; then
  if [[ "$SCHEDULE_MACHINE" == true ]]; then
    paths+=(/rootfs)
    # Everything the kernel makes up rather than stores, and Docker's image
    # layers, which are rebuilt from the registry.
    for e in /proc /sys /dev /run /tmp /var/run /var/lib/docker/overlay2 /var/lib/docker/containers; do
      extra_excludes+=(--exclude "/rootfs$e")
    done
  fi
  wanted=("${SCHEDULE_PATHS[@]+"${SCHEDULE_PATHS[@]}"}")
  for v in "${SCHEDULE_VOLUMES[@]+"${SCHEDULE_VOLUMES[@]}"}"; do
    wanted+=("/var/lib/docker/volumes/$v")
  done
else
  IFS=',' read -r -a wanted <<<"${BACKUP_PATHS:-}"
  [[ "${BACKUP_DOCKER_VOLUMES:-false}" == true ]] && wanted+=(/var/lib/docker/volumes)
fi
for p in "${wanted[@]+"${wanted[@]}"}"; do
  p="${p//[[:space:]]/}"
  [[ -n "$p" ]] || continue
  if [[ -e "/rootfs$p" ]]; then paths+=("/rootfs$p"); else log "WARNING $p does not exist on the host; skipped"; fi
done

if [[ ${#paths[@]} -gt 0 ]]; then
  log "backing up ${paths[*]}"
  # The agent's own write-ahead log and CrowdSec's hub cache are not worth
  # keeping; a database's live files are, but see the dumps below.
  if summary="$(restic backup --host "$HOST" --tag files --tag "$RUN_LABEL" --json --exclude-caches \
                  --exclude '/rootfs/var/lib/docker/volumes/*alloy-data*' \
                  --exclude '/rootfs/var/lib/docker/volumes/*backup-cache*' \
                  "${extra_excludes[@]+"${extra_excludes[@]}"}" \
                  "${paths[@]}" | jq -c 'select(.message_type == "summary")')" && [[ -n "$summary" ]]; then
    M[restic_backup_added_bytes]="$(jq -r '.data_added' <<<"$summary")"
    M[restic_backup_files_processed]="$(jq -r '.total_files_processed' <<<"$summary")"
    M[restic_backup_bytes_processed]="$(jq -r '.total_bytes_processed' <<<"$summary")"
    log "files: $(jq -r '"\(.total_files_processed) files, \(.data_added) bytes new, snapshot \(.snapshot_id[0:8])"' <<<"$summary")"
  else
    log "ERROR the file backup failed"
    ok=0
  fi
fi

# Databases: one streamed dump each. The command runs inside restic, which
# fails the snapshot if it exits non-zero, so a broken dump is never kept as
# a good backup.
dump() {
  local name="$1" url="$2" engine host query cmd=() file
  parse_url "$url"
  engine="$(db_engine "$U_SCHEME")"
  host="$U_HOST"
  [[ "$host" =~ ^($LOCAL_HOSTS)$ ]] && host=host.docker.internal
  [[ -n "$U_BRACKETS" ]] && host="[$host]"
  case "$engine" in
    postgres)
      query="$U_QUERY"
      if [[ ( "$U_HOST" =~ ^($LOCAL_HOSTS)$ || "$U_HOST" != *.* ) && "$query" != *sslmode=* ]]; then
        query="${query:-?}"; [[ "$query" == "?" ]] || query="$query&"; query="${query}sslmode=disable"
      fi
      file="$name.pgdump"
      cmd=(pg_dump --format=custom --no-password "postgresql://$U_USERINFO@$host${U_PORT:+:$U_PORT}$U_PATH$query") ;;
    mysql)
      file="$name.sql"
      export MYSQL_PWD; MYSQL_PWD="$(urldecode "$U_PASS")"
      local db="${U_PATH#/}" conn dbs
      conn=(--host="${host//[\[\]]/}" --port="${U_PORT:-3306}" --user="$(urldecode "$U_USER")" --skip-ssl-verify-server-cert)
      # Without a database in the URL: every user database. Not
      # --all-databases: that includes MySQL's own system schema, which a
      # fresh server refuses to load back (tested with MySQL 8.4), so the
      # backup would fail exactly when it is needed. Accounts and grants are
      # therefore not in the dump; recreate them when restoring.
      if [[ -n "$db" ]]; then
        dbs=("$db")
      else
        mapfile -t dbs < <(mariadb "${conn[@]}" -N -e 'SHOW DATABASES' 2>/dev/null \
                           | grep -vxE 'mysql|sys|information_schema|performance_schema')
        [[ ${#dbs[@]} -gt 0 ]] || { log "database $name: no user databases to dump (or cannot connect)"; dbs=(); }
      fi
      cmd=(mariadb-dump "${conn[@]}" --single-transaction --routines --events --databases "${dbs[@]}") ;;
    mongodb)
      file="$name.archive.gz"
      # The path in the URL is where the user was created. Left in the URI,
      # mongodump would dump only that database, so it moves to
      # --authenticationDatabase and everything is dumped.
      local authdb="${U_PATH#/}"
      cmd=(mongodump --quiet --archive --gzip --authenticationDatabase="${authdb:-admin}"
           --uri="mongodb://$U_USERINFO@$host${U_PORT:+:$U_PORT}/$U_QUERY") ;;
    redis)
      file="$name.rdb"
      # redis-cli -u does not decode %-escapes, so the password goes, decoded,
      # through REDISCLI_AUTH (which also keeps it out of the process list).
      export REDISCLI_AUTH; REDISCLI_AUTH="$(urldecode "$U_PASS")"
      cmd=(redis-cli -u "$U_SCHEME://$host:${U_PORT:-6379}" --rdb -)
      [[ -z "$U_USER" ]] || cmd+=(--user "$(urldecode "$U_USER")") ;;
    mssql)
      log "SQL Server $name: no dump; its own BACKUP DATABASE writes on the database server. Back up its volume instead (BACKUP_DOCKER_VOLUMES)."
      return 0 ;;
  esac
  if summary="$(restic backup --host "$HOST" --tag db --tag "$name" --json \
                  --stdin-from-command --stdin-filename "databases/$file" -- "${cmd[@]}" \
                | jq -c 'select(.message_type == "summary")')" && [[ -n "$summary" ]]; then
    M["restic_dump_success{db=\"$name\",engine=\"$engine\"}"]=1
    M["restic_dump_bytes{db=\"$name\",engine=\"$engine\"}"]="$(jq -r '.total_bytes_processed' <<<"$summary")"
    log "database $name: $(jq -r '.total_bytes_processed' <<<"$summary") bytes dumped"
  else
    M["restic_dump_success{db=\"$name\",engine=\"$engine\"}"]=0
    log "ERROR database $name: the dump failed"
    ok=0
  fi
  unset MYSQL_PWD REDISCLI_AUTH
}
# BACKUP_DB_<NAME> overrides DB_<NAME>: the monitoring user usually may not
# read the data itself.
# Forget dump results from earlier runs: a database removed from the
# variables must not keep reporting its last dump.
for key in "${!M[@]}"; do [[ "$key" == restic_dump_* ]] && unset "M[$key]"; done
declare -A DUMPS=()
while IFS='=' read -r key url; do DUMPS["${key#DB_}"]="$url"; done < <(db_vars)
while IFS='=' read -r -d '' key value; do
  [[ "$key" =~ ^BACKUP_DB_([A-Za-z0-9_]+)$ ]] && DUMPS["${BASH_REMATCH[1]}"]="$value"
done < <(env -0)
# A schedule names the databases it wants; otherwise every DB_ variable.
if [[ -n "$USING_SCHEDULE" ]]; then
  declare -A WANTED=()
  for d in "${SCHEDULE_DATABASES[@]+"${SCHEDULE_DATABASES[@]}"}"; do
    upper="${d^^}"; WANTED["${upper//-/_}"]=1
  done
  for key in "${!DUMPS[@]}"; do [[ -n "${WANTED[$key]:-}" ]] || unset "DUMPS[$key]"; done
fi
if [[ "${BACKUP_DATABASES:-true}" == true ]]; then
  for key in $(printf '%s\n' "${!DUMPS[@]}" | sort); do
    name="$(db_name "DB_$key")"
    if problem="$(db_problem "$name" "${DUMPS[$key]}")" && [[ -n "$problem" ]]; then
      log "ERROR skipping database $name: $problem"
      M["restic_dump_success{db=\"$name\",engine=\"unknown\"}"]=0
      ok=0
      continue
    fi
    dump "$name" "${DUMPS[$key]}"
  done
fi

if [[ ${#paths[@]} -eq 0 && ${#DUMPS[@]} -eq 0 ]]; then
  if [[ -n "$USING_SCHEDULE" ]]; then
    log "ERROR schedule $RUN_LABEL has nothing to back up on this host"
  else
    log "ERROR nothing to back up: set BACKUP_PATHS, BACKUP_DOCKER_VOLUMES=true or DB_ variables"
  fi
  ok=0
fi

# Retention, for this host's snapshots only.
if ! restic forget --host "$HOST" --prune --quiet \
       --keep-daily "${BACKUP_KEEP_DAILY:-7}" --keep-weekly "${BACKUP_KEEP_WEEKLY:-4}" \
       --keep-monthly "${BACKUP_KEEP_MONTHLY:-6}" >/dev/null; then
  log "WARNING applying retention failed; old snapshots are kept"
fi

# Integrity of the repository's structure. Reading back every byte is far
# more expensive; BACKUP_CHECK_READ_DATA=5% reads that share each run.
check=(restic check --quiet)
[[ -z "${BACKUP_CHECK_READ_DATA:-}" ]] || check+=(--read-data-subset "$BACKUP_CHECK_READ_DATA")
if out="$("${check[@]}" 2>&1)"; then
  M[restic_check_success]=1
else
  M[restic_check_success]=0
  log "ERROR the repository check failed: $(grep -v '^$' <<<"$out" | head -n 3 | tr '\n' ' ')"
  ok=0
fi
M[restic_check_last_timestamp_seconds]=$(date +%s)

M[restic_snapshots]="$(restic snapshots --host "$HOST" --json 2>/dev/null | jq length || echo 0)"
size="$(restic stats --mode raw-data --json 2>/dev/null | jq -r '.total_size // empty')"
[[ -z "$size" ]] || M[restic_repository_size_bytes]="$size"

M[restic_backup_success]=$ok
M[restic_backup_duration_seconds]=$(( $(date +%s) - started ))
[[ "$ok" == 1 ]] && M[restic_backup_last_success_timestamp_seconds]=$started
write_metrics

# Tell the API what this run did, so the dashboard can show it. Best effort:
# the backup itself is what matters, and the metrics carry the same facts.
if [[ -n "${INGEST_URL:-}" && -n "${CLIENT_ID:-}" && -n "${INGEST_PASSWORD:-}" ]]; then
  jq -nc --arg schedule "$RUN_LABEL" \
     --arg started "$(date -u -d "@$started" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)" \
     --arg finished "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
     --argjson ok "$([[ $ok == 1 ]] && echo true || echo false)" \
     --argjson added "${M[restic_backup_added_bytes]:-0}" \
     --argjson processed "${M[restic_backup_bytes_processed]:-0}" \
     --argjson duration "${M[restic_backup_duration_seconds]}" \
     '{schedule: $schedule, started_at: $started, finished_at: $finished, ok: $ok,
       summary: {added_bytes: $added, bytes_processed: $processed, duration_seconds: $duration}}' \
    | curl --silent --show-error --max-time 30 --user "$CLIENT_ID:$INGEST_PASSWORD" \
        -H 'Content-Type: application/json' --data-binary @- \
        -X POST "$INGEST_URL/backup/runs?host=$HOST" >/dev/null 2>&1 || true
fi

log "run finished: $([[ $ok == 1 ]] && echo ok || echo FAILED) in ${M[restic_backup_duration_seconds]}s"
[[ "$ok" == 1 ]]
