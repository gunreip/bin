#!/usr/bin/env bash
# laravel_workspace_scan.sh — Laravel Workspace Snapshot
# v0.6.3  (Patch: Funktions-Newlines + "shellcheck disable=" Kopfzeile)
#
# Erzeugt Markdown- und JSON-Snapshots eines Laravel-Projekts.
# Unicode ist standardmäßig aktiv; Notfall ASCII via --unicode=no.
# Snapshots liegen unter <project>/.wiki/logs/laravel_workspace_scan/
# Dated-Files: <scriptname>_<deep|flat>_<ts>.md; Anzahl via --keep N, oder nur latest.* via --no-history.

# shellcheck disable=
SCRIPT_STATE=1

set -euo pipefail

SCRIPT_VERSION="v0.6.3"

# ---------- Flags / Defaults ----------
PROJECT_PATH=""
STRUCTURE_MODE="flat"    # flat|deep
ENV_VIEW="redact"        # redact|raw
ALLOW_SECRETS=0
WIKI=1
PROJLOG=1
VERBOSE=0
UNICODE=1                # Unicode standardmäßig AN
NO_HISTORY=0             # nur latest.* schreiben, keine dated *.md
KEEP=5                   # wie viele dated Snapshots behalten

# ---------- Helpers ----------
ok() { printf "\033[1;32m%s\033[0m\n" "$*"; }
warn(){ printf "\033[1;33m%s\033[0m\n" "$*"; }
err() { printf "\033[1;31m%s\033[0m\n" "$*"; }
prompt(){ printf "\033[1;31m\$ %s\033[0m\n" "$*"; }
run(){ local c="$*"; [[ $VERBOSE -eq 1 ]] && prompt "$c"; bash -c "$c"; }
md_escape(){ sed 's/\\/\\\\/g; s/`/\\`/g'; }
TICK="$(printf '\x60')"  # Backtick-Token

# Parts (optional)
[[ -f "$HOME/bin/parts/log_core.part" ]] && source "$HOME/bin/parts/log_core.part"

# ---------- CLI ----------
print_version(){ echo "laravel_workspace_scan.sh ${SCRIPT_VERSION}"; }

print_help(){
  cat <<EOF
laravel_workspace_scan.sh ${SCRIPT_VERSION}
Snapshot eines Laravel-Projekts (Markdown + JSON). Unicode ist standardmäßig aktiv.

Usage:
  laravel_workspace_scan.sh [-p PATH] [--structure flat|deep]
                            [--env redact|raw] [--allow-secrets]
                            [--unicode[=yes|no] | --no-unicode]
                            [--no-history] [--keep N]
                            [--no-wiki] [--no-projlog] [--verbose]
                            [--version] [--help]
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--project) PROJECT_PATH="${2:-}"; shift 2;;
    --structure)  STRUCTURE_MODE="${2:-flat}"; shift 2;;
    --structure=*) STRUCTURE_MODE="${1#*=}"; shift 1;;
    --env)        ENV_VIEW="${2:-redact}"; shift 2;;
    --env=*)      ENV_VIEW="${1#*=}"; shift 1;;
    --allow-secrets) ALLOW_SECRETS=1; shift;;
    --unicode)    UNICODE=1; shift;;
    --unicode=yes)UNICODE=1; shift;;
    --unicode=no|--no-unicode) UNICODE=0; shift;;
    --no-history) NO_HISTORY=1; shift;;
    --keep)       KEEP="${2:-5}"; shift 2;;
    --keep=*)     KEEP="${1#*=}"; shift 1;;
    --no-wiki)    WIKI=0; shift;;
    --no-projlog) PROJLOG=0; shift;;
    --verbose)    VERBOSE=1; shift;;
    --version|-V) print_version; exit 0;;
    --help|-h)    print_help; exit 0;;
    *) err "Unknown parameter: $1"; exit 2;;
  esac
done

