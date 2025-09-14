#!/usr/bin/env bash
SCRIPT_VERSION="v0.7.0"
set -euo pipefail

# Defaults
PROJECT_PATH="$(pwd)"
ENABLE_HSTS="0"
HSTS_MAX_AGE="31536000"
HSTS_INCLUDE_SUBDOMAINS="0"
HSTS_PRELOAD="0"
ENABLE_CSP="0"
CSP_PRESET="minimal"   # neu: dev-vite | prod-strict zusätzlich zu minimal|loose|strict
CSP_EXTRA=""
CLEAN_DUPLICATES="0"

usage() {
  printf '%s\n' "Usage: $0 [--clean-duplicates] [--enable-hsts [--hsts-max-age SEC] [--hsts-include-subdomains] [--hsts-preload]] [--enable-csp [--csp-preset minimal|loose|strict|dev-vite|prod-strict] [--csp-extra '...;']] [-p PATH] [--version]"
  exit 1
}

# Args
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p) PROJECT_PATH="$2"; shift 2;;
    --clean-duplicates) CLEAN_DUPLICATES="1"; shift;;
    --enable-hsts) ENABLE_HSTS="1"; shift;;
    --hsts-max-age) HSTS_MAX_AGE="$2"; shift 2;;
    --hsts-include-subdomains) HSTS_INCLUDE_SUBDOMAINS="1"; shift;;
    --hsts-preload) HSTS_PRELOAD="1"; shift;;
    --enable-csp) ENABLE_CSP="1"; shift;;
    --csp-preset) CSP_PRESET="$2"; shift 2;;
    --csp-extra) CSP_EXTRA="$2"; shift 2;;
    --version) printf '%s\n' "$SCRIPT_VERSION"; exit 0;;
    -h|--help) usage;;
    *) printf 'Unbekannter Parameter: %s\n' "$1" >&2; usage;;
  esac
done

# Gatekeeper
ENV_FILE="${PROJECT_PATH}/.env"
if [[ ! -f "$ENV_FILE" ]]; then
  printf 'Fehler: Dieses Skript muss im Projektordner mit .env ausgeführt werden (oder -p PATH).\n' >&2
  exit 2
fi

command -v nginx >/dev/null || { printf 'Fehler: nginx nicht gefunden.\n' >&2; exit 3; }
command -v mkcert >/dev/null || { printf 'Fehler: mkcert nicht gefunden.\n' >&2; exit 4; }

# Domain aus APP_URL
APP_URL="$(sed -nE 's/^APP_URL=//p' "$ENV_FILE" | tail -n1)"
DOMAIN="$(printf '%s' "$APP_URL" | sed -E 's#^[a-zA-Z]+://##; s#/.*$##')"
if [[ -z "${DOMAIN:-}" ]]; then
  printf 'Fehler: APP_URL in .env nicht gesetzt.\n' >&2
  exit 5
fi
WWW_DOMAIN="www.${DOMAIN}"

# Cert-Pfade (kanonisch)
CERT_DIR="/etc/nginx/certs"
CERT_PEM="${CERT_DIR}/${DOMAIN}.pem"
CERT_KEY="${CERT_DIR}/${DOMAIN}.key"
sudo mkdir -p "$CERT_DIR"

# mkcert: direkt nach /etc/nginx/certs schreiben (fallback: verschieben)
if [[ ! -f "$CERT_PEM" || ! -f "$CERT_KEY" ]]; then
  if mkcert -help 2>/dev/null | grep -q -- '-cert-file'; then
    tmpdir="$(mktemp -d)"; trap 'rm -rf "$tmpdir"' EXIT
    mkcert -cert-file "${tmpdir}/${DOMAIN}.pem" -key-file "${tmpdir}/${DOMAIN}.key" "$DOMAIN" "$WWW_DOMAIN"
    sudo install -o root -g root -m 0644 "${tmpdir}/${DOMAIN}.pem" "$CERT_PEM"
    sudo install -o root -g root -m 0600 "${tmpdir}/${DOMAIN}.key" "$CERT_KEY"
  else
    mkcert "$DOMAIN" "$WWW_DOMAIN"
    latest_pem="$(ls -t "${DOMAIN}"+*.pem 2>/dev/null | head -n1 || true)"
    [[ -n "${latest_pem}" ]] || { printf 'Fehler: Konnte erzeugtes PEM nicht finden.\n' >&2; exit 6; }
    latest_key="${latest_pem%.pem}-key.pem"
    [[ -f "$latest_key" ]] || { printf 'Fehler: Konnte erzeugten KEY nicht finden.\n' >&2; exit 7; }
    sudo install -o root -g root -m 0644 "$latest_pem" "$CERT_PEM"
    sudo install -o root -g root -m 0600 "$latest_key" "$CERT_KEY"
    rm -f "$latest_pem" "$latest_key"
  fi
fi

