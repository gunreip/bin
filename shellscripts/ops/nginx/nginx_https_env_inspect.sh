#!/usr/bin/env bash
SCRIPT_VERSION="v0.2.0"

set -euo pipefail

PROJECT_PATH="$(pwd)"
CERT_DIR="${HOME}/.local/share/mkcert"
NGINX_DIR="/etc/nginx"
HOSTS_FILE="/etc/hosts"

# Parameter
while [[ $# -gt 0 ]]; do
    case "$1" in
        -p)
            PROJECT_PATH="$2"
            shift 2
            ;;
        --version)
            printf '%s\n' "$SCRIPT_VERSION"
            exit 0
            ;;
        *)
            printf 'Unbekannter Parameter: %s\n' "$1" >&2
            exit 1
            ;;
    esac
done

ENV_FILE="${PROJECT_PATH}/.env"
if [[ ! -f "$ENV_FILE" ]]; then
    printf 'Fehler: Keine .env im Pfad %s gefunden.\n' "$PROJECT_PATH" >&2
    exit 2
fi

DOMAIN_LINE=$(grep -E '^APP_URL=' "$ENV_FILE" || true)
APP_URL=${DOMAIN_LINE#*=}
APP_DOMAIN=${APP_URL#*://}
ALT_DOMAIN="www.${APP_DOMAIN}"

printf 'Projekt: %s\n' "$(basename "$PROJECT_PATH")"
printf 'Pfad: %s\n' "$PROJECT_PATH"
printf 'Domain: %s\n' "$APP_DOMAIN"
printf 'Alternativ-Domain: %s\n' "$ALT_DOMAIN"
printf '\n'

printf '🔐 mkcert-Zertifikate (alle):\n'
if ls "$CERT_DIR"/*.pem &>/dev/null; then
    for f in "$CERT_DIR"/*.pem; do
        printf '  %s\n' "$(basename "$f")"
        openssl x509 -in "$f" -noout -dates 2>/dev/null || true
    done
else
    printf '  Keine Zertifikate gefunden.\n'
fi
printf '\n'

printf '📒 /etc/hosts:\n'
grep -E "${APP_DOMAIN}|${ALT_DOMAIN}" "$HOSTS_FILE" || printf '  Keine relevanten Einträge.\n'
printf '\n'

printf '🧰 nginx Konfiguration (server_name):\n'
if [[ -d "$NGINX_DIR/sites-enabled" ]]; then
    grep -r 'server_name' "$NGINX_DIR/sites-enabled" || printf '  Keine server_name Einträge gefunden.\n'
else
    printf '  nginx sites-enabled nicht gefunden.\n'
fi
printf '\n'

printf '🧪 Port-Status (80/443):\n'
sudo ss -tuln | grep -E ':80|:443' || printf '  Keine Prozesse auf Port 80/443 gefunden.\n'
printf '\n'

printf '🌐 curl https://%s:\n' "$APP_DOMAIN"
curl -skIL "https://${APP_DOMAIN}" | head -n 5 || printf '  Verbindung zu %s fehlgeschlagen.\n' "$APP_DOMAIN"
printf '\n'
printf '🌐 curl https://%s:\n' "$ALT_DOMAIN"
curl -skIL "https://${ALT_DOMAIN}" | head -n 5 || printf '  Verbindung zu %s fehlgeschlagen.\n' "$ALT_DOMAIN"
