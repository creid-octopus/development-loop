#!/usr/bin/env bash
# Proves the local loop works, one check at a time, and says what each check means.
#
# Run after `docker compose up --build`:
#   scripts/test-local.sh
#
# Each check prints PASS or FAIL with the reason. Exit code is the number of
# failures. Nothing here changes data except the one item the API check creates.
#
# Environment:
#   APP_URL         default http://localhost:3001
#   PROM_URL        default http://localhost:9090
#   SKIP_TELEMETRY  set to 1 to skip the Prometheus checks

set -uo pipefail

APP_URL="${APP_URL:-http://localhost:3001}"
PROM_URL="${PROM_URL:-http://localhost:9090}"
failures=0

pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; echo "      $2"; failures=$((failures + 1)); }

need() { command -v "$1" >/dev/null || { echo "missing tool: $1" >&2; exit 99; }; }
need curl
need jq

get() { curl -sS --max-time 5 "$@"; }

echo "App:        $APP_URL"
echo "Prometheus: $PROM_URL"
echo

# ── 1. App is up ────────────────────────────────────────────────────────────
# Proves the container started and Express is listening.
if health="$(get "$APP_URL/health")"; then
  pass "app answers /health"
else
  fail "app answers /health" "No response from $APP_URL. Is 'docker compose up' running? Check: docker compose ps"
  echo; echo "Stopping. Nothing else can pass without the app."; exit 1
fi

# ── 2. Database connection ──────────────────────────────────────────────────
# Proves DATABASE_URL (or PG*) is correct and the database accepts the app.
db_status="$(echo "$health" | jq -r '.database.status')"
case "$db_status" in
  ok)             pass "app reaches the database ($(echo "$health" | jq -r '.database | "\(.user)@\(.host):\(.port)/\(.database)"'))" ;;
  "not configured") fail "app reaches the database" "DATABASE_URL and PGHOST are both unset. See README.md > Pointing at a different database." ;;
  *)              fail "app reaches the database" "$(echo "$health" | jq -r '.database.error // "unknown error"')" ;;
esac

# ── 3. Migrations applied ───────────────────────────────────────────────────
# Proves Flyway ran. schemaVersion is the newest migration in flyway_schema_history.
expected="$(ls "$(dirname "$0")/../db/migrations" | grep -E '^V[0-9]' | sed -E 's/^V([0-9._]+)__.*/\1/' | tr '_' '.' | sort -V | tail -n1)"
actual="$(echo "$health" | jq -r '.database.schemaVersion // "none"')"
if [ "$actual" = "$expected" ]; then
  pass "schema is at version $actual (matches db/migrations)"
else
  fail "schema is at version $expected" "The database is at version '$actual'. Run: docker compose run --rm flyway  (or scripts/migrate.sh migrate)"
fi

# ── 4. Readiness endpoint ───────────────────────────────────────────────────
# /health/db returns 503 when a configured database is unreachable. This is the
# endpoint a Kubernetes readiness probe should use.
code="$(get -o /dev/null -w '%{http_code}' "$APP_URL/health/db")"
[ "$code" = "200" ] && pass "/health/db returns 200" || fail "/health/db returns 200" "Got HTTP $code"

# ── 5. Write and read through the API ───────────────────────────────────────
# Proves the app can use the schema the migrations created.
name="test-$(date +%s)"
created="$(get -X POST -H 'Content-Type: application/json' -d "{\"name\":\"$name\"}" "$APP_URL/api/items")"
if echo "$created" | jq -e '.id' >/dev/null 2>&1; then
  pass "POST /api/items created id $(echo "$created" | jq -r '.id')"
else
  fail "POST /api/items" "Response: $created"
fi
if get "$APP_URL/api/items" | jq -e --arg n "$name" 'map(select(.name == $n)) | length == 1' >/dev/null 2>&1; then
  pass "GET /api/items returns the new item"
else
  fail "GET /api/items returns the new item" "The item was not found in the list."
fi

# ── 6. Bad input is rejected, not crashed ───────────────────────────────────
code="$(get -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d '{}' "$APP_URL/api/items")"
[ "$code" = "400" ] && pass "POST /api/items with no name returns 400" || fail "POST /api/items with no name returns 400" "Got HTTP $code"

# ── 7. Failure simulation shows up as errors ────────────────────────────────
# Proves the demo can break the app on purpose, and that reset puts it back.
get "$APP_URL/simulate/errors?rate=1&minutes=1" >/dev/null
sim_code="$(get -o /dev/null -w '%{http_code}' "$APP_URL/")"
[ "$sim_code" = "500" ] && pass "/simulate/errors makes / return 500" || fail "/simulate/errors makes / return 500" "Got HTTP $sim_code"
get "$APP_URL/simulate/reset" >/dev/null
reset_code="$(get -o /dev/null -w '%{http_code}' "$APP_URL/")"
[ "$reset_code" = "200" ] && pass "/simulate/reset restores / to 200" || fail "/simulate/reset restores / to 200" "Got HTTP $reset_code"

# ── 8. Telemetry reaches Prometheus ─────────────────────────────────────────
# Proves: app -> collector -> spanmetrics -> prometheus. The metrics appear
# about 10 to 20 seconds after traffic, so this check waits.
if [ "${SKIP_TELEMETRY:-0}" != "1" ]; then
  echo
  echo "Waiting up to 60s for span metrics to reach Prometheus..."
  q='sum(traces_span_metrics_calls_total)'
  found=0
  for _ in $(seq 1 30); do
    v="$(get --get --data-urlencode "query=$q" "$PROM_URL/api/v1/query" 2>/dev/null | jq -r '.data.result[0].value[1] // empty')"
    if [ -n "$v" ] && [ "$v" != "0" ]; then found=1; break; fi
    sleep 2
  done
  if [ "$found" = 1 ]; then
    pass "Prometheus has span metrics (calls so far: $v)"
  else
    fail "Prometheus has span metrics" "No traces_span_metrics_calls_total after 60s. Check: docker compose logs collector"
  fi

  # The error from check 7 must be counted as an error span. This is the check
  # for the old Datadog gap (50% returned, 8% shown). Retries because the error
  # batch can land one flush after the first span metrics do.
  errq='sum(traces_span_metrics_calls_total{status_code="STATUS_CODE_ERROR"})'
  ev=""
  for _ in $(seq 1 10); do
    ev="$(get --get --data-urlencode "query=$errq" "$PROM_URL/api/v1/query" 2>/dev/null | jq -r '.data.result[0].value[1] // empty')"
    if [ -n "$ev" ] && [ "$ev" != "0" ]; then break; fi
    sleep 2
  done
  if [ -n "$ev" ] && [ "$ev" != "0" ]; then
    pass "failed requests are recorded as error spans (errors so far: $ev)"
  else
    fail "failed requests are recorded as error spans" "Prometheus shows no STATUS_CODE_ERROR calls. The span error status is not being set."
  fi
fi

echo
if [ "$failures" -eq 0 ]; then echo "All checks passed."; else echo "$failures check(s) failed."; fi
exit "$failures"
