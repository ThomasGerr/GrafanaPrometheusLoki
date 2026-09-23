#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Restores a snapshot, on a job from the backup API:
#
#   backup-restore '{"id":"…","payload":{"snapshot_id":"…","kind":"files",
#                    "include":"/etc/nginx","switch":true}}'
#
# Nothing is ever restored over live data directly. Files and databases are
# first restored beside what is there, and only once that has finished does
# the switch happen, keeping the previous copy as <name>_old_<timestamp>.
# So a failed restore leaves the live data untouched, and a regretted one can
# be undone by moving the _old copy back.
#
# Files are written through /hostfs, the host's filesystem mounted writable.
# Backups themselves read /rootfs, which stays read-only.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

# shellcheck disable=SC1091
[[ -f /run/backup.env ]] && . /run/backup.env
# shellcheck source=../lib/db-url.sh
. /usr/local/lib/db-url.sh

JOB="${1:?a job as JSON is required}"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
log() { echo "restore: $*" >&2; }
fail() { log "ERROR $*"; exit 1; }

SNAPSHOT="$(jq -r '.payload.snapshot_id' <<<"$JOB")"
KIND="$(jq -r '.payload.kind' <<<"$JOB")"
SWITCH="$(jq -r '.payload.switch // true' <<<"$JOB")"
[[ -n "$SNAPSHOT" && "$SNAPSHOT" != null ]] || fail "the job has no snapshot"

