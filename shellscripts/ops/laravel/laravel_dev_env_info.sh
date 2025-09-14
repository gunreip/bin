#!/usr/bin/env bash
# dev_env_info.sh — Projekt-Env-Check (nur aus Projekt-Root!)
# Version: 0.4.3
# Changelog:
# - 0.4.3: Repack: Funktionsblöcke strikt getrennt (Copy/Paste-sicher)
# - 0.4.2: Fix: ok()/warn()/bad() auf separaten Zeilen
# - 0.4.1: Dateiname dev_env_info_<ts>.<fmt>; Exit +1 nur bei missing required/recommended
# - 0.4.0: md/json only, --short/--full, pretty JSON, neues Layout
# - 0.3.0: MD-Rework (Header/Subheader/Listen/Icons)
# - 0.2.0: STRICT ROOT
# - 0.1.0: Initial
set -o pipefail

VERSION="0.4.3"
SCRIPT_NAME="dev_env_info"

usage(){ cat <<'EOF'
dev_env_info — kompakter Env-Report (nur im Projekt-Root ausführen)
Usage:
  dev_env_info [--dry-run] [--full|--short] [--format md|json] [--out <file>]
               [--color auto|always|never] [--debug] [--version]
EOF
}

# ---------- Defaults ----------
DRY_RUN=0
FULL=0               # --short = Default
FORMAT="md"          # md|json
OUTFILE=""
COLOR_MODE="auto"
DEBUG=0

# ---------- Args ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --full)    FULL=1 ;;
    --short)   FULL=0 ;;
    --format)  FORMAT="${2:-md}"; shift ;;
    --out)     OUTFILE="${2:-}"; shift ;;
    --color)   COLOR_MODE="${2:-auto}"; shift ;;
    --debug)   DEBUG=1 ;;
    --version) echo "$VERSION"; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2 ;;
  esac; shift
done

# ---------- Colors/Debug ----------
setup_colors() {
  local use=0
  case "$COLOR_MODE" in always) use=1;; never) use=0;; auto) [[ -t 1 ]] && use=1 || use=0;; esac
  if [[ $use -eq 1 ]]; then
    BOLD=$'\e[1m'; DIM=$'\e[2m'; RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; BLUE=$'\e[34m'; RESET=$'\e[0m'
  else
    BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; RESET=""
  fi
}
setup_colors
dbg(){ [[ $DEBUG -eq 1 ]] && printf "%s[DBG]%s %s\n" "$DIM" "$RESET" "$*" >&2; }
ts_iso(){ date +"%Y-%m-%d %H:%M:%S%z"; }
ts_de(){ date +"%d.%m.%Y %H:%M:%S"; }

# ---------- Strict root ----------
PROJECT_ROOT="$PWD"
[[ -f "$PROJECT_ROOT/.env" ]] || { echo "${RED}[ERROR]${RESET} .env fehlt im aktuellen Ordner." >&2; exit 2; }
[[ -f "$PROJECT_ROOT/artisan" || -f "$PROJECT_ROOT/composer.json" ]] || { echo "${RED}[ERROR]${RESET} Weder artisan noch composer.json im aktuellen Ordner." >&2; exit 2; }

