#!/usr/bin/env bash
# Checks /health/db on every track and environment through the local ingress.
#
# Run with the port-forward open:
#   kubectl port-forward svc/ingress-nginx-controller 8080:8080 -n ingress-nginx
#   scripts/check-k8s-health.sh
#
# Each check prints PASS or FAIL. A pass needs status ok, the expected database,
# and the expected app login for that environment. Exit code is the number of
# failures.
#
# Arguments (optional):
#   scripts/check-k8s-health.sh [env ...]     default: development test production
#
# Environment:
#   TRACKS   default "raw kustomize helm"
#   DOMAIN   default localtest.me
#   PORT     default 8080 (set to empty for a real cluster on port 80 or 443)
#   SCHEME   default http

set -uo pipefail

TRACKS="${TRACKS:-raw kustomize helm}"
DOMAIN="${DOMAIN:-localtest.me}"
PORT="${PORT-8080}"
SCHEME="${SCHEME:-http}"

if [[ $# -gt 0 ]]; then
  ENVS="$*"
else
  ENVS="development test production"
fi

command -v curl >/dev/null || { echo "missing tool: curl" >&2; exit 99; }
command -v jq >/dev/null || { echo "missing tool: jq" >&2; exit 99; }

failures=0
port_suffix="${PORT:+:$PORT}"

for env in $ENVS; do
  expected_db="developmentloop_${env}"
  expected_user="developmentloop_app_${env}"
  echo "== $env"
  for track in $TRACKS; do
    host="${track}-${env}.developmentloop.${DOMAIN}"
    url="${SCHEME}://${host}${port_suffix}/health/db"
    label="$(printf '%-10s' "$track")"

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
      echo "PASS  $label schema $schema, $db, $user"
    else
      echo "FAIL  $label status=$status database=$db user=$user"
      echo "      expected status=ok database=$expected_db user=$expected_user"
      if [[ "$status" == "not json" ]]; then
        echo "      body: ${body:0:120}"
      fi
      failures=$((failures + 1))
    fi
  done
done

echo
if [[ $failures -eq 0 ]]; then
  echo "All checks passed."
else
  echo "$failures check(s) failed."
fi
exit "$failures"
