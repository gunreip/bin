#!/usr/bin/env bash
# health_check_basic.sh — generischer Basis-Health-Report für Laravel-Projekte
# Version: 0.3.1
# Changelog:
# - 0.3.1: Symlink-Setup vereinfacht (relativ in ~/bin)
# - 0.3.0: Standardisierte Ablage ~/bin/*.sh + Symlink ohne Extension
# - 0.2.0: Generisch (Host/Cert/Socket autodetect, .env-basierend)
# - 0.1.0: Initial (projektfest)
set -euo pipefail

VERSION="0.3.1"
SCRIPT_NAME="health_check_basic"

usage(){ cat <<'EOF'
health_check_basic — Basis-Health-Report (aus dem <project>-Root ausführen)
Usage: health_check_basic [--no-dry-run] [--format md|json|txt] [--out <file>] [--version]
EOF
}

DRY_RUN=1
FORMAT="md"
OUTFILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-dry-run) DRY_RUN=0 ;;
    --format) FORMAT="${2:-}"; shift ;;
    --out) OUTFILE="${2:-}"; shift ;;
    --version) echo "$VERSION"; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2 ;;
  esac; shift
done

PROJECT_ROOT="$(pwd)"
if [[ ! -f ".env" ]]; then
  echo "[ERROR] .env nicht gefunden. Bitte aus einem gültigen <project>-Root ausführen." >&2
  exit 1
fi

WIKI_DIR="$PROJECT_ROOT/.wiki/health"
ROTATE_DAYS=30

mask(){ sed -E 's/([A-Za-z0-9]{2})([A-Za-z0-9]+)([A-Za-z0-9]{2})/\1******\3/g'; }
ts(){ date +"%Y-%m-%d %H:%M:%S%z"; }
rot(){ find "$WIKI_DIR" -type f -mtime +$ROTATE_DAYS -delete 2>/dev/null || true; }
kv(){ local k="$1" v="$2"; printf "%s: %s\n" "$k" "$v"; }

# ENV laden (nur benötigte Keys)
# shellcheck disable=SC2046
export $(grep -E '^(APP_URL|DB_HOST|DB_PORT|DB_DATABASE|DB_USERNAME|DB_PASSWORD|QUEUE_CONNECTION|PHP_FPM_SOCK|NGINX_CERT_PEM|NGINX_CERT_KEY|HEALTH_TIMER_PREFIX)=' .env | xargs) || true

APP_HOST=""
if [[ -n "${APP_URL:-}" ]]; then
  APP_HOST="$(printf "%s" "$APP_URL" | sed -E 's#^[a-zA-Z]+://##' | cut -d/ -f1)"
fi

APP_URL_SAFE="$(printf "%s" "${APP_URL:-}" | mask)"
DB_USER_SAFE="$(printf "%s" "${DB_USERNAME:-}" | mask)"

detect_php_sock(){
  if [[ -n "${PHP_FPM_SOCK:-}" && -S "${PHP_FPM_SOCK:-}" ]]; then echo "$PHP_FPM_SOCK"; return; fi
  for s in /run/php/php*-fpm.sock /var/run/php/php*-fpm.sock; do [[ -S "$s" ]] && { echo "$s"; return; }; done
  echo ""
}
PHPFPM_SOCK="$(detect_php_sock)"

detect_cert_paths(){
  local host="$1"; local crt="" key=""
  [[ -n "${NGINX_CERT_PEM:-}" && -f "${NGINX_CERT_PEM:-}" ]] && crt="$NGINX_CERT_PEM"
  [[ -n "${NGINX_CERT_KEY:-}" && -f "${NGINX_CERT_KEY:-}" ]] && key="$NGINX_CERT_KEY"
  [[ -z "$crt" && -n "$host" && -f "/etc/nginx/certs/$host.pem" ]] && crt="/etc/nginx/certs/$host.pem"
  [[ -z "$key" && -n "$host" && -f "/etc/nginx/certs/$host.key" ]] && key="/etc/nginx/certs/$host.key"
  printf "%s;%s\n" "$crt" "$key"
}
IFS=';' read -r CERT_CRT CERT_KEY < <(detect_cert_paths "$APP_HOST")

declare -A S