# ---------- .env lesen ----------
# shellcheck disable=SC2046
export $(grep -E '^(APP_NAME|APP_ENV|APP_URL|DB_CONNECTION|DB_HOST|DB_PORT|DB_DATABASE|DB_USERNAME|DB_PASSWORD|REDIS_HOST|REDIS_PORT|REDIS_URL|CACHE_DRIVER|QUEUE_CONNECTION)=' .env | xargs) || true
APP_NAME_VAL="$(sed -nE 's/^APP_NAME=["'\'']?(.*)["'\'']?$/\1/p' .env | head -n1)"

proj_basename="$(basename "$PROJECT_ROOT")"
if [[ -n "$APP_NAME_VAL" ]]; then
  PROJECT_NAME="$APP_NAME_VAL"
else
  PROJECT_NAME="$(printf "%s" "$proj_basename" | sed -E 's/_+/-/g; s/(^|-)([a-z])/\1\u\2/g')"
fi

# ---------- Reporting ----------
WIKI_DIR="$PROJECT_ROOT/.wiki/dev/env"
mkdir -p "$WIKI_DIR"
find "$WIKI_DIR" -type f -mtime +30 -delete 2>/dev/null || true
TS_FILE="$(date +%F_%H%M%S)"

# ---------- Helpers ----------
have(){ command -v "$1" >/dev/null 2>&1; }
ok(){ printf "✅"; }
warn(){ printf "⚠️"; }
bad(){ printf "❌"; }
join_arr(){ local IFS=", "; echo "$*"; }

# ---------- Binaries ----------
bins_found=(); bins_missing=()
for b in php composer node pnpm npm mysql psql redis-cli; do
  if have "$b"; then bins_found+=("$b"); else bins_missing+=("$b"); fi
done

php_v="$(php -v 2>/dev/null | head -n1 || true)"
composer_v="$(composer --version 2>/dev/null || true)"
node_v="$(node -v 2>/dev/null || true)"
pnpm_v="$(pnpm -v 2>/dev/null || true)"
npm_v="$(npm -v 2>/dev/null || true)"
has_pkg_json=0; [[ -f "package.json" ]] && has_pkg_json=1
has_pnpm_lock=0; [[ -f "pnpm-lock.yaml" ]] && has_pnpm_lock=1
db_drv="${DB_CONNECTION:-}"

is_found(){
  for x in "${bins_found[@]}"; do [[ "$x" == "$1" ]] && return 0; done
  return 1
}

need_of(){
  case "$1" in
    php|composer) echo required ;;
    node)         [[ $has_pkg_json -eq 1 ]] && echo recommended || echo optional ;;
    pnpm)
      if [[ $has_pkg_json -eq 1 && $has_pnpm_lock -eq 1 ]]; then echo recommended
      elif [[ $has_pkg_json -eq 1 ]]; then echo optional
      else echo unnecessary
      fi ;;
    npm)
      if [[ $has_pkg_json -eq 1 && $has_pnpm_lock -eq 1 ]]; then echo optional
      elif [[ $has_pkg_json -eq 1 ]]; then echo recommended
      else echo unnecessary
      fi ;;
    mysql)
      case "$db_drv" in
        mysql|mariadb) echo recommended ;;
        pgsql|postgres|postgresql) echo optional ;;
        *) echo optional ;;
      esac ;;
    psql)
      case "$db_drv" in
        pgsql|postgres|postgresql) echo recommended ;;
        mysql|mariadb) echo optional ;;
        *) echo optional ;;
      esac ;;
    redis-cli)
      if [[ -n "${REDIS_URL:-}" || -n "${REDIS_HOST:-}" || "${CACHE_DRIVER:-}" == "redis" || "${QUEUE_CONNECTION:-}" == "redis" ]]; then
        echo recommended
      else
        echo optional
      fi ;;
    *) echo optional ;;
  esac
}

reason_of(){
  case "$1" in
    php)        echo "Framework-Laufzeit" ;;
    composer)   echo "PHP-Paketverwaltung (Composer)" ;;
    node)       echo "JS-Tooling (z. B. Vite/NPM-Scripts)" ;;
    pnpm)       [[ $has_pnpm_lock -eq 1 ]] && echo "Lockfile gefunden (pnpm-lock.yaml)" || echo "Nur nötig, wenn Team pnpm nutzt" ;;
    npm)        [[ $has_pnpm_lock -eq 1 ]] && echo "Fallback-Manager; meist nicht nötig" || echo "Standard-Manager für Node-Projekte" ;;
    mysql)      [[ "$db_drv" =~ ^(mysql|mariadb)$ ]] && echo "DB-Client für ${db_drv}; nützlich für Dumps" || echo "Hier nicht nötig; nur für MySQL/MariaDB" ;;
    psql)       [[ "$db_drv" =~ ^(pgsql|postgres|postgresql)$ ]] && echo "DB-Client für PostgreSQL; Dumps/SQL" || echo "Hier nicht nötig; nur für PostgreSQL" ;;
    redis-cli)  echo "CLI für Redis-Debugging" ;;
    *)          echo "" ;;
  esac
}

