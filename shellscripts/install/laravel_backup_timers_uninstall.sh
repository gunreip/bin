#!/usr/bin/env bash
set -euo pipefail

SCRIPT_VERSION="v1.0.0"

SERVICE_DB="laravel_backup_db"
SERVICE_CLEAN="laravel_backup_clean"
SERVICE_MONITOR="laravel_backup_monitor"
DRY_RUN=0

usage() {
  cat <<'USAGE'
Laravel Backup systemd Timer Uninstaller
---------------------------------------
Deaktiviert & entfernt Services/Timer für Spatie Backups.

Verwendung:
  sudo ./laravel_backup_timers_uninstall.sh [Optionen]

Optionen:
  --dry-run     Nur anzeigen, nichts löschen
  --version     Version anzeigen
  -h, --help    Hilfe
USAGE
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Bitte mit sudo/root ausführen." >&2
    exit 2
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift;;
    --version) echo "laravel_backup_timers_uninstall.sh ${SCRIPT_VERSION}"; exit 0;;
    -h|--help) usage; exit 0;;
    *) echo "Unbekannte Option: $1"; usage; exit 1;;
  esac
done

require_root

SVC_DB_PATH="/etc/systemd/system/${SERVICE_DB}.service"
SVC_CLEAN_PATH="/etc/systemd/system/${SERVICE_CLEAN}.service"
SVC_MONITOR_PATH="/etc/systemd/system/${SERVICE_MONITOR}.service"
TMR_DB_PATH="/etc/systemd/system/${SERVICE_DB}.timer"
TMR_CLEAN_PATH="/etc/systemd/system/${SERVICE_CLEAN}.timer"
TMR_MON_PATH="/etc/systemd/system/${SERVICE_MONITOR}.timer"

echo "==> Deaktivieren & Entfernen:"
echo "    ${SVC_DB_PATH}"
echo "    ${SVC_CLEAN_PATH}"
echo "    ${SVC_MONITOR_PATH}"
echo "    ${TMR_DB_PATH}"
echo "    ${TMR_CLEAN_PATH}"
echo "    ${TMR_MON_PATH}"

if [[ ${DRY_RUN} -eq 1 ]]; then
  echo "[dry-run] Würde Timer stoppen/disable + Dateien löschen."
  exit 0
fi

# Stop/disable timer
systemctl disable --now "${SERVICE_DB}.timer" "${SERVICE_CLEAN}.timer" "${SERVICE_MONITOR}.timer" || true

# Remove files
rm -f "${SVC_DB_PATH}" "${SVC_CLEAN_PATH}" "${SVC_MONITOR_PATH}" \
      "${TMR_DB_PATH}" "${TMR_CLEAN_PATH}" "${TMR_MON_PATH}"

systemctl daemon-reload
systemctl reset-failed || true

echo "Fertig. Entfernt."
