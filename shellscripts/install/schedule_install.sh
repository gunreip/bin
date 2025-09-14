#!/usr/bin/env bash
set -euo pipefail

SCRIPT_VERSION="v1.0.0"

PROJECT_PATH=""
SERVICE_NAME="laravel_schedule"
RUN_USER="${USER:-$(id -un)}"
RUN_GROUP="www-data"
PHP_BIN="$(command -v php || echo /usr/bin/php)"
ON_CALENDAR="*-*-* *:*:00" # jede Minute

usage() {
  cat <<USAGE
laravel scheduler installer ($SCRIPT_VERSION)

Nutzung:
  $0 -p <project_path> [-u <user>] [--group <group>] [--php <php_bin>] [--service-name <name>] [--calendar "<OnCalendar expr>"]

Optionen:
  -p <path>            Pfad zum Laravel-Projekt (erforderlich)
  -u <user>            Systembenutzer für den Job (Default: $RUN_USER)
  --group <group>      Gruppe (Default: $RUN_GROUP)
  --php <php_bin>      PHP-Binary (Default: $PHP_BIN)
  --service-name <n>   Name für Service/Timer (Default: $SERVICE_NAME)
  --calendar "<expr>"  systemd OnCalendar-Ausdruck (Default: "$ON_CALENDAR")
  --dry-run            Nur anzeigen, nichts schreiben
  --uninstall          Statt Installation: Service/Timer entfernen (Alias zu schedule_uninstall.sh)
  -h, --help           Hilfe

Beispiel:
  sudo $0 -p ~/code/tafel_wesseling -u $USER --service-name tafel_schedule
USAGE
}

DRY_RUN="false"
DO_UNINSTALL="false"

# Argumente parsen
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p) PROJECT_PATH="$2"; shift;;
    -u) RUN_USER="$2"; shift;;
    --group) RUN_GROUP="$2"; shift;;
    --php) PHP_BIN="$2"; shift;;
    --service-name) SERVICE_NAME="$2"; shift;;
    --calendar) ON_CALENDAR="$2"; shift;;
    --dry-run) DRY_RUN="true";;
    --uninstall) DO_UNINSTALL="true";;
    -h|--help) usage; exit 0;;
    *) echo "❌ Unbekannte Option: $1" >&2; usage; exit 1;;
  esac
  shift
done

# Uninstall-Shortcut
if [[ "$DO_UNINSTALL" == "true" ]]; then
  exec "$(dirname "$0")/schedule_uninstall.sh" --service-name "$SERVICE_NAME"
fi

if [[ -z "$PROJECT_PATH" ]]; then
  echo "❌ Projektpfad fehlt. Verwende -p <project_path>." >&2
  usage; exit 2
fi

# Normalisieren
PROJECT_PATH="$(readlink -f "$PROJECT_PATH" || echo "$PROJECT_PATH")"

# Basic Checks
if [[ ! -d "$PROJECT_PATH" ]]; then
  echo "❌ Projektverzeichnis nicht gefunden: $PROJECT_PATH" >&2
  exit 2
fi
if [[ ! -f "$PROJECT_PATH/artisan" ]]; then
  echo "❌ Keine 'artisan' im Projekt gefunden: $PROJECT_PATH" >&2
  exit 2
fi
if [[ ! -f "$PROJECT_PATH/.env" ]]; then
  echo "❌ .env fehlt in $PROJECT_PATH – Abbruch (falscher Ordner?)" >&2
  exit 2
fi
if [[ ! -x "$PHP_BIN" ]]; then
  echo "❌ PHP nicht gefunden/ausführbar: $PHP_BIN" >&2
  exit 2
fi

SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}.service"
TIMER_PATH="/etc/systemd/system/${SERVICE_NAME}.timer"

echo "ℹ️ Installiere systemd Service/Timer für Laravel Scheduler"
echo "   Service: $SERVICE_PATH"
echo "   Timer:   $TIMER_PATH"
echo "   User/Grp: ${RUN_USER}:${RUN_GROUP}"
echo "   PHP: $PHP_BIN"
echo "   Projekt: $PROJECT_PATH"
echo "   OnCalendar: $ON_CALENDAR"

SERVICE_UNIT="[Unit]
Description=Laravel Scheduler (${SERVICE_NAME}) for ${PROJECT_PATH}
After=network.target

[Service]
Type=oneshot
User=${RUN_USER}
Group=${RUN_GROUP}
WorkingDirectory=${PROJECT_PATH}
ExecStart=${PHP_BIN} ${PROJECT_PATH}/artisan schedule:run
Nice=10
IOSchedulingClass=idle
# Hardening
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
"

TIMER_UNIT="[Unit]
Description=Run Laravel schedule:run every minute (${SERVICE_NAME})

[Timer]
OnCalendar=${ON_CALENDAR}
Persistent=true
Unit=${SERVICE_NAME}.service
AccuracySec=1s

[Install]
WantedBy=timers.target
"

if [[ "$DRY_RUN" == "true" ]]; then
  echo "---- DRY RUN: Service Unit ----"
  echo "$SERVICE_UNIT"
  echo "---- DRY RUN: Timer Unit ----"
  echo "$TIMER_UNIT"
  echo "✅ Dry-Run abgeschlossen."
  exit 0
fi

# Schreiben (root)
if [[ $EUID -ne 0 ]]; then
  echo "ℹ️ erhöhe Rechte via sudo …"
  exec sudo -E bash "$0" -p "$PROJECT_PATH" -u "$RUN_USER" --group "$RUN_GROUP" --php "$PHP_BIN" --service-name "$SERVICE_NAME" --calendar "$ON_CALENDAR"
fi

backup_if_exists() {
  local f="$1"
  if [[ -f "$f" ]]; then
    cp -a "$f" "${f}.bak-$(date +%Y%m%d-%H%M%S)"
  fi
}

backup_if_exists "$SERVICE_PATH"
backup_if_exists "$TIMER_PATH"

printf '%s\n' "$SERVICE_UNIT" > "$SERVICE_PATH"
printf '%s\n' "$TIMER_UNIT" > "$TIMER_PATH"

chmod 0644 "$SERVICE_PATH" "$TIMER_PATH"

systemctl daemon-reload
systemctl enable --now "${SERVICE_NAME}.timer"

echo "✅ Scheduler eingerichtet. Status:"
systemctl status --no-pager "${SERVICE_NAME}.timer" || true
echo "👉 Logs ansehen mit: journalctl -u ${SERVICE_NAME}.service --since '1 hour ago' --no-pager"