# CSP Presets
build_csp() {
  case "$CSP_PRESET" in
    minimal)
      printf "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; font-src 'self' data:; connect-src 'self' ws: wss:; frame-ancestors 'self'; base-uri 'self'; object-src 'none';"
      ;;
    loose)
      printf "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self' data:; connect-src 'self' ws: wss:; frame-ancestors 'self'; base-uri 'self'; object-src 'none';"
      ;;
    strict)
      printf "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self'; font-src 'self'; connect-src 'self'; frame-ancestors 'self'; base-uri 'self'; object-src 'none';"
      ;;
    dev-vite)
      # großzügig für HMR/WS (5173)
      printf "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval' http://localhost:5173 http://127.0.0.1:5173; style-src 'self' 'unsafe-inline' http://localhost:5173 http://127.0.0.1:5173; img-src 'self' data: blob:; font-src 'self' data:; connect-src 'self' ws: wss: https://%s http://localhost:5173 ws://localhost:5173 ws://127.0.0.1:5173; frame-ancestors 'self'; base-uri 'self'; object-src 'none';" "$DOMAIN"
      ;;
    prod-strict)
      printf "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; font-src 'self' data:; connect-src 'self'; frame-ancestors 'self'; base-uri 'self'; object-src 'none';"
      ;;
    *)
      printf 'Warnung: unbekanntes CSP-Preset (%s), nutze minimal.\n' "$CSP_PRESET" >&2
      CSP_PRESET="minimal"
      build_csp
      ;;
  esac
}

# Nginx-Conf Pfade
SITE_AVAIL="/etc/nginx/sites-available/nginx_https_${DOMAIN}.conf"
SITE_LINK="/etc/nginx/sites-enabled/nginx_https_${DOMAIN}.conf"

# Konfiguration bauen (Platzhalter, dann ersetzen)
tmpconf="$(mktemp)"
cat > "$tmpconf" <<'NGINX'
server {
    listen 80;
    server_name __DOMAIN__ __WWW__;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    server_name __DOMAIN__ __WWW__;

    ssl_certificate     __CERT_PEM__;
    ssl_certificate_key __CERT_KEY__;

    root __DOCROOT__;
    index index.php index.html;

    add_header X-Frame-Options "SAMEORIGIN";
    add_header X-Content-Type-Options "nosniff";
    add_header Referrer-Policy "strict-origin-when-cross-origin";
    add_header Permissions-Policy "interest-cohort=()";
    add_header X-XSS-Protection "1; mode=block";
__HSTS__
__CSP__

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    location ~ \.php$ {
        include fastcgi_params;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
        fastcgi_param SCRIPT_FILENAME $realpath_root$fastcgi_script_name;
        fastcgi_param PATH_INFO $fastcgi_path_info;
    }

    location ~ /\.ht {
        deny all;
    }
}
NGINX

# HSTS/CSP Zeilen aufbauen
HSTS_LINE=""
if [[ "$ENABLE_HSTS" == "1" ]]; then
  hsts="max-age=${HSTS_MAX_AGE}"
  [[ "$HSTS_INCLUDE_SUBDOMAINS" == "1" ]] && hsts="${hsts}; includeSubDomains"
  [[ "$HSTS_PRELOAD" == "1" ]] && hsts="${hsts}; preload"
  HSTS_LINE="    add_header Strict-Transport-Security \"${hsts}\" always;"
fi

CSP_LINE=""
if [[ "$ENABLE_CSP" == "1" ]]; then
  csp_val="$(build_csp)"
  if [[ -n "$CSP_EXTRA" ]]; then
    case "$CSP_EXTRA" in
      *';') csp_val="${csp_val} ${CSP_EXTRA}";;
      *)     csp_val="${csp_val} ${CSP_EXTRA};";;
    esac
  fi
  CSP_LINE="    add_header Content-Security-Policy \"${csp_val}\";"
fi

# Platzhalter ersetzen
sudo sed -e "s#__DOMAIN__#${DOMAIN}#g" \
    -e "s#__WWW__#${WWW_DOMAIN}#g" \
    -e "s#__CERT_PEM__#${CERT_PEM}#g" \
    -e "s#__CERT_KEY__#${CERT_KEY}#g" \
    -e "s#__DOCROOT__#${PROJECT_PATH}/public#g" \
    -e "s#__HSTS__#${HSTS_LINE//\\/\\\\}#g" \
    -e "s#__CSP__#${CSP_LINE//\\/\\\\}#g" \
    "$tmpconf" | sudo tee "$SITE_AVAIL" >/dev/null

sudo ln -sf "$SITE_AVAIL" "$SITE_LINK"

# /etc/hosts ergänzen (falls fehlt)
if ! grep -qE "^[^#]*\s${DOMAIN}(\s|$)" /etc/hosts; then
  echo "127.0.0.1 ${DOMAIN} ${WWW_DOMAIN}" | sudo tee -a /etc/hosts >/dev/null
fi

# Doppelte vHosts (optional) – nur Links entfernen
if [[ "$CLEAN_DUPLICATES" == "1" ]]; then
  while IFS= read -r f; do
    base="$(basename "$f")"
    [[ "$base" == "$(basename "$SITE_AVAIL")" ]] && continue
    if [[ -L "/etc/nginx/sites-enabled/$base" ]]; then
      sudo rm -f "/etc/nginx/sites-enabled/$base"
    fi
  done < <(sudo grep -RIl "server_name.*\b${DOMAIN}\b" /etc/nginx/sites-available || true)
fi

# Test + Reload
sudo nginx -t
sudo systemctl reload nginx

printf 'OK: HTTPS aktiv für %s (Conf: %s)\n' "$DOMAIN" "$SITE_AVAIL"