bin_line(){
  local name="$1" found="$2" need="$3" reason="$4" ver="$5"
  local state icon
  if [[ "$found" == "1" ]]; then
    state="vorhanden"; icon="$(ok)"
  else
    case "$need" in
      required)     state="fehlt (benötigt)";   icon="$(bad)";;
      recommended)  state="fehlt (empfohlen)";  icon="$(warn)";;
      optional)     state="fehlt (optional)";   icon="$(warn)";;
      unnecessary)  state="nicht nötig";        icon="$(ok)";;
      *)            state="fehlt";              icon="$(warn)";;
    esac
  fi
  [[ -n "$ver" && "$found" == "1" ]] && ver=" — $ver" || ver=""
  printf -- "- %s **%s** — %s; %s%s\n" "$icon" "$name" "$state" "$reason" "$ver"
}

BIN_STATUS=()
actionable_missing=0
for name in php composer node pnpm npm mysql psql redis-cli; do
  found="$(is_found "$name" && echo 1 || echo 0)"
  need="$(need_of "$name")"
  reason="$(reason_of "$name")"
  ver=""
  case "$name" in
    php) ver="$php_v";;
    composer) ver="$composer_v";;
    node) ver="$node_v";;
    pnpm) ver="$pnpm_v";;
    npm) ver="$npm_v";;
  esac
  BIN_STATUS+=("$(bin_line "$name" "$found" "$need" "$reason" "$ver")")
  if [[ "$found" == "0" && ( "$need" == "required" || "$need" == "recommended" ) ]]; then
    actionable_missing=$((actionable_missing+1))
  fi
done

# ---------- PHP Extensions ----------
php_ext_list="$(php -m 2>/dev/null || true | sort)"
need_ext=(openssl pdo mbstring curl json tokenizer xml ctype fileinfo)
EXT_MISSING=()
for e in "${need_ext[@]}"; do
  printf "%s\n" "$php_ext_list" | grep -qiE "^$e$" || EXT_MISSING+=("$e")
done

# ---------- DB/Redis Reachability ----------
APP_URL_SAFE="${APP_URL:-}"

DB_STATUS="skipped"
if [[ $DRY_RUN -eq 1 ]]; then
  DB_STATUS="skipped (dry-run)"
else
  db_ok=0
  case "${DB_CONNECTION:-}" in
    mysql|mariadb)
      host="${DB_HOST:-127.0.0.1}"; port="${DB_PORT:-3306}"
      if have mysql; then
        MYSQL_PWD="${DB_PASSWORD:-}" mysql -h "$host" -P "$port" -u "${DB_USERNAME:-}" -D "${DB_DATABASE:-}" -e "SELECT 1" >/dev/null 2>&1 && db_ok=1
      else
        (exec 3<>/dev/tcp/"$host"/"$port") >/dev/null 2>&1 && { exec 3>&-; db_ok=1; }
      fi ;;
    pgsql|postgres|postgresql)
      host="${DB_HOST:-127.0.0.1}"; port="${DB_PORT:-5432}"
      if have psql; then
        PGPASSWORD="${DB_PASSWORD:-}" psql -h "$host" -p "$port" -U "${DB_USERNAME:-}" -d "${DB_DATABASE:-}" -tAc "SELECT 1" >/dev/null 2>&1 && db_ok=1
      else
        (exec 3<>/dev/tcp/"$host"/"$port") >/dev/null 2>&1 && { exec 3>&-; db_ok=1; }
      fi ;;
    *) DB_STATUS="unknown driver (${DB_CONNECTION:-unset})" ;;
  esac
  [[ $db_ok -eq 1 ]] && DB_STATUS="ok" || [[ "$DB_STATUS" == unknown* ]] || DB_STATUS="down"
fi

REDIS_STATUS="skipped"
if [[ $DRY_RUN -eq 1 ]]; then
  REDIS_STATUS="skipped (dry-run)"