# ---------- Projekt auflösen ----------
[[ -z "${PROJECT_PATH}" ]] && PROJECT_PATH="$(pwd)"
[[ -f "${PROJECT_PATH}/.env" ]] || { err "Not a Laravel project root (.env missing): ${PROJECT_PATH}"; exit 2; }
PROJECT_NAME="$(basename "${PROJECT_PATH}")"
BASE_NAME="$(basename "$0")"; BASE_NAME="${BASE_NAME%.sh}"

# ---------- Artefaktpfade (vereinheitlicht + Migration) ----------
NEW_DIR="${PROJECT_PATH}/.wiki/logs/laravel_workspace_scan"
OLD_A="${PROJECT_PATH}/.wiki/project_scans"
OLD_B="${PROJECT_PATH}/.wiki/laravel_workspace_scans"

migrate_dir(){
  local src="$1"
  [[ -d "$src" ]] || return 0
  mkdir -p "$NEW_DIR"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --ignore-existing "$src"/ "$NEW_DIR"/
  else
    cp -an "$src"/. "$NEW_DIR"/ 2>/dev/null || true
  fi
  rm -rf "$src"
  ln -s "$NEW_DIR" "$src"
}

migrate_dir "$OLD_A"
migrate_dir "$OLD_B"

SCAN_DIR="$NEW_DIR"
mkdir -p "$SCAN_DIR"

STAMP="$(date +"%Y%m%d_%H%M")"
RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$((RANDOM%90000+10000))}"
NOW_HUMAN="$(date +"%Y-%m-%d %H:%M")"

LATEST_MD="${SCAN_DIR}/latest.md"
LATEST_JSON="${SCAN_DIR}/latest.json"
HISTORY_JSONL="${SCAN_DIR}/history.jsonl"

# Ziel-Datei für den Lauf:
if [[ $NO_HISTORY -eq 1 ]]; then
  SCAN_FILE="${SCAN_DIR}/.tmp_${BASE_NAME}_${STRUCTURE_MODE}_${STAMP}.md"   # temp
else
  SCAN_FILE="${SCAN_DIR}/${BASE_NAME}_${STRUCTURE_MODE}_${STAMP}.md"
fi

# ---------- Zeichensätze ----------
if [[ $UNICODE -eq 1 ]]; then
  ICON_FOLDER="📁 "
  ICON_RUNTIME="🧩 "
  CONN_MID="├──"
  CONN_LAST="└──"
  CONT_MID="│   "
  CONT_LAST="    "
else
  ICON_FOLDER=""
  ICON_RUNTIME=""
  CONN_MID="+--"
  CONN_LAST="${TICK}--"
  CONT_MID="|   "
  CONT_LAST="    "
fi

# ---------- .env Handling ----------
env_is_safe_key(){
  case "$1" in
    APP_NAME|APP_ENV|APP_DEBUG|APP_URL|DB_CONNECTION|DB_HOST|DB_PORT|DB_DATABASE) return 0;;
    *) return 1;;
  esac
}

