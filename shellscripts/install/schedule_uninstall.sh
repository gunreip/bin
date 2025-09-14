#!/usr/bin/env bash
set -euo pipefail

SCRIPT_VERSION="v1.0.0"
SERVICE_NAME="laravel_schedule"

usage() {
  cat <<USAGE
laravel scheduler uninstall ($SCRIPT_VERSION)

Nutzung:
  $0 [--service-name <name>]

Optionen:
  --service-name <n>   Service/Timer-Name (Default: $SERVICE_NAME)

Beispiel:
  sudo $0 --service-name tafel_schedule
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --service-name) SERVICE_NAME="$2"; shift;;
    -h|--help) usage; exit 0;;
    *) echo "❌ Unbekannte Option: $1" >&2; usage; exit 1;;
  esac
  shift
done

SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}.service"
TIMER_PATH="/etc/systemd/system/${SERVICE_NAME}.timer"

if [[ $EUID -ne 0 ]]; then
  echo "ℹ️ erhöhe Rechte via sudo …"
  exec sudo -E bash "$0" --service-name "$SERVICE_NAME"
fi

systemctl disable --now "${SERVICE_NAME}.timer" 2>/dev/null || true
systemctl stop "${SERVICE_NAME}.service" 2>/dev/null || true

rm -f "$TIMER_PATH" "$SERVICE_PATH"
systemctl daemon-reload

echo "✅ Scheduler entfernt: ${SERVICE_NAME}"