check_nginx(){
  if command -v nginx >/dev/null && sudo nginx -t >/dev/null 2>&1; then S[nginx_config]="OK"; else S[nginx_config]="ERROR_or_no_nginx"; fi
  if [[ -n "$APP_HOST" ]]; then curl -kIs --max-time 4 "https://$APP_HOST" >/dev/null && S[nginx_https]="OK" || S[nginx_https]="FAIL"; else S[nginx_https]="SKIP(no_APP_URL)"; fi
}
check_phpfpm(){ [[ -n "$PHPFPM_SOCK" && -S "$PHPFPM_SOCK" ]] && S[phpfpm_socket]="OK" || S[phpfpm_socket]="MISSING"; php -v >/dev/null 2>&1 && S[php_cli]="OK" || S[php_cli]="FAIL"; }
check_tls(){
  [[ -n "$CERT_CRT" ]] && S[tls_crt]="FOUND" || S[tls_crt]="MISSING"
  [[ -n "$CERT_KEY" ]] && S[tls_key]="FOUND" || S[tls_key]="MISSING"
  if [[ -n "$CERT_CRT" && -f "$CERT_CRT" ]]; then
    local exp days; exp=$(openssl x509 -enddate -noout -in "$CERT_CRT" 2>/dev/null | cut -d= -f2 || true)
    if [[ -n "$exp" ]]; then days=$(( ( $(date -d "$exp" +%s) - $(date +%s) ) / 86400 )); S[tls_days_valid]="${days}"; else S[tls_days_valid]="n/a"; fi
  fi
}
check_db(){
  if command -v psql >/dev/null; then
    if PGPASSWORD="${DB_PASSWORD:-}" psql -h "${DB_HOST:-localhost}" -U "${DB_USERNAME:-}" -d "${DB_DATABASE:-}" -p "${DB_PORT:-5432}" -c "select 1" -tA >/dev/null 2>&1; then S[db_connect]="OK"; else S[db_connect]="FAIL"; fi
  else S[db_connect]="psql_missing"; fi
}
check_laravel(){
  if php artisan --version >/dev/null 2>&1; then
    S[laravel]="OK"
    if php artisan migrate:status 2>/dev/null | grep -q "Pending"; then S[migrations]="PENDING"; else S[migrations]="OK"; fi
  else S[laravel]="FAIL"; fi
}
check_queues_sched(){
  S[queue_conn]="${QUEUE_CONNECTION:-not_set}"
  if [[ $DRY_RUN -eq 1 ]]; then php artisan schedule:list >/dev/null 2>&1 && S[schedule]="OK" || S[schedule]="FAIL"
  else php artisan schedule:run --verbose --no-interaction >/dev/null 2>&1 || true; S[schedule]="RUN"; fi
}
check_backups(){
  local dbdir="$PROJECT_ROOT/.backups/db/hourly"; [[ -d "$dbdir" ]] || { S[backup_db_latest]="none"; return; }
  local latest; latest=$(ls -1t "$dbdir"/*.sql.gz 2>/dev/null | head -n1 || true)
  if [[ -n "$latest" ]]; then S[backup_db_latest]="$(basename "$latest")"; S[backup_db_age_days]=$(( ( $(date +%s) - $(stat -c %Y "$latest") ) / 86400 )); else S[backup_db_latest]="none"; fi
}
check_disk_mem(){ S[disk_root_pct]="$(df -P / | awk 'NR==2{print $5}')"; S[disk_proj_pct]="$(df -P "$PROJECT_ROOT" | awk 'NR==2{print $5}')"; S[mem_free_mb]="$(free -m | awk '/Mem:/{print $7}')"; }
check_systemd_user(){
  local patt="${HEALTH_TIMER_PREFIX:-$(basename "$PROJECT_ROOT" | tr '[:upper:]' '[:lower:]')}"
  local timers; timers=$(systemctl --user list-timers --all 2>/dev/null | grep -E "$patt" || true)
  [[ -n "$timers" ]] && S[timers]="FOUND($patt)" || S[timers]="MISSING($patt)"
}

run_all(){ mkdir -p "$WIKI_DIR"; rot
  check_nginx; check_phpfpm; check_tls; check_db; check_laravel; check_queues_sched; check_backups; check_disk_mem; check_systemd_user; }

to_md(){ cat <<EOF
# Health Report (${SCRIPT_NAME} v${VERSION})
Zeit: $(ts)
Projekt: $PROJECT_ROOT
APP_URL: ${APP_URL_SAFE:-""}
DB_USER: ${DB_USER_SAFE:-""}
PHP_FPM_SOCK: ${PHPFPM_SOCK:-"(auto)"}
CERT_CRT: ${CERT_CRT:-"(auto/none)"} CERT_KEY: ${CERT_KEY:-"(auto/none)"}

| Check | Status |
|---|---|
$(for k in "${!S[@]}"; do printf "| %s | %s |\n" "$k" "${S[$k]}"; done | sort)
EOF
}
to_json(){ printf "{\n  \"script\":\"%s\",\n  \"version\":\"%s\",\n  \"timestamp\":\"%s\",\n  \"project_root\":\"%s\",\n  \"data\":{\n" "$SCRIPT_NAME" "$VERSION" "$(ts)" "$PROJECT_ROOT"
  local i=0 total=${#S[@]}; for k in "${!S[@]}"; do ((i++)); printf "    \"%s\":\"%s\"%s\n" "$k" "${S[$k]}" $([[ $i -lt $total ]] && echo "," ); done; printf "  }\n}\n"; }
to_txt(){ echo "script=$SCRIPT_NAME version=$VERSION time=$(ts) project=$PROJECT_ROOT"; for k in "${!S[@]}"; do kv "$k" "${S[$k]}"; done | sort; }

run_all
case "$FORMAT" in
  md) CONTENT="$(to_md)" ;;
  json) CONTENT="$(to_json)" ;;
  txt) CONTENT="$(to_txt)" ;;
  *) echo "bad --format" >&2; exit 2 ;;
esac

if [[ -n "$OUTFILE" ]]; then
  [[ $DRY_RUN -eq 1 ]] && echo "[DRY-RUN] würde schreiben: $OUTFILE" || printf "%s\n" "$CONTENT" > "$OUTFILE"
else
  F="$WIKI_DIR/$(date +%F_%H%M%S)_health.${FORMAT}"
  [[ $DRY_RUN -eq 1 ]] && echo "[DRY-RUN] würde schreiben: $F" || printf "%s\n" "$CONTENT" > "$F"
fi