else
  r_ok=0
  if [[ -n "${REDIS_URL:-}" ]]; then
    r_host="$(printf "%s" "$REDIS_URL" | sed -E 's#^redis://([^:/]+).*$#\1#')"
    r_port="$(printf "%s" "$REDIS_URL" | sed -E 's#^redis://[^:/]+:([0-9]+).*$#\1#')"
  else
    r_host="${REDIS_HOST:-127.0.0.1}"
    r_port="${REDIS_PORT:-6379}"
  fi
  if have redis-cli; then
    redis-cli -h "$r_host" -p "$r_port" -e ping 2>/dev/null | grep -q PONG && r_ok=1
  else
    (exec 3<>/dev/tcp/"$r_host"/"$r_port") >/dev/null 2>&1 && { exec 3>&-; r_ok=1; }
  fi
  [[ $r_ok -eq 1 ]] && REDIS_STATUS="ok" || REDIS_STATUS="down"
fi

# ---------- Exit-Bits ----------
EXIT=0
(( actionable_missing > 0 )) && EXIT=$((EXIT | 1))
[[ "$DB_STATUS" == "down" ]]    && EXIT=$((EXIT | 2))
[[ "$REDIS_STATUS" == "down" ]] && EXIT=$((EXIT | 4))

# ---------- Formatters ----------
db_icon(){ [[ "$DB_STATUS" == "ok" ]] && echo "✅" || { [[ "$DB_STATUS" == "down" ]] && echo "❌" || echo "⚠️"; }; }
rd_icon(){ [[ "$REDIS_STATUS" == "ok" ]] && echo "✅" || { [[ "$REDIS_STATUS" == "down" ]] && echo "❌" || echo "⚠️"; }; }

