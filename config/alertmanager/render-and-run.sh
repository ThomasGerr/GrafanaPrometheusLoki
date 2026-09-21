#!/bin/sh
# ─────────────────────────────────────────────────────────────────────────────
# Alertmanager has no environment-variable expansion of its own, so we render
# the committed template at container start.
#
# Every substituted value is a hostname, URL or email address — safe for sed.
# The SMTP password never passes through sed or the config file: it is written
# straight to a file and referenced via `smtp_auth_password_file`, so a password
# containing slashes, ampersands or quotes cannot corrupt the config.
# ─────────────────────────────────────────────────────────────────────────────
set -eu

TEMPLATE=/etc/alertmanager/alertmanager.yml.tmpl
RENDERED=/tmp/alertmanager.yml
PASSFILE=/tmp/alertmanager-smtp-password

if [ ! -f "$TEMPLATE" ]; then
  echo "alertmanager: FATAL — $TEMPLATE missing. Run 'make generate' and redeploy." >&2
  exit 1
fi

for required in SMTP_SMARTHOST SMTP_FROM OPS_EMAIL; do
  eval "value=\${$required:-}"
  if [ -z "$value" ]; then
    echo "alertmanager: FATAL — $required is not set; alerts would go nowhere." >&2
    exit 1
  fi
done

umask 077
printf '%s' "${SMTP_PASSWORD:-}" > "$PASSFILE"

sed \
  -e "s|__SMTP_SMARTHOST__|${SMTP_SMARTHOST}|g" \
  -e "s|__SMTP_FROM__|${SMTP_FROM}|g" \
  -e "s|__SMTP_USER__|${SMTP_USER:-}|g" \
  -e "s|__SMTP_REQUIRE_TLS__|${SMTP_REQUIRE_TLS:-true}|g" \
  -e "s|__OPS_EMAIL__|${OPS_EMAIL}|g" \
  -e "s|__GRAFANA_URL__|${GRAFANA_ROOT_URL:-http://localhost:3000}|g" \
  "$TEMPLATE" > "$RENDERED"

# The message templates embed the dashboard URL too, so render them the same
# way into a writable directory that the config below points at.
mkdir -p /tmp/templates
for t in /etc/alertmanager/templates/*.tmpl; do
  [ -e "$t" ] || continue
  sed -e "s|__GRAFANA_URL__|${GRAFANA_ROOT_URL:-http://localhost:3000}|g" \
      "$t" > "/tmp/templates/$(basename "$t")"
done

# If no SMTP username was supplied, strip the auth lines entirely rather than
# offering an empty username, which some relays reject outright.
if [ -z "${SMTP_USER:-}" ]; then
  sed -i -e '/smtp_auth_username:/d' -e '/smtp_auth_password_file:/d' "$RENDERED"
  echo "alertmanager: no SMTP_USER set — sending unauthenticated"
fi

echo "alertmanager: config rendered, starting"
exec /bin/alertmanager --config.file="$RENDERED" "$@"
