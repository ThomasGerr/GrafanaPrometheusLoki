#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Database URLs: parsing and validation, shared by the agent's start-up
# (entrypoint.sh) and the backup container (backup/backup.sh). Sourced, not
# run.
#
#   DB_<NAME>=<url>   postgres(ql)://, mysql://, mariadb://, redis(s)://,
#                     mongodb://, sqlserver://, mssql://
# ─────────────────────────────────────────────────────────────────────────────
# shellcheck disable=SC2034  # the U_* globals are for the scripts sourcing this

LOCAL_HOSTS="localhost|127\.0\.0\.1|::1"

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
