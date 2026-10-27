#!/usr/bin/env bash
# Starts, stops, and checks the app on a Linux server without systemd.
# It stands in for a service manager on the local app server containers.
# On a real server, use the systemd unit in developmentloop.service instead.
#
#   bash service.sh start|stop|restart|status|wait
#
# Reads two env files from the folder that holds this script:
#   build.env            written by the build. Version, branch, commit.
#   developmentloop.env  written by Octopus at deploy time. Database and port.
#
# The pid file and log live in STATE_DIR, outside the install folder. Octopus
# clears the install folder on every deployment. The running app must survive
# that, so the next restart can still find and stop it.
#
# Environment:
#   STATE_DIR   default /var/lib/developmentloop
#   NODE_BIN    default node
#   WAIT_SECONDS  default 60. How long "wait" polls /health.

set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${STATE_DIR:-/var/lib/developmentloop}"
NODE_BIN="${NODE_BIN:-node}"
WAIT_SECONDS="${WAIT_SECONDS:-60}"
PID_FILE="$STATE_DIR/app.pid"
LOG_FILE="$STATE_DIR/app.log"

mkdir -p "$STATE_DIR"

# Reads KEY=VALUE lines without shell interpretation. A password with quotes or
# a dollar sign loads as written. systemd reads the same file format.
load_env() {
  local file="$1" line key value
  [[ -f "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    key="${line%%=*}"
    value="${line#*=}"
    export "$key=$value"
  done < "$file"
}

is_running() {
  [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null
}

start() {
  if is_running; then
    echo "Already running (pid $(cat "$PID_FILE"))."
    return 0
  fi
  load_env "$APP_DIR/build.env"
  load_env "$APP_DIR/developmentloop.env"
  cd "$APP_DIR"
  # setsid detaches the app from the Tentacle script so it outlives the deployment step.
  setsid nohup "$NODE_BIN" server.js >> "$LOG_FILE" 2>&1 < /dev/null &
  echo $! > "$PID_FILE"
  echo "Started pid $(cat "$PID_FILE"). Log: $LOG_FILE"
}

stop() {
  if ! is_running; then
    echo "Not running."
    rm -f "$PID_FILE"
    return 0
  fi
  local pid i
  pid="$(cat "$PID_FILE")"
  kill "$pid"
  for i in $(seq 1 20); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.5
  done
  if kill -0 "$pid" 2>/dev/null; then
    echo "Did not stop in 10 seconds. Sending SIGKILL."
    kill -9 "$pid"
  fi
  rm -f "$PID_FILE"
  echo "Stopped."
}

status() {
  if is_running; then
    echo "Running (pid $(cat "$PID_FILE"))."
  else
    echo "Not running."
    return 1
  fi
}

# Polls /health until it answers. Prints the tail of the log when it never does.
wait_healthy() {
  load_env "$APP_DIR/developmentloop.env"
  local port="${PORT:-3000}" i
  for i in $(seq 1 "$WAIT_SECONDS"); do
    if curl -fsS --max-time 2 "http://localhost:${port}/health" >/dev/null 2>&1; then
      echo "Healthy on port ${port} after ${i}s."
      return 0
    fi
    is_running || break
    sleep 1
  done
  echo "FAIL: the app did not answer /health on port ${port}." >&2
  echo "Last log lines:" >&2
  tail -n 20 "$LOG_FILE" >&2 || true
  return 1
}

case "${1:-}" in
  start)   start ;;
  stop)    stop ;;
  restart) stop; start ;;
  status)  status ;;
  wait)    wait_healthy ;;
  *)       echo "Usage: bash service.sh start|stop|restart|status|wait" >&2; exit 2 ;;
esac
