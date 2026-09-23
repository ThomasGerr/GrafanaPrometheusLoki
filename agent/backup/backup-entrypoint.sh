#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Backup container start-up: saves the environment for the scheduled runs
# (crond starts jobs with an empty one), reports the repository's latest
# snapshot so "last successful backup" survives a restart, and runs crond in
# the foreground on BACKUP_SCHEDULE.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

: "${RESTIC_REPOSITORY:?RESTIC_REPOSITORY is required: where the backups go, see docs/backups.md}"
if [[ -z "${RESTIC_PASSWORD:-}${RESTIC_PASSWORD_FILE:-}${RESTIC_PASSWORD_COMMAND:-}" ]]; then
  echo "backup: ERROR RESTIC_PASSWORD is required. Keep it somewhere safe: without it the backups cannot be read." >&2
  exit 1
fi

umask 077
export -p > /run/backup.env
mkdir -p /metrics

schedule="${BACKUP_SCHEDULE:-0 3 * * *}"
echo "$schedule /usr/local/bin/backup >/proc/1/fd/1 2>/proc/1/fd/2" > /etc/crontabs/root
echo "backup: scheduled at '$schedule' (UTC); repository $(sed -E 's#//[^@/]*@#//…@#' <<<"$RESTIC_REPOSITORY")" >&2

/usr/local/bin/backup init-metrics || echo "backup: WARNING the repository is not reachable yet" >&2
[[ "${BACKUP_RUN_ON_START:-false}" != true ]] || /usr/local/bin/backup &

# Schedules and jobs from the backup API, when the agent has ingest
# credentials. It rewrites the crontab above from the schedules the API
# holds; without the API, the line written above stays.
/usr/local/bin/backup-poll &

exec crond -f -l 8
