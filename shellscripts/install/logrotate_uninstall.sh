#!/usr/bin/env bash
set -euo pipefail

SCRIPT_VERSION="v1.0.0"

usage() {
  cat <<'USAGE'
logrotate_uninstall.sh - Remove logrotate config for Laravel logs
Version: v1.0.0

Usage:
  sudo ./logrotate_uninstall.sh [-p <project_path>]

Defaults:
  -p    current directory
USAGE
}

PROJECT_PATH="$(pwd)"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0;;
    -p) PROJECT_PATH="$2"; shift 2;;
    *) echo "Unknown option: $1" >&2; usage; exit 2;;
  esac
done

PROJECT_NAME="$(basename "${PROJECT_PATH}")"
CONFIG_FILE="/etc/logrotate.d/laravel_${PROJECT_NAME}"

echo "🗑️  Removing ${CONFIG_FILE} (v${SCRIPT_VERSION})"
if [[ "$EUID" -ne 0 ]]; then
  echo "❌ Please run with sudo/root" >&2
  exit 3
fi

if [[ -f "${CONFIG_FILE}" ]]; then
  rm -f "${CONFIG_FILE}"
  echo "✅ Removed ${CONFIG_FILE}"
else
  echo "ℹ️  Not found: ${CONFIG_FILE}"
fi

echo "🔁 Reloading logrotate is not required; it runs from cron/systemd timers automatically."
