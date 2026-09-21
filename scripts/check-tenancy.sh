#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Prove that each client's data sources cannot reach another client's data.
#
# This is the check that matters. Everything else in the stack is a
# convenience; this is the thing you have promised clients. Run it after any
# change to the label proxies, the Loki config, or the Grafana bootstrap.
#
# Requires the stack to be running (make up).
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Every query runs from a container on the stack's own network, so this
# works against the production stack too, which publishes no ports.
NETWORK=em-monitor
ORGS_FILE=generated/grafana-orgs.json

[ -f "$ORGS_FILE" ] || { echo "$ORGS_FILE missing — run 'make generate' first."; exit 1; }

# `mapfile` is bash 4+; macOS still ships bash 3.2, so read the list portably.
# `all_tenants` is every tenant including your own; `clients` is only those
# with an Org and a label proxy. The difference is what has to be skipped
# below, derived rather than named, so renaming it cannot strand this check.
TENANTS=()
while IFS= read -r line; do
  [ -n "$line" ] && TENANTS+=("$line")
done < <(python3 -c "
import json
d = json.load(open('$ORGS_FILE'))
print('\n'.join(t for t in d['all_tenants'].split('|') if t))")

REAL_CLIENTS=" $(python3 -c "
import json
d = json.load(open('$ORGS_FILE'))
print(' '.join(c['id'] for c in d['clients']))") "

if [ "${#TENANTS[@]}" -lt 2 ]; then
  echo "Only ${#TENANTS[@]} tenant(s) configured — nothing to isolate. Add a second client to clients.yml."
  exit 0
fi

fails=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; fails=$((fails + 1)); }

cq() { docker run --rm --network "$NETWORK" curlimages/curl:latest -s "$@"; }

echo "Tenants: ${TENANTS[*]}"

for victim in "${TENANTS[@]}"; do
  # Your own tenants have no label proxy and no Org — that data is only ever
  # visible through the admin Org's direct Prometheus data source.
  [[ "$REAL_CLIENTS" != *" $victim "* ]] && continue

  echo
  echo "As client '$victim':"
  PLP="http://prom-label-proxy-$victim:8080"

  # 1. What does a plain, unfiltered query return?
  seen=$(cq --get "$PLP/api/v1/query" --data-urlencode 'query=count by (client) (up)' \
         | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    print(','.join(sorted({s['metric'].get('client','?') for s in d.get('data',{}).get('result',[])})))
except Exception: print('QUERY-FAILED')")

  if [ "$seen" = "$victim" ]; then
    ok "an unfiltered query returns only '$victim'"
  elif [ -z "$seen" ]; then
    ok "an unfiltered query returns nothing yet (no data for '$victim')"
  else
    bad "an unfiltered query exposed: $seen"
  fi

  # 2. Can they name another tenant explicitly?
  for other in "${TENANTS[@]}"; do
    [ "$other" = "$victim" ] && continue

    body=$(cq --get "$PLP/api/v1/query" --data-urlencode "query=up{client=\"$other\"}")
    if grep -q 'conflicting label matcher' <<<"$body"; then
      ok "asking for '$other' by name is rejected outright"
    else
      leaked=$(python3 -c "
import json,sys
try: print(len(json.loads(sys.argv[1]).get('data',{}).get('result',[])))
except Exception: print('?')" "$body")
      [ "$leaked" = "0" ] \
        && ok "asking for '$other' by name returns nothing" \
        || bad "asking for '$other' by name returned $leaked series"
    fi

    # 3. Logs: same question, Loki's own tenancy.
    start=$(( ($(date +%s) - 3600) * 1000000000 ))
    streams=$(cq -H "X-Scope-OrgID: $victim" --get \
      "http://loki:3100/loki/api/v1/query_range" \
      --data-urlencode "query={client=\"$other\"}" --data-urlencode 'limit=5' \
      --data-urlencode "start=$start" \
      | python3 -c "
import json,sys
try: print(len(json.load(sys.stdin).get('data',{}).get('result',[])))
except Exception: print('?')")
    [ "$streams" = "0" ] \
      && ok "logs for '$other' are not readable as '$victim'" \
      || bad "logs for '$other' leaked $streams stream(s) to '$victim'"
  done
done

echo
if [ "$fails" -eq 0 ]; then
  printf '\033[32mTenant isolation holds.\033[0m\n'
else
  printf '\033[31m%d isolation check(s) FAILED — do not give clients logins until this is fixed.\033[0m\n' "$fails"
fi
exit "$fails"
