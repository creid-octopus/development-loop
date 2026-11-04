#!/usr/bin/env bash
# Checks /health/db on every track and environment through the local ingress,
# and on every tenant of the tenanted tracks.
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
#   TRACKS          default "raw kustomize helm"
#   TENANTS         tenant abbreviations (Tenant.Abbreviation), default "apex cannon radiant".
#                   Set to empty to skip the tenant checks.
#   TENANT_TRACKS   tracks that deploy to tenants, default "helm"
#   DOMAIN          default localtest.me
#   PORT            default 8080 (set to empty for a real cluster on port 80 or 443)
#   SCHEME          default http
#
# Tenant names follow docs/database-roles.md: host <track>-<tenant>-<env>,
# database developmentloop_<tenant>_<env>, login developmentloop_app_<tenant>_<env>.

set -uo pipefail

TRACKS="${TRACKS:-raw kustomize helm}"
TENANTS="${TENANTS-apex cannon radiant}"
TENANT_TRACKS="${TENANT_TRACKS:-helm}"
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

# check <label> <host> <expected database> <expected app login>
check() {
  local label url body status db user schema
  label="$(printf '%-16s' "$1")"
  url="${SCHEME}://$2${port_suffix}/health/db"

  if ! body="$(curl -sS --max-time 5 "$url" 2>&1)"; then
    echo "FAIL  $label no response from $url"
    echo "      $body"
    failures=$((failures + 1))
    return
  fi

  status="$(jq -r '.status // "missing"' <<<"$body" 2>/dev/null || echo "not json")"
  db="$(jq -r '.database // "missing"' <<<"$body" 2>/dev/null || echo "")"
  user="$(jq -r '.user // "missing"' <<<"$body" 2>/dev/null || echo "")"
  schema="$(jq -r '.schemaVersion // "missing"' <<<"$body" 2>/dev/null || echo "")"

  if [[ "$status" == "ok" && "$db" == "$3" && "$user" == "$4" ]]; then
    echo "PASS  $label schema $schema, $db, $user"
  else
    echo "FAIL  $label status=$status database=$db user=$user"
    echo "      expected status=ok database=$3 user=$4"
    if [[ "$status" == "not json" ]]; then
      echo "      body: ${body:0:120}"
    fi
    failures=$((failures + 1))
  fi
}

for env in $ENVS; do
  echo "== $env"
  for track in $TRACKS; do
    check "$track" "${track}-${env}.developmentloop.${DOMAIN}" \
      "developmentloop_${env}" "developmentloop_app_${env}"
  done
  for track in $TENANT_TRACKS; do
    for tenant in $TENANTS; do
      check "$track $tenant" "${track}-${tenant}-${env}.developmentloop.${DOMAIN}" \
        "developmentloop_${tenant}_${env}" "developmentloop_app_${tenant}_${env}"
    done
  done
done

echo
if [[ $failures -eq 0 ]]; then
  echo "All checks passed."
else
  echo "$failures check(s) failed."
fi
exit "$failures"