# ── Files ───────────────────────────────────────────────────────────────────
restore_files() {
  local include paths target staging restored old
  include="$(jq -r '.payload.include // empty' <<<"$JOB")"
  [[ -d /hostfs ]] || fail "the host filesystem is not mounted writable at /hostfs"

  # Which host paths this snapshot holds. Snapshot paths start with /rootfs.
  mapfile -t paths < <(restic snapshots "$SNAPSHOT" --json 2>/dev/null \
    | jq -r '.[0].paths[]? | select(startswith("/rootfs"))' | sed 's|^/rootfs||')
  [[ ${#paths[@]} -gt 0 ]] || fail "snapshot $SNAPSHOT holds no file paths"
  if [[ -n "$include" ]]; then
    local wanted=() p
    for p in "${paths[@]}"; do [[ "$include" == "$p" || "$include" == "$p"/* ]] && wanted+=("$include"); done
    [[ ${#wanted[@]} -gt 0 ]] || fail "$include is not part of snapshot $SNAPSHOT"
    paths=("${wanted[0]}")
  fi

  for target in "${paths[@]}"; do
    staging="$(dirname "$target")/.em-restore-$STAMP"
    log "restoring $target beside the live copy"
    mkdir -p "/hostfs$staging" || fail "cannot write to $(dirname "$target") on the host"
    if ! restic restore "$SNAPSHOT" --include "/rootfs$target" --target "/hostfs$staging" >/dev/null; then
      rm -rf "/hostfs$staging"
      fail "restoring $target failed; nothing was changed"
    fi
    restored="/hostfs$staging/rootfs$target"
    [[ -e "$restored" ]] || { rm -rf "/hostfs$staging"; fail "$target is not in the snapshot"; }

    if [[ "$SWITCH" != true ]]; then
      log "restored to $staging/rootfs$target (not switched, as asked)"
      continue
    fi
    old="${target}_old_$STAMP"
    if [[ -e "/hostfs$target" ]]; then
      mv "/hostfs$target" "/hostfs$old" || { rm -rf "/hostfs$staging"; fail "cannot move the live $target aside"; }
    fi
    if ! mv "$restored" "/hostfs$target"; then
      # Put back what was there, so a failure never leaves the host worse off.
      [[ -e "/hostfs$old" ]] && mv "/hostfs$old" "/hostfs$target"
      rm -rf "/hostfs$staging"
      fail "cannot put the restored $target in place; the live copy is back"
    fi
    rm -rf "/hostfs$staging"
    log "$target restored from snapshot $SNAPSHOT; what was there is now $old"
  done
}

# ── Databases ───────────────────────────────────────────────────────────────
# The URL of a database, as the dumps use it: BACKUP_DB_<NAME> first.
db_url() {
  local name="$1"
  local key="DB_${name^^}"
  key="${key//-/_}"
  local backup_key="BACKUP_$key"
  printf '%s' "${!backup_key:-${!key:-}}"
}

restore_database() {
  local name url engine host authdb
  name="$(jq -r '.payload.database' <<<"$JOB")"
  [[ -n "$name" && "$name" != null ]] || fail "the job has no database"
  url="$(db_url "$name")"
  [[ -n "$url" ]] || fail "this host has no DB_ or BACKUP_DB_ variable for $name"
  parse_url "$url" || fail "the URL for $name cannot be parsed"
  engine="$(db_engine "$U_SCHEME")" || fail "unsupported database URL for $name"
  host="$U_HOST"
  [[ "$host" =~ ^($LOCAL_HOSTS)$ ]] && host=host.docker.internal

  case "$engine" in
    postgres)
      local db="${U_PATH#/}" admin rename_via restored old
      db="${db:-postgres}"
      admin="postgresql://$U_USERINFO@$host${U_PORT:+:$U_PORT}/postgres?sslmode=disable"
      # A database cannot be renamed through a connection to itself, and
      # CREATE DATABASE cannot run through template1 (it is the template).
      # So: create through postgres, rename through template1 — unless the
      # database being restored is one of those two.
      rename_via="template1"
      [[ "$db" != template1 ]] || rename_via="postgres"
      rename_via="postgresql://$U_USERINFO@$host${U_PORT:+:$U_PORT}/$rename_via?sslmode=disable"
      restored="${db}_restored_$STAMP"; old="${db}_old_$STAMP"
      log "restoring into $restored, beside the live $db"
      psql "$admin" -q -c "CREATE DATABASE \"$restored\"" || fail "cannot create $restored"
      if ! restic dump "$SNAPSHOT" "databases/$name.pgdump" \
           | pg_restore --no-owner --no-privileges -d "postgresql://$U_USERINFO@$host${U_PORT:+:$U_PORT}/$restored?sslmode=disable"; then
        psql "$admin" -q -c "DROP DATABASE \"$restored\"" >/dev/null 2>&1
        fail "the dump did not restore; the live $db is untouched"
      fi
      [[ "$SWITCH" == true ]] || { log "restored to $restored (not switched, as asked)"; return 0; }
      # Renaming needs the database to be idle: connections are closed first.
      psql "$rename_via" -q -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$db' AND pid <> pg_backend_pid()" >/dev/null
      psql "$rename_via" -q -c "ALTER DATABASE \"$db\" RENAME TO \"$old\"" || fail "cannot rename the live $db aside; the restore is in $restored"
      if ! psql "$rename_via" -q -c "ALTER DATABASE \"$restored\" RENAME TO \"$db\""; then
        psql "$rename_via" -q -c "ALTER DATABASE \"$old\" RENAME TO \"$db\""
        fail "cannot put $restored in place; the live $db is back"
      fi
      log "$db restored from snapshot $SNAPSHOT; what was there is now $old"
      ;;

    mysql)
      local db="${U_PATH#/}" conn restored old tables
      db="${db:-$name}"
      export MYSQL_PWD; MYSQL_PWD="$(urldecode "$U_PASS")"
      conn=(--host="$host" --port="${U_PORT:-3306}" --user="$(urldecode "$U_USER")" --skip-ssl-verify-server-cert)
      restored="${db}_restored_$STAMP"; old="${db}_old_$STAMP"
      log "restoring into $restored, beside the live $db"
      mariadb "${conn[@]}" -e "CREATE DATABASE \`$restored\`" || fail "cannot create $restored"
      # The dump recreates the original database; those statements are
      # dropped so it lands in the new one instead.
      if ! restic dump "$SNAPSHOT" "databases/$name.sql" \
           | sed -E '/^(CREATE DATABASE|USE `)/d' \
           | mariadb "${conn[@]}" --database="$restored"; then
        mariadb "${conn[@]}" -e "DROP DATABASE \`$restored\`" >/dev/null 2>&1
        fail "the dump did not restore; the live $db is untouched"
      fi
      [[ "$SWITCH" == true ]] || { log "restored to $restored (not switched, as asked)"; return 0; }
      # MySQL cannot rename a database, so the tables are moved: out of the
      # live one into _old, then out of the restored one into live.
      mariadb "${conn[@]}" -e "CREATE DATABASE IF NOT EXISTS \`$old\`" || fail "cannot create $old"
      tables="$(mariadb "${conn[@]}" -N -e "SELECT table_name FROM information_schema.tables WHERE table_schema = '$db' AND table_type = 'BASE TABLE'")"
      for t in $tables; do
        mariadb "${conn[@]}" -e "RENAME TABLE \`$db\`.\`$t\` TO \`$old\`.\`$t\`" || fail "cannot move $db.$t aside"
      done
      tables="$(mariadb "${conn[@]}" -N -e "SELECT table_name FROM information_schema.tables WHERE table_schema = '$restored' AND table_type = 'BASE TABLE'")"
      for t in $tables; do
        mariadb "${conn[@]}" -e "RENAME TABLE \`$restored\`.\`$t\` TO \`$db\`.\`$t\`" || fail "cannot put $restored.$t in place; the previous tables are in $old"
      done
      mariadb "${conn[@]}" -e "DROP DATABASE \`$restored\`" >/dev/null 2>&1
      log "$db restored from snapshot $SNAPSHOT; what was there is now the database $old"
      ;;

    mongodb)
      local db="${U_PATH#/}" uri old
      authdb="${db:-admin}"
      db="$name"
      old="${db}_old_$STAMP"
      uri="mongodb://$U_USERINFO@$host${U_PORT:+:$U_PORT}/?authSource=$authdb"
      [[ "$SWITCH" != true ]] || {
        log "copying the live $db to $old first"
        mongodump --quiet --uri="$uri" --db="$db" --archive 2>/dev/null \
          | mongorestore --quiet --uri="$uri" --archive --nsFrom="$db.*" --nsTo="$old.*" \
          || log "WARNING nothing copied aside: $db may not exist yet"
      }
      log "restoring $db from snapshot $SNAPSHOT"
      restic dump "$SNAPSHOT" "databases/$name.archive.gz" \
        | mongorestore --quiet --uri="$uri" --archive --gzip --drop \
        || fail "the dump did not restore; the copy of the live data is in $old"
      log "$db restored; what was there is now the database $old"
      ;;

    redis)
      local staged="/hostfs/var/tmp/$name-$STAMP.rdb"
      mkdir -p /hostfs/var/tmp || fail "the host filesystem is not mounted writable at /hostfs"
      restic dump "$SNAPSHOT" "databases/$name.rdb" > "$staged" || fail "cannot read the dump from the snapshot"
      log "Redis loads its snapshot only at start-up, so this one is not switched automatically."
      log "The snapshot is on the host at ${staged#/hostfs}. To use it: stop the Redis"
      log "container, replace its dump.rdb with this file, and start it again."
      ;;

    mssql)
      fail "SQL Server has no dump in these backups; restore its volume instead" ;;
  esac
  unset MYSQL_PWD
}

case "$KIND" in
  files)    restore_files ;;
  database) restore_database ;;
  *)        fail "unknown restore kind $KIND" ;;
esac
