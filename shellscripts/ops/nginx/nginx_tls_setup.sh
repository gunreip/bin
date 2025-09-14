#!/usr/bin/env bash

#!/usr/bin/env bash
set -euo pipefail

DOMAIN="tafel-wesseling.local"
WEBROOT=""
CRT_IN=""
KEY_IN=""
HTTPS_PORT="443"
PHPFPM="0"
ONLY_CONF="0"
ASSUME_YES="0"

usage() {
  echo "Usage: $0 [-d domain] [-r webroot] [-k key] [-c cert] [-P https_port] [-p] [-n] [-y]" >&2
  exit 1
}

while getopts ":d:r:k:c:P:pny" opt; do
  case $opt in
    d) DOMAIN="$OPTARG" ;;
    r) WEBROOT="$OPTARG" ;;
    k) KEY_IN="$OPTARG" ;;
    c) CRT_IN="$OPTARG" ;;
    P) HTTPS_PORT="$OPTARG" ;;
    p) PHPFPM="1" ;;
    n) ONLY_CONF="1" ;;
    y) ASSUME_YES="1" ;;
    *) usage ;;
  esac
done

if ! command -v nginx >/dev/null 2>&1; then
  echo "NGINX wird installiert..."
  sudo apt update && sudo apt install -y nginx
fi

sudo mkdir -p /etc/nginx/ssl
sudo mkdir -p /var/www

if [[ -z "$WEBROOT" ]]; then
  WEBROOT="/var/www/${DOMAIN}/public"
fi
sudo mkdir -p "$WEBROOT"
sudo chown -R $USER:$USER "/var/www/${DOMAIN}" || true

CONF_AVAIL="/etc/nginx/sites-available/${DOMAIN}.conf"
CONF_ENABLED="/etc/nginx/sites-enabled/${DOMAIN}.conf"

# Basis-Config schreiben
sudo tee "$CONF_AVAIL" >/dev/null <<CONF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
    return 301 https://\$host\$request_uri;
}

server {
    listen ${HTTPS_PORT} ssl http2;
    listen [::]:${HTTPS_PORT} ssl http2;
    server_name ${DOMAIN};

    root ${WEBROOT};
    index index.html index.htm index.php;

    ssl_certificate     /etc/nginx/ssl/${DOMAIN}.crt;
    ssl_certificate_key /etc/nginx/ssl/${DOMAIN}.key;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;

    location / {
        try_files \$uri \$uri/ /index.html;
    }
CONF

# PHP-FPM Block optional ergänzen
if [[ "$PHPFPM" == "1" ]]; then
  # einfachen Socket heuristisch finden
  PHP_SOCK=$(ls /run/php/php*-fpm.sock 2>/dev/null | head -n1 || true)
  if [[ -n "$PHP_SOCK" ]]; then
    sudo tee -a "$CONF_AVAIL" >/dev/null <<CONF
    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:${PHP_SOCK};
    }
CONF
  else
    echo "Hinweis: Kein PHP-FPM Socket gefunden. PHP-Block wird nicht aktiviert."
  fi
fi

# Server-Block abschließen
sudo tee -a "$CONF_AVAIL" >/dev/null <<CONF
}
CONF

# Zertifikate behandeln
CRT_PATH="/etc/nginx/ssl/${DOMAIN}.crt"
KEY_PATH="/etc/nginx/ssl/${DOMAIN}.key"

if [[ "$ONLY_CONF" == "0" ]]; then
  if [[ -n "$CRT_IN" && -n "$KEY_IN" ]]; then
    sudo cp "$CRT_IN" "$CRT_PATH"
    sudo cp "$KEY_IN" "$KEY_PATH"
  else
    echo "Self-Signed Zertifikat wird erzeugt für ${DOMAIN} ..."
    sudo openssl req -x509 -nodes -newkey rsa:2048 -days 365       -keyout "$KEY_PATH" -out "$CRT_PATH"       -subj "/CN=${DOMAIN}"       -addext "subjectAltName=DNS:${DOMAIN}"
  fi
  sudo chmod 600 "$KEY_PATH"
fi

# vHost aktivieren
if [[ ! -e "$CONF_ENABLED" ]]; then
  sudo ln -s "$CONF_AVAIL" "$CONF_ENABLED"
fi

# Default-Server deaktivieren (optional)
if [[ -e /etc/nginx/sites-enabled/default ]]; then
  sudo rm -f /etc/nginx/sites-enabled/default
fi

# einfache Index-Datei, falls nicht vorhanden
if [[ ! -f "${WEBROOT}/index.html" ]]; then
  cat > /tmp/index.html <<HTML
<!doctype html>
<html>
<head><meta charset="utf-8"><title>${DOMAIN}</title></head>
<body><h1>It works: ${DOMAIN}</h1></body>
</html>
HTML
  sudo mv /tmp/index.html "${WEBROOT}/index.html"
fi

# Syntax prüfen und neu laden
sudo nginx -t
sudo systemctl restart nginx

echo "Fertig. Rufe jetzt https://${DOMAIN}:${HTTPS_PORT}/ im Browser auf."
