#!/usr/bin/env bash
set -euo pipefail

SCRIPT_VERSION="v1.0.0"

# Defaults
PROJECT_PATH=""
PHP_BIN="/usr/bin/php"
SERVICE_DB="laravel_backup_db"
SERVICE_CLEAN="laravel_backup_clean"
SERVICE_MONITOR="laravel_backup_monitor"
USER_NAME="$(id -un)"
GROUP_NAME="www-data"
DB_TIME="17:30:00"
CLEAN_TIME="17:45:00"
MONITOR_TIME="18:00:00"
DELAY="5m"          # RandomizedDelaySec (use 0 to disable)
ONLY_DB=1
DRY_RUN=0

usage() {
  cat <<'USAGE'
Laravel Backup systemd Timer Installer
-------------------------------------
Installiert drei systemd Services + Timer für Spatie Backups (DB, Clean, Monitor) mit Catch-Up.

Verwendung:
  sudo ./laravel_backup_timers_install.sh -p <projektpfad> [Optionen]

Pflicht:
  -p, --path <pfad>         Projekt-Root (enthält artisan)

Optionen:
      --php <pfad>          PHP-Binary (Default: /usr/bin/php)
      --user <name>         Service-User (Default: aktueller Nutzer)
      --group <name>        Service-Gruppe (Default: www-data)
      --db-time <HH:MM>     Uhrzeit für DB-Backup (Default: 17:30)
      --clean-time <HH:MM>  Uhrzeit für Clean (Default: 17:45)
      --monitor-time <HH:MM>Uhrzeit für Monitor (Default: 18:00)
      --delay <Dauer>       RandomizedDelaySec, z. B. 5m / 0 zum Deaktivieren (Default: 5m)
      --full                Full-Backup (DB + Files). Default ist --only-db.
      --dry-run             Nur anzeigen, nichts schreiben/aktivieren.
      --version             Version anzeigen
  -h, --help                Hilfe

Hinweis:
- Die Timer sind mit Persistent=true versehen (Catch-Up nach Standby/Neustart).
- Wenn du Backups zusätzlich in Laravel (routes/console.php) planst, kann es zu Doppel-Starts kommen.
USAGE
}

# Root erforderlich
require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Bitte mit sudo/root ausführen." >&2
    exit 2
  fi
}

# Parse args
if [[ $# -eq 0 ]]; then usage; exit 1; fi
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--path) PROJECT_PATH="$2"; shift 2;;
    --php) PHP_BIN="$2"; shift 2;;
    --user) USER_NAME="$2"; shift 2;;
    --group) GROUP_NAME="$2"; shift 2;;
    --db-time) DB_TIME="$2:00"; [[ "$2" =~ ^[0-2][0-9]:[0-5][0-9]$ ]] || { echo "Ungültige --db-time: $2"; exit 1; }; shift 2;;
    --clean-time) CLEAN_TIME="$2:00"; [[ "$2" =~ ^[0-2][0-9]:[0-5][0-9]$ ]] || { echo "Ungültige --clean-time: $2"; exit 1; }; shift 2;;
    --monitor-time) MONITOR_TIME="$2:00"; [[ "$2" =~ ^[0-2][0-9]:[0-5][0-9]$ ]] || { echo "Ungültige --monitor-time: $2"; exit 1; }; shift 2;;
    --delay) DELAY="$2"; shift 2;;
    --full) ONLY_DB=0; shift;;
    --dry-run) DRY_RUN=1; shift;;
    --version) echo "laravel_backup_timers_install.sh ${SCRIPT_VERSION}"; exit 0;;
    -h|--help) usage; exit 0;;
    *) echo "Unbekannte Option: $1"; usage; exit 1;;
  esac
done

# Checks
if [[ -z "${PROJECT_PATH}" ]]; then
  echo "Fehler: Projektpfad angeben mit -p/--path." >&2
  exit 1
fi

# Normalisieren
if command -v realpath >/dev/null 2>&1; then
  PROJECT_PATH="$(realpath "${PROJECT_PATH}")"
fi

ARTISAN="${PROJECT_PATH}/artisan"
if [[ ! -f "${ARTISAN}" ]]; then
  echo "Fehler: ${ARTISAN} nicht gefunden." >&2
  exit 1
fi

if [[ ! -x "${PHP_BIN}" ]]; then
  echo "Warnung: PHP-Binary ${PHP_BIN} ist nicht ausführbar – ich versuche es trotzdem." >&2
fi

require_root

CMD_DB="${PHP_BIN} ${ARTISAN} backup:run"
if [[ ${ONLY_DB} -eq 1 ]]; then
  CMD_DB="${CMD_DB} --only-db"
fi
CMD_CLEAN="${PHP_BIN} ${ARTISAN} backup:clean"
CMD_MONITOR="${PHP_BIN} ${ARTISAN} backup:monitor"

read -r -d '' SERVICE_DB_CONTENT <<EOF
[Unit]
Description=Laravel Backup DB (Spatie) – ${PROJECT_PATH}

