#!/usr/bin/env bash
# Runs Flyway Community against any Postgres database.
#
# The connection comes from the same variables the app uses, so pointing this
# at a different database is a change of environment, not of code.
#   DATABASE_URL                                  postgres://user:pass@host:5432/db
#   PGHOST PGPORT PGUSER PGPASSWORD PGDATABASE    standard libpq variables
#
# Usage:
#   scripts/migrate.sh [info|validate|migrate]      default: info
#
# `info` is read-only. It shows which migrations are applied and which are pending.
# Run it before `migrate` to see what is about to change.
#
# How Flyway runs. The first match wins:
#   1. FLYWAY_MODE=local, or a `flyway` command on your PATH.
#      Install on macOS with: brew install flyway
#   2. A container. The default image is octopuslabs/flyway-workertools:latest.
#      It is the same kind of image Octopus uses as an execution container, so
#      a later process template runs the same tool. The script sets the
#      entrypoint to `flyway`, so any image with Flyway on its PATH works.
#      Docker is asked for linux/amd64. On Apple Silicon Docker runs that under
#      emulation if the image has no arm64 build. Set FLYWAY_PLATFORM= (empty)
#      to let Docker choose.
#
# A container cannot reach your machine as "localhost". When the host is
# localhost or 127.0.0.1 this script swaps in host.docker.internal. Set
# FLYWAY_DOCKER_NETWORK=<name> to join a Docker network instead.
#
# Environment:
#   FLYWAY_MODE            local or docker (default: local if flyway is installed)
#   FLYWAY_IMAGE           default octopuslabs/flyway-workertools:latest
#   FLYWAY_PLATFORM        default linux/amd64. Empty means "let Docker choose"
#   FLYWAY_LOCATIONS       default db/migrations (relative to the repo root)
#   FLYWAY_DOCKER_NETWORK  optional Docker network to join

set -euo pipefail

command_name="${1:-info}"
case "$command_name" in info|validate|migrate) ;; *) echo "usage: $0 [info|validate|migrate]" >&2; exit 2 ;; esac

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
locations="${FLYWAY_LOCATIONS:-db/migrations}"
image="${FLYWAY_IMAGE:-octopuslabs/flyway-workertools:latest}"

# ── Work out host, port, database, user, password ────────────────────────────
if [ -n "${DATABASE_URL:-}" ]; then
  # postgres://user:pass@host:port/db  (no percent-decoding of the password)
  rest="${DATABASE_URL#*://}"
  creds="${rest%%@*}"
  hostpart="${rest#*@}"
  user="${creds%%:*}"
  password="${creds#*:}"
  hostport="${hostpart%%/*}"
  database="${hostpart#*/}"
  database="${database%%\?*}"
  host="${hostport%%:*}"
  port="${hostport#*:}"
  [ "$port" = "$hostport" ] && port=5432
else
  host="${PGHOST:?Set DATABASE_URL or PGHOST}"
  port="${PGPORT:-5432}"
  user="${PGUSER:?Set PGUSER}"
  password="${PGPASSWORD:-}"
  database="${PGDATABASE:-$user}"
fi

mode="${FLYWAY_MODE:-}"
if [ -z "$mode" ]; then
  if command -v flyway >/dev/null 2>&1; then mode="local"; else mode="docker"; fi
fi

# ── Local install ───────────────────────────────────────────────────────────
if [ "$mode" = "local" ]; then
  command -v flyway >/dev/null 2>&1 || { echo "flyway not found. Install it (brew install flyway) or set FLYWAY_MODE=docker." >&2; exit 2; }
  echo "Flyway $command_name (local install: $(command -v flyway))"
  echo "  database:  $user@$host:$port/$database"
  echo "  migrations: $locations"
  echo
  # The password goes in an environment variable so it never shows in `ps`.
  FLYWAY_PASSWORD="$password" exec flyway \
    -url="jdbc:postgresql://${host}:${port}/${database}" -user="$user" \
    -locations="filesystem:$repo_root/$locations" \
    -connectRetries=10 \
    "$command_name"
fi

# ── Container ───────────────────────────────────────────────────────────────
if [ -z "${FLYWAY_DOCKER_NETWORK:-}" ]; then
  case "$host" in localhost|127.0.0.1) host="host.docker.internal" ;; esac
fi

url="jdbc:postgresql://${host}:${port}/${database}"
platform="${FLYWAY_PLATFORM-linux/amd64}"

echo "Flyway $command_name (container)"
echo "  image:     $image${platform:+ ($platform)}"
echo "  database:  $user@$host:$port/$database"
echo "  migrations: $locations"
echo

docker_args=(run --rm -v "$repo_root/$locations:/flyway/sql:ro")
[ -n "$platform" ] && docker_args+=(--platform "$platform")
[ -n "${FLYWAY_DOCKER_NETWORK:-}" ] && docker_args+=(--network "$FLYWAY_DOCKER_NETWORK")
# Linux needs this line for host.docker.internal. Docker Desktop ignores it.
docker_args+=(--add-host=host.docker.internal:host-gateway)

# The password goes in an environment variable so it never shows in `ps`.
exec docker "${docker_args[@]}" \
  -e FLYWAY_PASSWORD="$password" \
  --entrypoint flyway \
  "$image" \
  -url="$url" -user="$user" \
  -locations=filesystem:/flyway/sql \
  -connectRetries=10 \
  "$command_name"
