#!/bin/bash
set -e

SERVICE_NAME="queue_worker"
QUEUE_NAME="default"
PHP_BIN="/usr/bin/php"

while [[ "$#" -gt 0 ]]; do
    case $1 in
        -p) PROJECT_PATH="$2"; shift ;;
        -u) USERNAME="$2"; shift ;;
        -q) QUEUE_NAME="$2"; shift ;;
        --php) PHP_BIN="$2"; shift ;;
        --service-name) SERVICE_NAME="$2"; shift ;;
        *) echo "Unbekannter Parameter: $1"; exit 1 ;;
    esac
    shift
done

if [[ -z "$PROJECT_PATH" ]] || [[ -z "$USERNAME" ]]; then
    echo "❌ Pfadangabe oder Benutzer fehlt"
    exit 1
fi

SERVICE_PATH="/etc/systemd/system/$SERVICE_NAME.service"

sed \
    -e "s|%QUEUE_NAME%|$QUEUE_NAME|g" \
    -e "s|%PROJECT_PATH%|$PROJECT_PATH|g" \
    -e "s|%USER%|$USERNAME|g" \
    -e "s|%PHP_BIN%|$PHP_BIN|g" \
    <<< "$(cat <<EOF
[Unit]
Description=Laravel Queue Worker (%QUEUE_NAME%) for %PROJECT_PATH%
After=network.target

[Service]
Type=simple
User=%USER%
Group=www-data
WorkingDirectory=%PROJECT_PATH%
ExecStart=%PHP_BIN% %PROJECT_PATH%/artisan queue:work --queue=%QUEUE_NAME% --sleep=3 --tries=3 --max-time=3600 --timeout=120
Restart=always
RestartSec=5
KillMode=process
StandardOutput=journal
StandardError=journal
Environment=APP_ENV=production

[Install]
WantedBy=multi-user.target

EOF
)" > "$SERVICE_PATH"

systemctl daemon-reload
systemctl enable --now "$SERVICE_NAME"
systemctl status "$SERVICE_NAME"
