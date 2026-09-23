#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Asks the central backup API what this host should do, and reports what it
# did. The API never reaches in: this polls outward through the same ingest
# gateway the agent already pushes to, with the same credentials, so a server
# still accepts no inbound connections.
#
# Every BACKUP_POLL_SECONDS (30 by default):
#   1. fetch this host's schedules and write them to crontab,
#   2. claim one job (a backup now, or a restore) and run it,
#   3. report the repository's snapshots, so the dashboard can list them.
#
# Without the API (no INGEST_URL, or it is unreachable) the container keeps
# running on BACKUP_SCHEDULE from its environment, and leaves its crontab
# alone rather than losing it.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

SPECS=/run/backup-schedules.json
log() { echo "backup-poll: $*" >&2; }

api() {
  local method="$1" path="$2" body="${3:-}"
  local args=(--silent --show-error --max-time 30 --user "$CLIENT_ID:$INGEST_PASSWORD"
              -X "$method" "$INGEST_URL/backup/$path")
  [[ -z "$body" ]] || args+=(-H 'Content-Type: application/json' --data-binary "$body")
  curl "${args[@]}"
}

# The crontab, one line per schedule. Rewritten only when the schedules
# actually changed, so crond is not restarted for nothing.
write_crontab() {
  local specs="$1" tmp=/run/crontab.new
  : > "$tmp"
  jq -r '.[] | "\(.cron) /usr/local/bin/backup schedule \(.name) >/proc/1/fd/1 2>/proc/1/fd/2"' <<<"$specs" >> "$tmp"
  if [[ ! -s "$tmp" ]]; then
    # No schedules from the API: fall back to the one in the environment.
    echo "${BACKUP_SCHEDULE:-0 3 * * *} /usr/local/bin/backup >/proc/1/fd/1 2>/proc/1/fd/2" >> "$tmp"
  fi
  if ! cmp -s "$tmp" /etc/crontabs/root; then
    cp "$tmp" /etc/crontabs/root
    log "schedules updated: $(jq -r 'if length == 0 then "none from the API; using BACKUP_SCHEDULE" else (map("\(.name) at \(.cron)") | join(", ")) end' <<<"$specs")"
    # busybox crond re-reads its crontab by itself, but only every minute;
    # a HUP applies it now.
    pkill -HUP crond 2>/dev/null || true
  fi
}

report_snapshots() {
  local snaps
  snaps="$(restic snapshots --host "$HOST_NAME" --json 2>/dev/null \
           | jq -c '[.[] | {id: .short_id, time: .time, tags: (.tags // []), paths: (.paths // [])}]')" || return 0
  [[ -n "$snaps" ]] || return 0
  api POST "snapshots?host=$HOST_NAME" "{\"snapshots\":$snaps}" >/dev/null
}

run_job() {
  local job="$1" id type ok=1 message
  id="$(jq -r '.id' <<<"$job")"
  type="$(jq -r '.type' <<<"$job")"
  case "$type" in
    backup)
      local schedule; schedule="$(jq -r '.payload.schedule // "manual"' <<<"$job")"
      log "job $id: backup ($schedule)"
      if [[ "$schedule" == "manual" || "$schedule" == "null" ]]; then
        message="$(/usr/local/bin/backup 2>&1 | tail -n 3)" || ok=0
      else
        message="$(/usr/local/bin/backup schedule "$schedule" 2>&1 | tail -n 3)" || ok=0
      fi ;;
    restore)
      log "job $id: restore"
      message="$(/usr/local/bin/backup-restore "$job" 2>&1 | tail -n 5)" || ok=0 ;;
    *)
      ok=0; message="unknown job type $type" ;;
  esac
  api POST "job/$id?host=$HOST_NAME" "$(jq -nc --argjson ok "$([[ $ok == 1 ]] && echo true || echo false)" \
      --arg message "$message" '{ok: $ok, message: $message}')" >/dev/null
  log "job $id finished: $([[ $ok == 1 ]] && echo ok || echo FAILED)"
}

[[ -n "${INGEST_URL:-}" && -n "${CLIENT_ID:-}" && -n "${INGEST_PASSWORD:-}" ]] || {
  log "no ingest credentials; running on BACKUP_SCHEDULE only"
  exit 0
}

log "polling $INGEST_URL/backup every ${BACKUP_POLL_SECONDS:-30}s"
while true; do
  if specs="$(api GET "schedules?host=$HOST_NAME")" && jq -e 'type == "array"' <<<"$specs" >/dev/null 2>&1; then
    printf '%s' "$specs" > "$SPECS"
    write_crontab "$specs"
    job="$(api GET "job?host=$HOST_NAME")"
    if jq -e '.id' <<<"$job" >/dev/null 2>&1; then
      run_job "$job"
      report_snapshots
    fi
  else
    log "WARNING the backup API is not answering; keeping the current schedules"
  fi
  sleep "${BACKUP_POLL_SECONDS:-30}"
done
