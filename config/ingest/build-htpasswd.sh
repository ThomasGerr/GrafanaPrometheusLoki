#!/bin/sh
# Turn INGEST_USERS="acme:pw1,globex:pw2" into an nginx credentials file.
# Runs as root via /docker-entrypoint.d/ before nginx starts.
# Nothing is ever written to the repo — the passwords live only in the
# environment (Dokploy) and in this container-local file.
set -eu

HTPASSWD=/etc/nginx/ingest.htpasswd

if [ -z "${INGEST_USERS:-}" ]; then
  echo "ingest: FATAL — INGEST_USERS is empty. No agent would be able to push." >&2
  exit 1
fi

rm -f "$HTPASSWD"
: > "$HTPASSWD"
chmod 600 "$HTPASSWD"

count=0
echo "$INGEST_USERS" | tr ',' '\n' | while IFS= read -r pair; do
  pair=$(echo "$pair" | tr -d '[:space:]')
  [ -z "$pair" ] && continue

  user=${pair%%:*}
  pass=${pair#*:}

  if [ -z "$user" ] || [ -z "$pass" ] || [ "$user" = "$pair" ]; then
    echo "ingest: FATAL — malformed INGEST_USERS entry (expected 'client:password')" >&2
    exit 1
  fi

  # The username becomes the Loki tenant id, so keep it to safe characters.
  if ! echo "$user" | grep -Eq '^[a-z0-9][a-z0-9_-]*$'; then
    echo "ingest: FATAL — client id '$user' must match [a-z0-9][a-z0-9_-]*" >&2
    exit 1
  fi

  htpasswd -bm "$HTPASSWD" "$user" "$pass" 2>/dev/null
  count=$((count + 1))
  echo "ingest: registered client '$user'"
done

chown nginx "$HTPASSWD"
echo "ingest: credentials file ready"
