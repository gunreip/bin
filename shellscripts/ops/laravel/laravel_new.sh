#!/bin/bash
set -euo pipefail

PROJECT_PATH=""
DB_NAME=""
DB_USER=""
DB_PASS=""
DB_HOST="127.0.0.1"
DB_PORT="5432"
APP_URL="http://localhost"
RUN_MIGRATIONS=1

usage() {
  echo "Usage: $0 -p <project_path> -d <db_name> -u <db_user> [-w <db_pass>] [-h <db_host>] [-P <db_port>] [-a <app_url>] [--no-migrate]"
  exit 1
}

# Parse args
while (( "$#" )); do
  case "$1" in
    -p) PROJECT_PATH="$2"; shift 2 ;;
    -d) DB_NAME="$2"; shift 2 ;;
    -u) DB_USER="$2"; shift 2 ;;
    -w) DB_PASS="$2"; shift 2 ;;
    -h) DB_HOST="$2"; shift 2 ;;
    -P) DB_PORT="$2"; shift 2 ;;
    -a) APP_URL="$2"; shift 2 ;;
    --no-migrate) RUN_MIGRATIONS=0; shift 1 ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

if [[ -z "${PROJECT_PATH}" || -z "${DB_NAME}" || -z "${DB_USER}" ]]; then
  echo "❌ Fehlende Parameter. Erforderlich: -p <project_path> -d <db_name> -u <db_user>"
  usage
fi

if [[ ! -d "${PROJECT_PATH}" ]]; then
  echo "❌ Projektverzeichnis nicht gefunden: ${PROJECT_PATH}"
  exit 1
fi

cd "${PROJECT_PATH}"

if [[ ! -f artisan ]]; then
  echo "❌ '${PROJECT_PATH}' scheint kein Laravel-Projekt zu sein (artisan fehlt)."
  exit 1
fi

# .env vorbereiten
if [[ ! -f .env ]]; then
  cp .env.example .env
fi

# Falls Passwort fehlt: sicher abfragen
if [[ -z "${DB_PASS}" ]]; then
  read -s -p "Passwort für DB-User ${DB_USER}: " DB_PASS
  echo ""
fi

# In .env setzen/ersetzen (idempotent)
set_kv () {
  local key="$1"; shift
  local val="$1"; shift
  if grep -qE "^${key}=" .env; then
    # Escape &, / and backslashes for sed
    local esc_val
    esc_val=$(printf '%s' "${val}" | sed -e 's/[&/\\]/\\&/g')
    sed -i -E "s|^${key}=.*$|${key}=${esc_val}|" .env
  else
    echo "${key}=${val}" >> .env
  fi
}

set_kv APP_URL "${APP_URL}"
set_kv DB_CONNECTION "pgsql"
set_kv DB_HOST "${DB_HOST}"
set_kv DB_PORT "${DB_PORT}"
set_kv DB_DATABASE "${DB_NAME}"
set_kv DB_USERNAME "${DB_USER}"
set_kv DB_PASSWORD "${DB_PASS}"

# App-Key setzen (idempotent)
php artisan key:generate --force >/dev/null

# Storage-Link sicherstellen
php artisan storage:link >/dev/null || true

# Cache aufräumen & rebuild
php artisan config:clear >/dev/null || true
php artisan route:clear >/dev/null || true
php artisan view:clear >/dev/null || true
php artisan optimize >/dev/null || true

# Migrationen (optional)
if [[ "${RUN_MIGRATIONS}" -eq 1 ]]; then
  php artisan migrate --force
fi

echo "✅ Laravel-Bootstrap abgeschlossen für: ${PROJECT_PATH}"
echo "   APP_URL=${APP_URL}"
echo "   DB=${DB_USER}@${DB_HOST}:${DB_PORT}/${DB_NAME}"
