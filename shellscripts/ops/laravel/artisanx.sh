#!/usr/bin/env bash
# artisanx.sh — smarter php artisan Wrapper (nur aus Projekt-Root!)
# Version: 0.5.3
# Changelog:
# - 0.5.3: DEBUG wird NICHT mehr automatisch an log_render_html(.sh) weitergereicht.
#          Neue Option: --lr-debug=OFF|ON|TRACE (Default OFF) für Render-Debug.
# - 0.5.2: Fix für "declare -x"-Spam (kein nacktes 'export'; sicherer .env-Import)
# - 0.5.1: Fix Array-Längenprüfung + 'endesac'→'esac'
# - 0.5.0: log_core Integration, Debugfiles, Auto-Render

# ───────────────────────── Shell-Safety ─────────────────────────
if [ -z "${BASH_VERSION-}" ]; then exec bash "$0" "$@"; fi
set -Euo pipefail

SCRIPT_NAME="artisanx.sh"
SCRIPT_VERSION="0.5.3"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
ORIG_ARGS=("$@")
ORIG_CWD="$(pwd)"

# ───────────────────────── Defaults ─────────────────────────
DRY_RUN=0
FORMAT="md"            # md|txt|json
OUTFILE=""
COLOR_MODE="auto"      # auto|always|never
DEBUG="OFF"            # OFF|ON|TRACE  (nur für artisanx)
PHP_MEMORY="${ARTISANX_MEMORY:-1G}"
CAPTURE_LINES=120
DO_LOG_RENDER="ON"     # ON|OFF
RENDER_DELAY=1         # Sekunden
LR_DEBUG="OFF"         # OFF|ON|TRACE  (nur für log_render_html)

# ───────────────────────── Usage ─────────────────────────
usage(){ cat <<'EOF'
artisanx — Wrapper für php artisan (NUR im Projekt-Root ausführen)

Usage:
  artisanx [--dry-run] [--format md|txt|json] [--out <file>]
           [--color auto|always|never] [--memory <VAL>]
           [--debug=OFF|ON|TRACE] [--capture-lines <N>]
           [--do-log-render=ON|OFF] [--render-delay=<sec>]
           [--lr-debug=OFF|ON|TRACE]
           [--version] [--help] -- <artisan args...>

Beispiele:
  artisanx                                # entspricht: php artisan list
  artisanx -- --version                   # Artisan-Version
  artisanx --format md -- --help          # Hilfe in Markdown-Datei
  artisanx --dry-run -- --migrate         # Vorschau, kein echter Lauf
EOF
}

# ───────────────────────── Parse Args ─────────────────────────
ARGS=()
while (($#)); do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --format) FORMAT="${2:-md}"; shift ;;
    --out) OUTFILE="${2:-}"; shift ;;
    --color) COLOR_MODE="${2:-auto}"; shift ;;
    --memory) PHP_MEMORY="${2:-1G}"; shift ;;
    --capture-lines) CAPTURE_LINES="${2:-120}"; shift ;;
    --do-log-render=*) DO_LOG_RENDER="${1#*=}"; DO_LOG_RENDER="${DO_LOG_RENDER^^}" ;;
    --render-delay=*) RENDER_DELAY="${1#*=}" ;;
    --lr-debug=*) LR_DEBUG="${1#*=}"; LR_DEBUG="${LR_DEBUG^^}" ;;     # NEU: eigenes Render-Debug
    --debug|--debug=*) if [[ "$1" == --debug=* ]]; then DEBUG="${1#*=}"; else DEBUG="${2:-OFF}"; shift; fi; DEBUG="${DEBUG^^}" ;;
    --version) echo "${SCRIPT_VERSION}"; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    --) shift; ARGS+=("$@"); break ;;
    *) ARGS+=("$1") ;;
  esac
  shift || true
done

# ───────────────────────── Colors ─────────────────────────
setup_colors(){
  local use=0
  case "$COLOR_MODE" in
    always) use=1 ;;
    never)  use=0 ;;
    auto)   [[ -t 1 ]] && use=1 || use=0 ;;
  esac
  if [[ $use -eq 1 ]]; then
    BOLD=$'\e[1m'; DIM=$'\e[2m'; RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; BLUE=$'\e[34m'; RESET=$'\e[0m'
  else
    BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; RESET=""
  fi
}
setup_colors

