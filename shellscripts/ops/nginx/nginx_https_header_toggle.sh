#!/usr/bin/env bash
SCRIPT_VERSION="v0.2.0"
set -euo pipefail

PROJECT_PATH="$(pwd)"
DO_HSTS_ON=0; DO_HSTS_OFF=0
DO_CSP_ON=0;  DO_CSP_OFF=0
HSTS_MAX_AGE="31536000"; HSTS_INC_SUB=0; HSTS_PRELOAD=0
CSP_PRESET="minimal"   # minimal|loose|strict|dev-vite|prod-strict
CSP_EXTRA=""
SHOW_STATUS=0
DRY_RUN=0

usage(){ printf '%s\n' \
"Usage: $0 [--enable-hsts [--hsts-max-age SEC] [--hsts-include-subdomains] [--hsts-preload]] | [--hsts-off] \
[--enable-csp [--csp-preset minimal|loose|strict|dev-vite|prod-strict] [--csp-extra '...;']] | [--csp-off] \
[--status] [--dry-run] [-p PATH] [--version]"; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p) PROJECT_PATH="$2"; shift 2;;
    --enable-hsts) DO_HSTS_ON=1; shift;;
    --hsts-max-age) HSTS_MAX_AGE="$2"; shift 2;;
    --hsts-include-subdomains) HSTS_INC_SUB=1; shift;;
    --hsts-preload) HSTS_PRELOAD=1; shift;;
    --hsts-off) DO_HSTS_OFF=1; shift;;
    --enable-csp) DO_CSP_ON=1; shift;;
    --csp-preset) CSP_PRESET="$2"; shift 2;;
    --csp-extra) CSP_EXTRA="$2"; shift 2;;
    --csp-off) DO_CSP_OFF=1; shift;;
    --status) SHOW_STATUS=1; shift;;
    --dry-run) DRY_RUN=1; shift;;
    --version) printf '%s\n' "$SCRIPT_VERSION"; exit 0;;
    -h|--help) usage;;
    *) printf 'Unbekannter Parameter: %s\n' "$1" >&2; usage;;
  esac
done

ENV_FILE="${PROJECT_PATH}/.env"
[[ -f "$ENV_FILE" ]] || { printf 'Fehler: .env nicht gefunden (verwende -p PATH).\n' >&2; exit 2; }

APP_URL="$(sed -nE 's/^APP_URL=//p' "$ENV_FILE" | tail -n1)"
DOMAIN="$(printf '%s' "$APP_URL" | sed -E 's#^[a-zA-Z]+://##; s#/.*$##')"
[[ -n "${DOMAIN:-}" ]] || { printf 'Fehler: APP_URL leer.\n' >&2; exit 3; }

SITE_AVAIL="/etc/nginx/sites-available/nginx_https_${DOMAIN}.conf"
[[ -f "$SITE_AVAIL" ]] || { printf 'Fehler: %s existiert nicht.\n' "$SITE_AVAIL" >&2; exit 4; }

# ---- Helpers ----
build_csp(){
  case "$CSP_PRESET" in
    minimal)     printf "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; font-src 'self' data:; connect-src 'self' ws: wss:; frame-ancestors 'self'; base-uri 'self'; object-src 'none';";;
    loose)       printf "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self' data:; connect-src 'self' ws: wss:; frame-ancestors 'self'; base-uri 'self'; object-src 'none';";;
    strict)      printf "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self'; font-src 'self'; connect-src 'self'; frame-ancestors 'self'; base-uri 'self'; object-src 'none';";;
    dev-vite)    printf "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval' http://localhost:5173 http://127.0.0.1:5173; style-src 'self' 'unsafe-inline' http://localhost:5173 http://127.0.0.1:5173; img-src 'self' data: blob:; font-src 'self' data:; connect-src 'self' ws: wss: https://%s http://localhost:5173 ws://localhost:5173 ws://127.0.0.1:5173; frame-ancestors 'self'; base-uri 'self'; object-src 'none';" "$DOMAIN";;
    prod-strict) printf "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; font-src 'self' data:; connect-src 'self'; frame-ancestors 'self'; base-uri 'self'; object-src 'none';";;
    *)           printf "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; font-src 'self' data:; connect-src 'self' ws: wss:; frame-ancestors 'self'; base-uri 'self'; object-src 'none';";;
  esac
}

