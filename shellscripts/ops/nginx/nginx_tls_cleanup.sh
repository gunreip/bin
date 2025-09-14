#!/usr/bin/env bash

#!/usr/bin/env bash
set -euo pipefail
DOMAIN="${1:-tafel-wesseling.local}"
CONF_AVAIL="/etc/nginx/sites-available/${DOMAIN}.conf"
CONF_ENABLED="/etc/nginx/sites-enabled/${DOMAIN}.conf"
CRT_PATH="/etc/nginx/ssl/${DOMAIN}.crt"
KEY_PATH="/etc/nginx/ssl/${DOMAIN}.key"
WEBROOT="/var/www/${DOMAIN}"

sudo rm -f "$CONF_ENABLED" || true
sudo rm -f "$CONF_AVAIL" || true
sudo rm -f "$CRT_PATH" "$KEY_PATH" || true
sudo rm -rf "$WEBROOT" || true

sudo nginx -t && sudo systemctl restart nginx || true

echo "Aufräumen abgeschlossen."
