#!/usr/bin/env bash
SCRIPT_VERSION="v0.3.1"
set -euo pipefail

PROJECT_PATH="$(pwd)"
CLEAN_DUPLICATES="0"

usage() {
  printf '%s\n' "Usage: $0 [-p PATH] [--clean-duplicates] [--version]"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p) PROJECT_PATH="$2"; shift 2;;
    --clean-duplicates) CLEAN_DUPLICATES="1"; shift;;
    --version) printf '%s\n' "$SCRIPT_VERSION"; exit 0;;
    -h|--help) usage;;
    *) printf 'Unbekannter Parameter: %s\n' "$1" >&2; usage;;
  esac
done

ENV_FILE="${PROJECT_PATH}/.env"
[[ -f "$ENV_FILE" ]] || { printf 'Fehler: .env nicht gefunden (verwende -p PATH).\n' >&2; exit 2; }
command -v nginx >/dev/null || { printf 'Fehler: nginx nicht gefunden.\n' >&2; exit 3; }

APP_URL="$(sed -nE 's/^APP_URL=//p' "$ENV_FILE" | tail -n1)"
DOMAIN="$(printf '%s' "$APP_URL" | sed -E 's#^[a-zA-Z]+://##; s#/.*$##')"
[[ -n "${DOMAIN:-}" ]] || { printf 'Fehler: APP_URL leer.\n' >&2; exit 4; }

CERT_DIR="/etc/nginx/certs"
DEST_PEM="${CERT_DIR}/${DOMAIN}.pem"
DEST_KEY="${CERT_DIR}/${DOMAIN}.key"

sudo mkdir -p "$CERT_DIR"

found_pem=""
found_key=""

try_pair() {
  local pem="$1" key="$2"
  if [[ -f "$pem" && -f "$key" ]]; then
    found_pem="$pem"; found_key="$key"; return 0
  fi
  return 1
}

# Suchreihenfolge
# 1) <project>/.certs/<domain>+N.pem|-key.pem
if ls "${PROJECT_PATH}"/.certs/"${DOMAIN}"+*.pem >/dev/null 2>&1; then
  pem="$(ls -t "${PROJECT_PATH}"/.certs/"${DOMAIN}"+*.pem | head -n1)"
  key="${pem%.pem}-key.pem"
  try_pair "$pem" "$key" || true
fi

# 2) <project>/certs/<domain>+N.pem|-key.pem
if [[ -z "$found_pem" ]] && ls "${PROJECT_PATH}"/certs/"${DOMAIN}"+*.pem >/dev/null 2>&1; then
  pem="$(ls -t "${PROJECT_PATH}"/certs/"${DOMAIN}"+*.pem | head -n1)"
  key="${pem%.pem}-key.pem"
  try_pair "$pem" "$key" || true
fi

# 3) ~/.local/share/mkcert/<domain>+N.pem|-key.pem
if [[ -z "$found_pem" ]] && ls "${HOME}"/.local/share/mkcert/"${DOMAIN}"+*.pem >/dev/null 2>&1; then
  pem="$(ls -t "${HOME}"/.local/share/mkcert/"${DOMAIN}"+*.pem | head -n1)"
  key="${pem%.pem}-key.pem"
  try_pair "$pem" "$key" || true
fi

# 4) /etc/nginx/certs/<domain>/<domain>.pem|-key.pem
if [[ -z "$found_pem" ]] && ls "/etc/nginx/certs/${DOMAIN}"/*.pem >/dev/null 2>&1; then
  pem="/etc/nginx/certs/${DOMAIN}/${DOMAIN}.pem"
  key="/etc/nginx/certs/${DOMAIN}/${DOMAIN}-key.pem"
  try_pair "$pem" "$key" || true
fi

# 5) /etc/nginx/certs/<domain>.pem|.key (kanonisch bereits)
if [[ -z "$found_pem" ]]; then
  try_pair "$DEST_PEM" "$DEST_KEY" || true
fi

if [[ -z "$found_pem" ]]; then
  printf 'Fehler: Kein Zertifikatspaar für %s gefunden.\n' "$DOMAIN" >&2
  exit 5
fi

printf '[INFO] Gefundenes Paar:\n  PEM: %s\n  KEY: %s\n' "$found_pem" "$found_key"

# Kopieren, wenn nötig
if [[ "$found_pem" != "$DEST_PEM" || "$found_key" != "$DEST_KEY" ]]; then
  sudo install -o root -g root -m 0644 "$found_pem" "$DEST_PEM"
  sudo install -o root -g root -m 0600 "$found_key" "$DEST_KEY"
else
  printf '[INFO] Kanonische Pfade sind bereits befüllt.\n'
fi

SITE_AVAIL="/etc/nginx/sites-available/nginx_https_${DOMAIN}.conf"
SITE_LINK="/etc/nginx/sites-enabled/nginx_https_${DOMAIN}.conf"

# Site patchen (nur ssl_certificate*_Zeilen)
if [[ -f "$SITE_AVAIL" ]]; then
  sudo sed -i \
    -e "s#^\s*ssl_certificate\s\+.*#    ssl_certificate ${DEST_PEM};#g" \
    -e "s#^\s*ssl_certificate_key\s\+.*#    ssl_certificate_key ${DEST_KEY};#g" \
    "$SITE_AVAIL"
  sudo ln -sf "$SITE_AVAIL" "$SITE_LINK"
  if [[ "$CLEAN_DUPLICATES" == "1" ]]; then
    while IFS= read -r f; do
      base="$(basename "$f")"
      [[ "$base" == "$(basename "$SITE_AVAIL")" ]] && continue
      if [[ -L "/etc/nginx/sites-enabled/$base" ]]; then
        sudo rm -f "/etc/nginx/sites-enabled/$base"
      fi
    done < <(sudo grep -RIl "server_name.*\b${DOMAIN}\b" /etc/nginx/sites-available || true)
  fi
fi

printf '[INFO] nginx testen & neu laden …\n'
sudo nginx -t
sudo systemctl reload nginx
printf '[OK] Zertifikatspfad konsolidiert: %s / %s\n' "$DEST_PEM" "$DEST_KEY"