esc_sed(){ local s="$1"; s="${s//\\/\\\\}"; s="${s//&/\\&}"; printf '%s' "$s"; }

add_or_replace_tmp(){
  # $1 pattern, $2 line, $3 tmpfile
  local pattern="$1" line="$2" file="$3" line_esc; line_esc="$(esc_sed "$line")"
  if grep -qE "$pattern" "$file"; then
    sed -i -E "s|$pattern|$line_esc|g" "$file"
  else
    if grep -qE 'add_header\s+X-XSS-Protection' "$file"; then
      sed -i "/add_header\s\+X-XSS-Protection.*/a\\
$line_esc
" "$file"
    else
      sed -i "/server_name\s\+${DOMAIN}.*/a\\
$line_esc
" "$file"
    fi
  fi
}

remove_lines_tmp(){ local pattern="$1" file="$2"; sed -i -E "/$pattern/d" "$file"; }

# ---- Status only ----
if [[ "$SHOW_STATUS" == "1" ]]; then
  printf 'Status (%s):\n' "$SITE_AVAIL"
  sudo grep -nE 'add_header\s+Strict-Transport-Security|add_header\s+Content-Security-Policy' "$SITE_AVAIL" || printf '  keine HSTS/CSP Header gefunden\n'
  exit 0
fi

# ---- Build desired lines ----
hsts_line=""
if [[ "$DO_HSTS_ON" == "1" ]]; then
  hsts="max-age=${HSTS_MAX_AGE}"
  [[ "$HSTS_INC_SUB" == "1" ]] && hsts="${hsts}; includeSubDomains"
  [[ "$HSTS_PRELOAD" == "1" ]] && hsts="${hsts}; preload"
  hsts_line="    add_header Strict-Transport-Security \"${hsts}\" always;"
fi

csp_line=""
if [[ "$DO_CSP_ON" == "1" ]]; then
  csp="$(build_csp)"
  if [[ -n "${CSP_EXTRA:-}" ]]; then
    case "$CSP_EXTRA" in *';') csp="${csp} ${CSP_EXTRA}";; *) csp="${csp} ${CSP_EXTRA};";; esac
  fi
  csp_line="    add_header Content-Security-Policy \"${csp}\";"
fi

# ---- Work on a temp copy ----
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
sudo cat "$SITE_AVAIL" > "$tmp"

changed=0

# OFF actions
if [[ "$DO_HSTS_OFF" == "1" ]]; then remove_lines_tmp '^\s*add_header\s+Strict-Transport-Security\b' "$tmp"; changed=1; fi
if [[ "$DO_CSP_OFF"  == "1" ]]; then remove_lines_tmp '^\s*add_header\s+Content-Security-Policy\b' "$tmp"; changed=1; fi

# ON actions (add/replace)
if [[ "$DO_HSTS_ON" == "1" ]]; then add_or_replace_tmp '^\s*add_header\s+Strict-Transport-Security\b.*' "$hsts_line" "$tmp"; changed=1; fi
if [[ "$DO_CSP_ON"  == "1" ]]; then add_or_replace_tmp '^\s*add_header\s+Content-Security-Policy\b.*' "$csp_line" "$tmp"; changed=1; fi

# Nothing to do?
if [[ "$changed" == "0" ]]; then
  printf 'Nichts zu tun.\n'; exit 0
fi

# DRY-RUN: show diff only
if [[ "$DRY_RUN" == "1" ]]; then
  if command -v diff >/dev/null; then
    printf '[DRY-RUN] Änderungen an %s:\n' "$SITE_AVAIL"
    diff -u "$SITE_AVAIL" "$tmp" || true
  else
    printf '[DRY-RUN] diff nicht verfügbar. Neue Datei (Vorschau):\n'
    cat "$tmp"
  fi
  exit 0
fi

# Apply
sudo tee "$SITE_AVAIL" >/dev/null < "$tmp"
sudo nginx -t
sudo systemctl reload nginx
printf '[OK] nginx neu geladen.\n'
