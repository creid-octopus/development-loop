#!/usr/bin/env bash
# Checks /health/db on the Linux server path in every environment.
#
#   scripts/check-server-health.sh
#
# The local app server containers publish these ports:
#   development 3101, test 3102, production 3103
#
# Each check prints PASS or FAIL. A pass needs status ok, the expected database,
# and the expected app login for that environment. Exit code is the number of
# failures.
#
# Arguments (optional):
#   scripts/check-server-health.sh [env ...]     default: development test production
#
# Environment:
#   HOST   default localhost
#   SCHEME default http

set -uo pipefail

HOST="${HOST:-localhost}"
SCHEME="${SCHEME:-http}"

if [[ $# -gt 0 ]]; then
  ENVS="$*"
else
  ENVS="development test production"
fi

command -v curl >/dev/null || { echo "missing tool: curl" >&2; exit 99; }
command -v jq >/dev/null || { echo "missing tool: jq" >&2; exit 99; }

port_for() {
  case "$1" in
    development) echo 3101 ;;
    test) echo 3102 ;;
    production) echo 3103 ;;
    *) echo "" ;;
  esac
}

failures=0

for env in $ENVS; do
  port="$(port_for "$env")"
  if [[ -z "$port" ]]; then
    echo "FAIL  unknown environment: $env"
    failures=$((failures + 1))
    continue
  fi

  expected_db="developmentloop_${env}"
  expected_user="developmentloop_app_${env}"
  url="${SCHEME}://${HOST}:${port}/health/db"
  label="$(printf '%-12s' "$env")"

  if ! body="$(curl -sS --max-time 5 "$url" 2>&1)"; then
    echo "FAIL  $label no response from $url"
    echo "      $body"
    failures=$((failures + 1))
    continue
  fi

  status="$(jq -r '.status // "missing"' <<<"$body" 2>/dev/null || echo "not json")"
  db="$(jq -r '.database // "missing"' <<<"$body" 2>/dev/null || echo "")"
  user="$(jq -r '.user // "missing"' <<<"$body" 2>/dev/null || echo "")"
  schema="$(jq -r '.schemaVersion // "missing"' <<<"$body" 2>/dev/null || echo "")"

  if [[ "$status" == "ok" && "$db" == "$expected_db" && "$user" == "$expected_user" ]]; then
    echo "PASS  $label port $port, schema $schema, $db, $user"
  else
    echo "FAIL  $label status=$status database=$db user=$user"
    echo "      expected status=ok database=$expected_db user=$expected_user"
    if [[ "$status" == "not json" ]]; then
      echo "      body: ${body:0:120}"
    fi
    failures=$((failures + 1))
  fi
done

echo
if [[ $failures -eq 0 ]]; then
  echo "All checks passed."
else
  echo "$failures check(s) failed."
fi
exit "$failures"
