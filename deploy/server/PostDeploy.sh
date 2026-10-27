#!/usr/bin/env bash
# Octopus runs this file after it extracts the package. It restarts the app and
# waits for /health. A failed wait fails the deployment.
#
# Octopus finds the file by name. Do not rename it.

set -euo pipefail

# Octopus sets the install folder for a package step. Fall back to this script's folder.
APP_DIR=""
if command -v get_octopusvariable >/dev/null 2>&1; then
  APP_DIR="$(get_octopusvariable "Octopus.Action.Package.CustomInstallationDirectory" 2>/dev/null || true)"
fi
[[ -n "$APP_DIR" && -d "$APP_DIR" ]] || APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$APP_DIR"

# The env file holds the database password. Only the service account reads it.
chmod 600 developmentloop.env

# Real servers run the app under systemd. The local app server containers have no
# systemd, so service.sh stands in.
if command -v systemctl >/dev/null 2>&1 && systemctl cat developmentloop.service >/dev/null 2>&1; then
  echo "Restarting with systemd."
  systemctl restart developmentloop.service
else
  echo "systemd unit not found. Restarting with service.sh."
  bash service.sh restart
fi

bash service.sh wait