to_md(){
cat <<EOF
# ${PROJECT_NAME} – $(ts_de)
Script: \`${SCRIPT_NAME}\` • Version: ${VERSION}

## Basics
- Projekt: \`${PROJECT_ROOT}\`
- APP_ENV: \`${APP_ENV:-}\`
- APP_URL: \`${APP_URL_SAFE}\`

## Binaries & Versionen
$(printf "%s\n" "${BIN_STATUS[@]}")

## PHP Extensions (wichtig)
- Fehlende: $( [[ ${#EXT_MISSING[@]} -eq 0 ]] && echo "Keine" || echo "$(join_arr "${EXT_MISSING[@]}")" )

## Datenbank
- Treiber: \`${DB_CONNECTION:-n/a}\`
- Host: \`${DB_HOST:-}\`  Port: \`${DB_PORT:-}\`  DB: \`${DB_DATABASE:-}\`
- Status: $(db_icon) \`${DB_STATUS}\`

## Redis
- Host: \`${REDIS_HOST:-${r_host:-}}\`  Port: \`${REDIS_PORT:-${r_port:-}}\`
- Status: $(rd_icon) \`${REDIS_STATUS}\`

## Exit
- Bits: \`${EXIT}\`  ( +1 fehlende Binaries (required/recommended) | +2 DB down | +4 Redis down )
EOF
}

to_json(){
  if command -v jq >/dev/null; then
    jq -n \
      --arg script "$SCRIPT_NAME" --arg version "$VERSION" --arg time "$(ts_iso)" \
      --arg project "$PROJECT_ROOT" --arg name "$PROJECT_NAME" --arg app_env "${APP_ENV:-}" --arg app_url "${APP_URL:-}" \
      --arg db_driver "${DB_CONNECTION:-}" --arg db_host "${DB_HOST:-}" --arg db_port "${DB_PORT:-}" --arg db_name "${DB_DATABASE:-}" --arg db_status "$DB_STATUS" \
      --arg rd_host "${REDIS_HOST:-${r_host:-}}" --arg rd_port "${REDIS_PORT:-${r_port:-}}" --arg rd_status "$REDIS_STATUS" \
      --argphpv "$php_v" --argcompv "$composer_v" --argnodev "$node_v" --argpnpmv "$pnpm_v" --argnpmv "$npm_v" \
      --argjson exit "$EXIT" --argjson full $([[ $FULL -eq 1 ]] && echo true || echo false) \
      --argjson bins_found "$(printf '%s\n' "${bins_found[@]}" | jq -R . | jq -s .)" \
      --argjson bins_missing "$(printf '%s\n' "${bins_missing[@]}" | jq -R . | jq -s .)" \
      --argjson ext_missing "$(printf '%s\n' "${EXT_MISSING[@]}" | jq -R . | jq -s .)" \
      '{
        meta:{script:$script,version:$version,time:$time,project:$project,name:$name,full:$full},
        basics:{app_env:$app_env,app_url:$app_url},
        binaries:{found:$bins_found,missing:$bins_missing,versions:{php:$phpv,composer:$compv,node:$nodev,pnpm:$pnpmv,npm:$npmv}},
        php:{ext_missing:$ext_missing},
        db:{driver:$db_driver,host:$db_host,port:$db_port,name:$db_name,status:$db_status},
        redis:{host:$rd_host,port:$rd_port,status:$rd_status},
        exit:$exit
      }'
  else
    # kleiner Pretty-Fallback
    esc(){ printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
    arr(){ local f=1; printf '['; for it in "$@"; do [[ $f -eq 0 ]]&&printf ','; f=0; printf '"%s"' "$(esc "$it")"; done; printf ']'; }
    echo "{"
    echo "  \"meta\": { \"script\": \"$(esc "$SCRIPT_NAME")\", \"version\": \"$(esc "$VERSION")\", \"time\": \"$(esc "$(ts_iso)")\", \"project\": \"$(esc "$PROJECT_ROOT")\", \"name\": \"$(esc "$PROJECT_NAME")\", \"full\": $([[ $FULL -eq 1 ]] && echo true || echo false) },"
    echo "  \"basics\": { \"app_env\": \"$(esc "${APP_ENV:-}")\", \"app_url\": \"$(esc "${APP_URL:-}")\" },"
    echo "  \"binaries\": {"
    echo "    \"found\": $(arr "${bins_found[@]}"),"
    echo "    \"missing\": $(arr "${bins_missing[@]}"),"
    echo "    \"versions\": { \"php\": \"$(esc "$php_v")\", \"composer\": \"$(esc "$composer_v")\", \"node\": \"$(esc "$node_v")\", \"pnpm\": \"$(esc "$pnpm_v")\", \"npm\": \"$(esc "$npm_v")\" }"
    echo "  },"
    echo "  \"php\": { \"ext_missing\": $(arr "${EXT_MISSING[@]}") },"
    echo "  \"db\": { \"driver\": \"$(esc "${DB_CONNECTION:-}")\", \"host\": \"$(esc "${DB_HOST:-}")\", \"port\": \"$(esc "${DB_PORT:-}")\", \"name\": \"$(esc "${DB_DATABASE:-}")\", \"status\": \"$(esc "$DB_STATUS")\" },"
    echo "  \"redis\": { \"host\": \"$(esc "${REDIS_HOST:-${r_host:-}}")\", \"port\": \"$(esc "${REDIS_PORT:-${r_port:-}}")\", \"status\": \"$(esc "$REDIS_STATUS")\" },"
    echo "  \"exit\": $EXIT"
    echo "}"
  fi
}

# ---------- Build & Write ----------
case "$FORMAT" in
  md)   CONTENT="$(to_md)" ;;
  json) CONTENT="$(to_json)" ;;
  *) echo "${RED}bad --format (nur md|json)${RESET}" >&2; exit 2 ;;
esac

if [[ -n "$OUTFILE" ]]; then
  [[ $DRY_RUN -eq 1 ]] && echo "[DRY-RUN] würde schreiben: $OUTFILE" || printf "%s\n" "$CONTENT" > "$OUTFILE"
else
  F="$WIKI_DIR/dev_env_info_${TS_FILE}.${FORMAT}"
  [[ $DRY_RUN -eq 1 ]] && echo "[DRY-RUN] würde schreiben: $F" || printf "%s\n" "$CONTENT" > "$F"
  printf "%s\n" "$CONTENT" > "$WIKI_DIR/last.${FORMAT}"
fi

exit $EXIT