# ───────────────────────── Debug-Setup ─────────────────────────
DEBUG_DIR="${HOME}/bin/debug"; mkdir -p "${DEBUG_DIR}"
DBG_TXT="${DEBUG_DIR}/artisanx.debug.log"
DBG_JSON="${DEBUG_DIR}/artisanx.debug.jsonl"
XTRACE="${DEBUG_DIR}/artisanx.xtrace.log"
: > "${DBG_TXT}"; : > "${DBG_JSON}"
if [[ "${DEBUG}" == "TRACE" ]]; then
  : > "${XTRACE}"
  exec 19>>"${XTRACE}"
  export BASH_XTRACEFD=19
  export PS4='+ artisanx.sh:${LINENO}:${FUNCNAME[0]-main} '
  set -x
fi
dbg_line(){ [[ "${DEBUG}" != "OFF" ]] && printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "${DBG_TXT}"; }
dbg_json(){ [[ "${DEBUG}" != "OFF" ]] && printf '{"ts":"%s","event":"%s"%s}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "${2:+,$2}" >> "${DBG_JSON}"; }
dbg_line "START ${SCRIPT_NAME} v${SCRIPT_VERSION} run_id=${RUN_ID} debug=${DEBUG} dry=${DRY_RUN}"
dbg_json "start" "\"script\":\"${SCRIPT_NAME}\",\"version\":\"${SCRIPT_VERSION}\",\"run_id\":\"${RUN_ID}\",\"cwd\":\"${ORIG_CWD}\",\"debug\":\"${DEBUG}\",\"dry\":\"${DRY_RUN}\""
cleanup(){ set +e; exec 19>&- 2>/dev/null; }
trap cleanup EXIT

# ───────────────────────── Optionen-Zelle (non-break hyphen) ─────────────────────────
nbhy_all(){ printf '%s' "${1//-/$'\u2011'}"; }  # U+2011 (non-breaking hyphen)
render_opt_cell_html_multiline(){
  local out=() t
  for t in "${ORIG_ARGS[@]}"; do
    out+=( "<span style=\"white-space:nowrap\"><code>$(nbhy_all "$t")</code></span>" )
  done
  if ((${#out[@]}==0)); then printf '%s' "keine"
  else
    local i; for ((i=0;i<${#out[@]};i++)); do printf '%s' "${out[i]}"; ((i<${#out[@]}-1)) && printf '<br />'; done
  fi
}
LC_OPT_CELL="keine"; LC_OPT_CELL_IS_HTML=1
LC_OPT_CELL="$(render_opt_cell_html_multiline)"

# ───────────────────────── STRICT ROOT Gatekeeper ─────────────────────────
PROJECT_ROOT="$PWD"
if [[ ! -f "$PROJECT_ROOT/artisan" ]]; then
  echo "${RED}[ERROR]${RESET} 'artisan' fehlt im aktuellen Ordner." >&2
  GATE_ERR="missing artisan"; GATE_FAIL=1
else
  GATE_FAIL=0
fi
if [[ ! -f "$PROJECT_ROOT/.env" ]]; then
  echo "${RED}[ERROR]${RESET} .env fehlt im aktuellen Ordner." >&2
  GATE_ERR="${GATE_ERR:-} missing .env"; GATE_FAIL=1
fi

# ───────────────────────── log_core.part (optional) ─────────────────────────
export SCRIPT_NAME SCRIPT_VERSION VERSION="${SCRIPT_VERSION}" SCRIPT="${SCRIPT_NAME}"
export LC_OPT_CELL LC_OPT_CELL_IS_HTML
LC_OK=0; LC_HAS_INIT=0; LC_HAS_FINALIZE=0; LC_HAS_SETOPT=0
if [[ -r "${HOME}/bin/parts/log_core.part" ]]; then
  # shellcheck disable=SC1090
  . "${HOME}/bin/parts/log_core.part" || true
  set +u; LC_ORIG_ARGS=("${ORIG_ARGS[@]}"); set -u
  command -v lc_log_event_all >/dev/null 2>&1 && LC_OK=1 || LC_OK=0
  command -v lc_init_ctx     >/dev/null 2>&1 && LC_HAS_INIT=1 || true
  command -v lc_finalize     >/dev/null 2>&1 && LC_HAS_FINALIZE=1 || true
  command -v lc_set_opt_cell >/dev/null 2>&1 && LC_HAS_SETOPT=1 || true
  if [[ "${LC_OK}" -eq 1 && "${LC_HAS_INIT}" -eq 1 ]]; then
    set +u
    lc_init_ctx "PRIMARY" "${PROJECT_ROOT}" "${RUN_ID}" "${SCRIPT_NAME}" "${SCRIPT_VERSION}" "${ORIG_CWD}" "artisanx"
    if declare -p CTX_NAMES >/dev/null 2>&1; then :; else declare -g -a CTX_NAMES; fi
    CTX_NAMES=("PRIMARY")
    [[ "${LC_HAS_SETOPT}" -eq 1 ]] && lc_set_opt_cell "${LC_OPT_CELL}" "${LC_OPT_CELL_IS_HTML}"
    set -u
  fi
else
  echo "⚠️ log_core.part nicht geladen → kein Markdown/JSON-Lauf-Log (nur Debugfiles)."
fi
safe_log(){ if [[ "${LC_OK}" -eq 1 ]]; then set +u; lc_log_event_all "$@"; set -u; fi; }

# Gatekeeper -> ggf. LOG + Exit
if (( GATE_FAIL==1 )); then
  safe_log ERROR "gate" "project" "strict-root" "❌" 0 2 "${GATE_ERR:-missing prerequisites}" "php,artisan,gatekeeper" "aborted"
  exit 2
fi

cd "${PROJECT_ROOT}"

# ───────────────────────── ENV (selektive Keys sicher importieren) ─────────────────────────
declare -a _env_pairs=()
while IFS= read -r line; do
  [[ -z "$line" || "$line" == \#* ]] && continue
  _env_pairs+=("$line")
done < <(grep -E '^(APP_ENV|APP_URL|DB_HOST|DB_DATABASE|DB_USERNAME|DB_PASSWORD)=' .env 2>/dev/null || true)
if ((${#_env_pairs[@]})); then
  for kv in "${_env_pairs[@]}"; do export "$kv"; done
fi
unset _env_pairs

mask(){ sed -E 's/([A-Za-z0-9]{2})([A-Za-z0-9]+)([A-Za-z0-9]{2})/\1******\3/g'; }
ts(){ date +"%Y-%m-%d %H:%M:%S%z"; }

# ───────────────────────── .wiki Pfade ─────────────────────────
WIKI_DIR="$PROJECT_ROOT/.wiki/dev/cli"
mkdir -p "$WIKI_DIR"
find "$WIKI_DIR" -type f -mtime +30 -delete 2>/dev/null || true
TS_FILE="$(date +%F_%H%M%S)"

# ───────────────────────── Defaults für Artisan-Args ─────────────────────────
if ((${#ARGS[@]}==0)); then
  ARGS=( list )
fi

# ───────────────────────── Command bauen ─────────────────────────
CMD=( php -d "memory_limit=${PHP_MEMORY}" -d "zend.exception_ignore_args=0" artisan "${ARGS[@]}" )
ARTISAN_STR="$(printf "%q " "${CMD[@]}")"
EXIT=0
START_EPOCH=$(date +%s)
PREVIEW=""
CONSOLE_MD="$WIKI_DIR/artisanx_console_${TS_FILE}.md"

# LOG: Start
safe_log INFO "artisan" "start" "\`$(basename -- "${PROJECT_ROOT}")\`" "✅" 0 0 \
  "Format=\`${FORMAT}\`; Memory=\`${PHP_MEMORY}\`; Capture=\`${CAPTURE_LINES}\`" \
  "php,artisan,begin$([ "${DEBUG}" = "TRACE" ] && echo ',trace')$([ ${DRY_RUN} -eq 1 ] && echo ',dry-run')" \
  "cmd=\`${ARTISAN_STR}--no-interaction\`"

# ───────────────────────── Run / Dry-Run ─────────────────────────
if [[ $DRY_RUN -eq 1 ]]; then
  PREVIEW="$(php artisan -V 2>/dev/null | head -n1 || true)"
  {
    echo "# artisanx console (dry-run) — v${SCRIPT_VERSION}"
    echo "Zeit: $(ts)"; echo
    echo "Command:"; echo '```bash'; echo "${ARTISAN_STR} --no-interaction"; echo '```'; echo
    echo "Output (nur Info-Zeile, da --dry-run):"; echo '```'; [[ -n "$PREVIEW" ]] && echo "$PREVIEW"; echo '```'
  } > "$CONSOLE_MD"
  RUNTIME_SEC=0
  safe_log INFO "artisan" "run" "\`dry-run\`" "✅" 0 0 "Console=\`$(basename -- "${CONSOLE_MD}")\`" "php,artisan,run,dry-run" "preview-only"
else
  TMP_RAW="$(mktemp)"
  set +e
  env XDEBUG_MODE=off COMPOSER_DISABLE_XDEBUG_WARN=1 "${CMD[@]}" --no-interaction 2>&1 | tee "$TMP_RAW"
  EXIT=${PIPESTATUS[0]}
  set -e
  PREVIEW="$(head -n "${CAPTURE_LINES}" "$TMP_RAW" 2>/dev/null || true)"
  {
    echo "# artisanx console — v${SCRIPT_VERSION}"
    echo "Zeit: $(ts)"; echo
    echo "Command:"; echo '```bash'; echo "${ARTISAN_STR} --no-interaction"; echo '```'; echo
    echo "Output:"; echo '```'; cat "$TMP_RAW"; echo '```'
  } > "$CONSOLE_MD"
  rm -f "$TMP_RAW"
  RUNTIME_SEC=$(( $(date +%s) - START_EPOCH ))
  safe_log "$([ ${EXIT} -eq 0 ] && echo INFO || echo ERROR)" \
    "artisan" "run" "\`$(printf '%s' "${ARGS[0]:-list}")\`" "$([ ${EXIT} -eq 0 ] && echo '✅' || echo '❌')" \
    "${RUNTIME_SEC}" "${EXIT}" \
    "Console=\`$(basename -- "${CONSOLE_MD}")\`" \
    "php,artisan,run" \
    "exit=${EXIT}; runtime=${RUNTIME_SEC}s"
fi

APP_URL_SAFE="$(printf "%s" "${APP_URL:-}" | mask)"
DB_USER_SAFE="$(printf "%s" "${DB_USERNAME:-}" | mask)"

# ───────────────────────── Formatter ─────────────────────────
to_md(){ cat <<EOF
# artisanx Report (v${SCRIPT_VERSION})
Zeit: $(ts)
Projekt: ${PROJECT_ROOT}
APP_ENV: ${APP_ENV:-}
APP_URL: ${APP_URL_SAFE:-}
DB_USER: ${DB_USER_SAFE:-}
Dry-Run: $([[ $DRY_RUN -eq 1 ]] && echo YES || echo NO)
Memory: ${PHP_MEMORY}
Xdebug: off

## Command
\`\`\`bash
${ARTISAN_STR}
\`\`\`

## Ergebnis
Exit-Code: ${EXIT}
Runtime: ${RUNTIME_SEC}s
Konsole (erste ${CAPTURE_LINES} Zeilen):
\`\`\`
${PREVIEW}
\`\`\`

Vollständige Konsole: \`$(basename "$CONSOLE_MD")\`
EOF
}
to_txt(){
  echo "script=${SCRIPT_NAME} version=${SCRIPT_VERSION} time=$(ts) project=${PROJECT_ROOT} dry_run=${DRY_RUN} exit=${EXIT} runtime=${RUNTIME_SEC}s memory=${PHP_MEMORY}"
  echo "cmd=${ARTISAN_STR}"
  echo "console_file=$(basename "$CONSOLE_MD")"
  echo "preview_start"
  printf "%s\n" "$PREVIEW"
  echo "preview_end"
}
to_json(){
  if command -v jq >/dev/null 2>&1; then
    jq -n \
      --arg script "$SCRIPT_NAME" --arg version "$SCRIPT_VERSION" \
      --arg time "$(ts)" --arg project "$PROJECT_ROOT" \
      --arg cmd "$ARTISAN_STR" --arg mem "$PHP_MEMORY" \
      --arg console_file "$(basename "$CONSOLE_MD")" \
      --arg preview "$PREVIEW" --argjson preview_lines "$CAPTURE_LINES" \
      --argjson dry $([[ $DRY_RUN -eq 1 ]]&&echo true||echo false) \
      --argjson exit "$EXIT" --argjson runtime "$RUNTIME_SEC" \
      '{script:$script,version:$version,time:$time,project:$project,dry_run:$dry,php_memory:$mem,cmd:$cmd,exit:$exit,runtime_sec:$runtime,console:{file:$console_file,preview_lines:$preview_lines,preview:$preview}}'
  else
    to_txt
  fi
}

# ───────────────────────── Report erzeugen ─────────────────────────
CONTENT=""
case "$FORMAT" in
  md)   CONTENT="$(to_md)" ;;
  txt)  CONTENT="$(to_txt)" ;;
  json) CONTENT="$(to_json)" ;;
  *) echo "${RED}bad --format${RESET}" >&2; safe_log ERROR "artisan" "format" "\`$FORMAT\`" "❌" 0 2 "" "php,artisan" "invalid format"; exit 2;;
esac

if [[ -n "${OUTFILE}" ]]; then
  TARGET_FILE="${OUTFILE}"
else
  TARGET_FILE="$WIKI_DIR/${TS_FILE}_artisanx.${FORMAT}"
fi

if [[ $DRY_RUN -eq 1 ]]; then
  echo "[DRY-RUN] würde schreiben: ${TARGET_FILE}"
  safe_log INFO "artisan" "write" "\`dry-run\`" "✅" 0 0 "Out=\`${TARGET_FILE}\`" "php,artisan,write,dry-run" "would-write"
else
  printf "%s\n" "$CONTENT" > "${TARGET_FILE}"
  printf "%s\n" "$CONTENT" > "$WIKI_DIR/last.${FORMAT}"
  safe_log INFO "artisan" "write" "\`$(basename -- "${TARGET_FILE}")\`" "✅" 0 0 "Out=\`${TARGET_FILE}\`" "php,artisan,write" "wrote"
fi

# ───────────────────────── Summary ─────────────────────────
summary="exit=${EXIT}; runtime=${RUNTIME_SEC}s; file=\`$(basename -- "${TARGET_FILE}")\`"
safe_log "$([ ${EXIT} -eq 0 ] && echo INFO || echo ERROR)" \
  "artisan" "summary" "\`$(basename -- "${PROJECT_ROOT}")\`" "$([ ${EXIT} -eq 0 ] && echo '✅' || echo '❌')" \
  "${RUNTIME_SEC}" "${EXIT}" \
  "Format=\`${FORMAT}\`; Memory=\`${PHP_MEMORY}\`" \
  "php,artisan,summary$([ "${DEBUG}" = "TRACE" ] && echo ',trace')$([ ${DRY_RUN} -eq 1 ] && echo ',dry-run')" \
  "${summary}"

# ───────────────────────── finalize & optional HTML-Render ─────────────────────
command -v lc_finalize >/dev/null 2>&1 && [[ "${LC_OK}" -eq 1 ]] && lc_finalize || true

if [[ "${DO_LOG_RENDER}" == "ON" ]]; then
  sleep "${RENDER_DELAY}" || true
  LR_CMD=""
  if command -v log_render_html >/dev/null 2>&1; then
    LR_CMD="log_render_html"
  elif command -v log_render_html.sh >/dev/null 2>&1; then
    LR_CMD="log_render_html.sh"
  fi
  if [[ -n "${LR_CMD}" ]]; then
    LR_ARGS=()
    # Wichtig: artisanx DEBUG NICHT automatisch durchreichen!
    # Nur wenn explizit --lr-debug gesetzt wurde:
    case "${LR_DEBUG}" in
      ON|TRACE) LR_ARGS+=(--debug="${LR_DEBUG}") ;;
      OFF|*) : ;;
    esac
    if "${LR_CMD}" "${LR_ARGS[@]}"; then
      echo "✅ LOG wurde gerendert!"
    else
      echo "⚠️ LOG-Rendering fehlgeschlagen (\"${LR_CMD} ${LR_ARGS[*]-}\")."
    fi
  else
    echo "ℹ️ log_render_html(.sh) nicht gefunden – Rendern übersprungen."
  fi
fi

exit "${EXIT}"