env_redacted_dump(){
  while IFS='=' read -r k v; do
    [[ -z "$k" || "$k" =~ ^# ]] && continue
    if env_is_safe_key "$k"; then printf '%s=%s\n' "$k" "$v"; else printf '%s=%s\n' "$k" "****"; fi
  done < "${PROJECT_PATH}/.env"
}

env_raw_dump(){
  [[ $ALLOW_SECRETS -eq 1 ]] || { err "--env=raw benötigt --allow-secrets"; exit 3; }
  cat "${PROJECT_PATH}/.env"
}

# ---------- Writer ----------
: > "${SCAN_FILE}"

line(){
  printf '%s\n' "$1" >> "${SCAN_FILE}"
}

open_fence(){
  line '```text'
}

close_fence(){
  line '```'
}

line "# Laravel Projekt-Scan – ${SCRIPT_VERSION}"
line ""
line "- Projekt: ${PROJECT_NAME}"
line "- Projektpfad: \`${PROJECT_PATH}\`"
line "- Erstellt am: ${NOW_HUMAN}"
line "- Version: ${SCRIPT_VERSION}"
line "- Struktur: ${STRUCTURE_MODE}"
line ""

# Struktur
line "## ${ICON_FOLDER}Projektstruktur"
line ""
open_fence

mapfile -t DIRS  < <(find "${PROJECT_PATH}" -maxdepth 1 -mindepth 1 -type d ! -name ".git" -printf '%f\n' | LC_ALL=C sort)
mapfile -t FILES < <(find "${PROJECT_PATH}" -maxdepth 1 -mindepth 1 -type f -printf '%f\n' | LC_ALL=C sort)

line "${PROJECT_NAME}"
total=$(( ${#DIRS[@]} + ${#FILES[@]} ))
idx=0

for name in "${DIRS[@]}"; do
  idx=$((idx+1))
  if [[ $idx -eq $total ]]; then
    conn="$CONN_LAST"; cont="$CONT_LAST"
  else
    conn="$CONN_MID";  cont="$CONT_MID"
  fi
  if [[ "$name" == "vendor" || "$name" == "node_modules" ]]; then
    line "${conn} ${ICON_FOLDER}${name}"
    if [[ "${STRUCTURE_MODE}" == "deep" ]]; then
      mapfile -t SUBS < <(find "${PROJECT_PATH}/${name}" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | LC_ALL=C sort)
      subcount=${#SUBS[@]}
      subi=0
      for sub in "${SUBS[@]}"; do
        subi=$((subi+1))
        if [[ $subi -eq $subcount ]]; then subconn="$CONN_LAST"; subcont="$CONT_LAST"; else subconn="$CONN_MID"; subcont="$CONT_MID"; fi
        line "${subcont}${subconn} ${ICON_FOLDER}${sub}"
      done
    else
      line "${cont}${CONN_LAST} ..."
    fi
  else
    line "${conn} ${ICON_FOLDER}${name}"
  fi
done

for name in "${FILES[@]}"; do
  idx=$((idx+1))
  if [[ $idx -eq $total ]]; then conn="$CONN_LAST"; else conn="$CONN_MID"; fi
  line "${conn} ${name}"
done

close_fence
line ""

# .env
line "## Ausgewählte .env-Einträge"
line ""
open_fence
if [[ "$ENV_VIEW" == "raw" ]]; then
  env_raw_dump >> "${SCAN_FILE}" || true
else
  env_redacted_dump >> "${SCAN_FILE}" || true
fi
close_fence
line ""

# Versionen
line "## ${ICON_RUNTIME}Laufzeit-Versionen"
line ""
open_fence
command -v php     >/dev/null 2>&1 && php -v | head -n 1 >> "${SCAN_FILE}" || line "(php nicht gefunden)"
if [[ -x "${PROJECT_PATH}/artisan" ]] && command -v php >/dev/null 2>&1; then
  (cd "${PROJECT_PATH}" && php artisan --version) >> "${SCAN_FILE}" 2>/dev/null || true
fi
command -v node    >/dev/null 2>&1 && node -v >> "${SCAN_FILE}" || line "(node nicht gefunden)"
command -v npm     >/dev/null 2>&1 && npm -v  >> "${SCAN_FILE}" || line "(npm nicht gefunden)"
command -v composer>/dev/null 2>&1 && composer --version | head -n1 >> "${SCAN_FILE}" || true
close_fence
line ""

# Composer/NPM kompakt
line "## Composer require"
open_fence
if [[ -f "${PROJECT_PATH}/composer.json" ]] && command -v jq >/dev/null 2>&1; then
  jq '.require // {}' "${PROJECT_PATH}/composer.json" >> "${SCAN_FILE}" || true
else
  echo "{}" >> "${SCAN_FILE}"
fi
close_fence
line ""

line "## NPM dependencies"
open_fence
if [[ -f "${PROJECT_PATH}/package.json" ]] && command -v jq >/dev/null 2>&1; then
  jq '.dependencies // {}' "${PROJECT_PATH}/package.json" >> "${SCAN_FILE}" 2>/dev/null || true
else
  echo "{}" >> "${SCAN_FILE}"
fi
close_fence
line ""

# ---------- JSON latest.json + history.jsonl ----------
PHV="$(command -v php >/dev/null 2>&1 && php -v | head -n1 | sed 's/"/\\"/g' || echo "php n/a")"
ARV="$([[ -x "${PROJECT_PATH}/artisan" ]] && command -v php >/dev/null 2>&1 && (cd "${PROJECT_PATH}" && php artisan --version) || echo "artisan n/a")"
NDV="$(command -v node >/dev/null 2>&1 && node -v || echo "node n/a")"
NPV="$(command -v npm  >/dev/null 2>&1 && npm -v || echo "npm n/a")"
CMV="$(command -v composer >/dev/null 2>&1 && composer --version | head -n1 || echo "composer n/a")"

to_json_array(){
  if command -v jq >/dev/null 2>&1; then
    printf '%s\n' "$@" | jq -R . | jq -s .
  else
    local first=1
    printf '['
    for x in "$@"; do
      [[ $first -eq 0 ]] && printf ','
      first=0
      printf '"%s"' "$(printf '%s' "$x" | sed 's/"/\\"/g')"
    done
    printf ']'
  fi
}

ROOT_DIRS_JSON="$(to_json_array "${DIRS[@]}")"
ROOT_FILES_JSON="$(to_json_array "${FILES[@]}")"
COMPOSER_REQ="{}"; NPM_DEPS="{}"
if command -v jq >/dev/null 2>&1; then
  [[ -f "${PROJECT_PATH}/composer.json" ]] && COMPOSER_REQ="$(jq -c '.require // {}' "${PROJECT_PATH}/composer.json" 2>/dev/null || echo '{}')"
  [[ -f "${PROJECT_PATH}/package.json"  ]] && NPM_DEPS="$(jq -c '.dependencies // {}' "${PROJECT_PATH}/package.json" 2>/dev/null || echo '{}')"
fi

# latest.json (safe_env wird unten gesetzt)
{
  printf '{\n'
  printf '  "run_id":"%s",\n' "$RUN_ID"
  printf '  "timestamp":"%s",\n' "$(date -Iseconds)"
  printf '  "project":{"name":"%s","path":"%s"},\n' "$PROJECT_NAME" "$PROJECT_PATH"
  printf '  "structure_mode":"%s",\n' "$STRUCTURE_MODE"
  printf '  "root":{"dirs":%s,"files":%s},\n' "$ROOT_DIRS_JSON" "$ROOT_FILES_JSON"
  printf '  "versions":{"php":"%s","artisan":"%s","node":"%s","npm":"%s","composer":"%s"},\n' "$PHV" "$ARV" "$NDV" "$NPV" "$CMV"
  printf '  "safe_env":{},\n'
  printf '  "composer_require":%s,\n' "$COMPOSER_REQ"
  printf '  "npm_dependencies":%s\n' "$NPM_DEPS"
  printf '}\n'
} > "${LATEST_JSON}"

if command -v jq >/dev/null 2>&1; then
  if [[ "$ENV_VIEW" == "raw" && $ALLOW_SECRETS -eq 1 ]]; then
    SAFE_ENV_JSON="$(awk -F= 'NF>=2&&!/^#/ {gsub(/"/,"\\\"",$2); printf "\"%s\":\"%s\",",$1,$2}' "${PROJECT_PATH}/.env" | sed 's/,$//')"
  else
    SAFE_ENV_JSON="$(awk -F= 'NF>=2&&!/^#/ {
      gsub(/"/,"\\\"",$2);
      if($1 ~ /^(APP_NAME|APP_ENV|APP_DEBUG|APP_URL|DB_CONNECTION|DB_HOST|DB_PORT|DB_DATABASE)$/){printf "\"%s\":\"%s\",",$1,$2}
      else{printf "\"%s\":\"****\",",$1}
    }' "${PROJECT_PATH}/.env" | sed 's/,$//')"
  fi
  printf '{%s}\n' "$SAFE_ENV_JSON" > "${SCAN_DIR}/.tmp_env.json"
  jq '.safe_env = input' "${LATEST_JSON}" "${SCAN_DIR}/.tmp_env.json" > "${LATEST_JSON}.tmp" 2>/dev/null || true
  [[ -s "${LATEST_JSON}.tmp" ]] && mv "${LATEST_JSON}.tmp" "${LATEST_JSON}"
  rm -f "${SCAN_DIR}/.tmp_env.json" "${LATEST_JSON}.tmp" 2>/dev/null || true
fi

# history.jsonl
cat "${LATEST_JSON}" >> "${HISTORY_JSONL}" 2>/dev/null || true

# latest.md aktualisieren
cp -f "${SCAN_FILE}" "${LATEST_MD}"

# temporäre SCAN_FILE entsorgen, falls NO_HISTORY
if [[ $NO_HISTORY -eq 1 ]]; then
  rm -f "${SCAN_FILE}" 2>/dev/null || true
fi

# ---------- Cleanup ----------
cleanup_keep_last(){
  local pattern="$1"; local keep="${2:-5}"
  mapfile -t files < <(ls -1t -- $pattern 2>/dev/null || true)
  local cnt="${#files[@]}"
  if [[ $cnt -gt $keep ]]; then
    local to_remove=("${files[@]:$keep}")
    [[ ${#to_remove[@]} -gt 0 ]] && rm -f -- "${to_remove[@]}" 2>/dev/null || true
  fi
}

if [[ $NO_HISTORY -eq 0 ]]; then
  cleanup_keep_last "${SCAN_DIR}/${BASE_NAME}_flat_*\.md" "$KEEP"
  cleanup_keep_last "${SCAN_DIR}/${BASE_NAME}_deep_*\.md" "$KEEP"
fi

# ---------- Projekt-LOG (Optionen je Zeile) ----------
if [[ ${PROJLOG} -eq 1 ]] && command -v lc_start_run >/dev/null 2>&1; then
  lc_start_run
  if [[ $NO_HISTORY -eq 0 ]]; then
    LOG_OUT="$(lc_fmt_paths_md "${SCAN_FILE}" "${LATEST_MD}" "${LATEST_JSON}")"
  else
    LOG_OUT="$(lc_fmt_paths_md "${LATEST_MD}" "${LATEST_JSON}")"
  fi

  NOW_HMS="$(date +%T)"
  declare -a OPTS_ARR=()
  OPTS_ARR+=("--structure=${STRUCTURE_MODE}")
  [[ "${ENV_VIEW}" != "redact" ]] && OPTS_ARR+=("--env=${ENV_VIEW}")
  [[ ${ALLOW_SECRETS} -eq 1 ]] && OPTS_ARR+=("--allow-secrets")
  [[ ${WIKI} -eq 0 ]] && OPTS_ARR+=("--no-wiki")
  [[ ${PROJLOG} -eq 0 ]] && OPTS_ARR+=("--no-projlog")
  [[ ${VERBOSE} -eq 1 ]] && OPTS_ARR+=("--verbose")
  [[ ${UNICODE} -eq 0 ]] && OPTS_ARR+=("--unicode=no")
  [[ ${NO_HISTORY} -eq 1 ]] && OPTS_ARR+=("--no-history")
  [[ ${KEEP} != "5" ]] && OPTS_ARR+=("--keep=${KEEP}")

  OPT_CELL=""
  for opt in "${OPTS_ARR[@]}"; do
    OPT_CELL="${OPT_CELL:+${OPT_CELL}<br />}${TICK}${opt}${TICK}"
  done
  [[ -z "$OPT_CELL" ]] && OPT_CELL="keine"

  lc_log_row_v2 "$NOW_HMS" "laravel_workspace_scan.sh" "${SCRIPT_VERSION#v}" "$OPT_CELL" \
    "workspace" "scan" "auto" "laravel, scan" "✅" "0" "0" "$(id -un)" \
    "Projekt=${PROJECT_NAME}" "root dirs=$((${#DIRS[@]})); files=$((${#FILES[@]}))" "$LOG_OUT"
fi

# ---------- HTML-Render (best-effort) ----------
if command -v lc_render_html >/dev/null 2>&1; then
  lc_render_html
elif command -v log_render_html >/dev/null 2>&1; then
  ( cd "${PROJECT_PATH}" && log_render_html )
fi

exit 0
