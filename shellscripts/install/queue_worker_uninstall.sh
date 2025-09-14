#!/bin/bash
set -e

SERVICE_NAME="queue_worker"

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --service-name) SERVICE_NAME="$2"; shift ;;
        *) echo "Unbekannter Parameter: $1"; exit 1 ;;
    esac
    shift
done

systemctl disable --now "$SERVICE_NAME"
rm -f "/etc/systemd/system/$SERVICE_NAME.service"
systemctl daemon-reload

echo "✅ Service $SERVICE_NAME entfernt"