[Service]
Type=oneshot
User=${USER_NAME}
Group=${GROUP_NAME}
ExecStart=${CMD_DB}
Nice=10
IOSchedulingClass=idle
ProtectSystem=full
ProtectHome=no
NoNewPrivileges=true
EOF

read -r -d '' SERVICE_CLEAN_CONTENT <<EOF
[Unit]
Description=Laravel Backup Clean (Spatie) – ${PROJECT_PATH}

[Service]
Type=oneshot
User=${USER_NAME}
Group=${GROUP_NAME}
ExecStart=${CMD_CLEAN}
Nice=10
IOSchedulingClass=idle
ProtectSystem=full
ProtectHome=no
NoNewPrivileges=true
EOF

read -r -d '' SERVICE_MONITOR_CONTENT <<EOF
[Unit]
Description=Laravel Backup Monitor (Spatie) – ${PROJECT_PATH}

[Service]
Type=oneshot
User=${USER_NAME}
Group=${GROUP_NAME}
ExecStart=${CMD_MONITOR}
Nice=10
IOSchedulingClass=idle
ProtectSystem=full
ProtectHome=no
NoNewPrivileges=true
EOF

randomized="RandomizedDelaySec=${DELAY}"
if [[ "${DELAY}" == "0" || "${DELAY}" == "0s" ]]; then
  randomized=""
fi

read -r -d '' TIMER_DB_CONTENT <<EOF
[Unit]
Description=Timer: Laravel DB Backup daily ${DB_TIME} (with catch-up)

[Timer]
OnCalendar=*-*-* ${DB_TIME}
Persistent=true
${randomized}
Unit=${SERVICE_DB}.service
AccuracySec=1s

[Install]
WantedBy=timers.target
EOF

read -r -d '' TIMER_CLEAN_CONTENT <<EOF
[Unit]
Description=Timer: Laravel Backup Clean daily ${CLEAN_TIME} (with catch-up)

[Timer]
OnCalendar=*-*-* ${CLEAN_TIME}
Persistent=true
${randomized}
Unit=${SERVICE_CLEAN}.service
AccuracySec=1s

[Install]
WantedBy=timers.target
EOF

read -r -d '' TIMER_MONITOR_CONTENT <<EOF
[Unit]
Description=Timer: Laravel Backup Monitor daily ${MONITOR_TIME} (with catch-up)

[Timer]
OnCalendar=*-*-* ${MONITOR_TIME}
Persistent=true
${randomized}
Unit=${SERVICE_MONITOR}.service
AccuracySec=1s

[Install]
WantedBy=timers.target
EOF

# Zielpfade
SVC_DB_PATH="/etc/systemd/system/${SERVICE_DB}.service"
SVC_CLEAN_PATH="/etc/systemd/system/${SERVICE_CLEAN}.service"
SVC_MONITOR_PATH="/etc/systemd/system/${SERVICE_MONITOR}.service"
TMR_DB_PATH="/etc/systemd/system/${SERVICE_DB}.timer"
TMR_CLEAN_PATH="/etc/systemd/system/${SERVICE_CLEAN}.timer"
TMR_MON_PATH="/etc/systemd/system/${SERVICE_MONITOR}.timer"

echo "==> Projekt: ${PROJECT_PATH}"
echo "==> User/Group: ${USER_NAME}:${GROUP_NAME}"
echo "==> Zeiten: DB ${DB_TIME}, Clean ${CLEAN_TIME}, Monitor ${MONITOR_TIME} (Delay=${DELAY})"
echo "==> Modus: $([[ ${ONLY_DB} -eq 1 ]] && echo 'DB-only' || echo 'FULL')"
echo "==> Dateien:"
echo "    ${SVC_DB_PATH}"
echo "    ${SVC_CLEAN_PATH}"
echo "    ${SVC_MONITOR_PATH}"
echo "    ${TMR_DB_PATH}"
echo "    ${TMR_CLEAN_PATH}"
echo "    ${TMR_MON_PATH}"

if [[ ${DRY_RUN} -eq 1 ]]; then
  echo "[dry-run] Würde Services/Timer schreiben & aktivieren."
  exit 0
fi

# Schreiben
printf '%s\n' "${SERVICE_DB_CONTENT}" > "${SVC_DB_PATH}"
printf '%s\n' "${SERVICE_CLEAN_CONTENT}" > "${SVC_CLEAN_PATH}"
printf '%s\n' "${SERVICE_MONITOR_CONTENT}" > "${SVC_MONITOR_PATH}"
printf '%s\n' "${TIMER_DB_CONTENT}" > "${TMR_DB_PATH}"
printf '%s\n' "${TIMER_CLEAN_CONTENT}" > "${TMR_CLEAN_PATH}"
printf '%s\n' "${TIMER_MONITOR_CONTENT}" > "${TMR_MON_PATH}"

# Aktivieren
systemctl daemon-reload
systemctl enable --now "${SERVICE_DB}.timer" "${SERVICE_CLEAN}.timer" "${SERVICE_MONITOR}.timer"

echo "Fertig. Timer aktiv:"
systemctl list-timers | grep -E "${SERVICE_DB}|${SERVICE_CLEAN}|${SERVICE_MONITOR}" || true
