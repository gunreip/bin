#!/usr/bin/env bash
# backup_db_hourly.sh — stündlicher PostgreSQL-Dump (Rotation) nach <project>/.backups/db/hourly
# Version: 0.9.0
#
# Changelog:
# - 0.9.0: log_core.part-Integration (Optionen-Zelle, Start/Steps/Summary), non-breaking option flags,
#          Debug-Artefakte (TXT/JSON/XTRACE), Auto-Render via log_render_html(.sh) mit separatem --lr-debug,
#          robuste .env-Reads, frei konfigurierbares --keep / --out-dir / --no-checksum, Gatekeeper & Exit-Codes
#
# Exit-Codes:
#   0  OK
#   2  Gatekeeper (.env fehlt / nicht im Projekt-Root)
#   3  Tool fehlt (pg_dump)
#   4  DB-Konfig unvollständig
#   10 Dump fehlgeschlagen

# ───────────────────────── Shell-Safety ─────────────────────────
if [ -z "${BASH_VERSION-}" ]; then exec bash "$0" "$@"; fi
set -Euo pipefail

SCRIPT_NAME="backup_db_hourly.sh"
SCRIPT_VERSION="0.9.0"
VERSION="${SCRIPT_VERSION}"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
ORIG_CWD="$(pwd)"
ORIG_ARGS=("$@")

# ───────────────────────── Defaults ─────────────────────────
DRY_RUN=0
KEEP=24                      # Anzahl zu behaltender Dumps
OUT_DIR=".backups/db/hourly" # projektrelativ (oder absolut / mit ~)
DO_CHECKSUM=1                # sha256sum erzeugen, falls verfügbar
DEBUG="OFF"                  # OFF|ON|TRACE   (nur für dieses Skript)
DO_LOG_RENDER="ON"           # ON|OFF
RENDER_DELAY=1               # Sekunden
LR_DEBUG="OFF"               # OFF|ON|TRACE   (nur für log_render_html)
FORMAT="md"                  # unkritisch; nur für evtl. Zusatzberichte reserviert

# ───────────────────────── Hilfe ─────────────────────────
usage(){ cat <<'EOF'
backup_db_hourly — stündlicher PostgreSQL-Dump mit Rotation

Usage:
  backup_db_hourly.sh [--dry-run]
                      [--keep <N>]                 # default: 24
                      [--out-dir <PATH>]           # default: .backups/db/hourly (projektrelativ)
                      [--no-checksum]              # sha256sum nicht erzeugen
                      [--debug=OFF|ON|TRACE]       # default: OFF (nur für dieses Skript)
                      [--do-log-render=ON|OFF]     # default: ON
                      [--render-delay=<sec>]       # default: 1
                      [--lr-debug=OFF|ON|TRACE]    # default: OFF (nur für log_render_html)
                      [--format md|txt|json]       # reserviert (Report-Ausgabe), default: md
                      [--version] [--help]

Hinweise:
- Benötigt: .env im Projekt-Root mit DB_HOST, DB_PORT, DB_DATABASE, DB_USERNAME, optional DB_PASSWORD
- Nutzt 'pg_dump' aus PATH
EOF
}

# ───────────────────────── Args parsen ─────────────────────────
ARGS=()
while (($#)); do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --keep) KEEP="${2:-24}"; shift ;;
    --out-dir) OUT_DIR="${2:-.backups/db/hourly}"; shift ;;
    --no-checksum) DO_CHECKSUM=0 ;;
    --do-log-render=*) DO_LOG_RENDER="${1#*=}"; DO_LOG_RENDER="${DO_LOG_RENDER^^}" ;;
    --render-delay=*) RENDER_DELAY="${1#*=}" ;;
    --lr-debug=*) LR_DEBUG="${1#*=}"; LR_DEBUG="${LR_DEBUG^^}" ;;
    --debug|--debug=*) if [[ "$1" == --debug=* ]]; then DEBUG="${1#*=}"; else DEBUG="${2:-OFF}"; shift; fi; DEBUG="${DEBUG^^}" ;;
    --format) FORMAT="${2:-md}"; shift ;;
    --version) echo "${SCRIPT_VERSION}"; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    --) shift; ARGS+=("$@"); break ;;
    *) echo "Unbekannter Parameter: $1" >&2; usage; exit 2 ;;
  esac
  shift || true
done

# ───────────────────────── Debug-Setup ─────────────────────────
DEBUG_DIR="${HOME}/bin/debug"; mkdir -p "${DEBUG_DIR}"
DBG_TXT="${DEBUG_DIR}/backup_db_hourly.debug.log"
DBG_JSON="${DEBUG_DIR}/backup_db_hourly.debug.jsonl"
XTRACE="${DEBUG_DIR}/backup_db_hourly.xtrace.log"
: > "${DBG_TXT}"; : > "${DBG_JSON}"
if [[ "${DEBUG}" == "TRACE" ]]; then
  : > "${XTRACE}"
  exec 19>>"${XTRACE}"
  export BASH_XTRACEFD=19
  export PS4='+ backup_db_hourly.sh:${LINENO}:${FUNCNAME[0]-main} '
  set -x
fi
dbg_line(){ [[ "${DEBUG}" != "OFF" ]] && printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "${DBG_TXT}"; }
dbg_json(){ [[ "${DEBUG}" != "OFF" ]] && printf '{"ts":"%s","event":"%s"%s}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "${2:+,$2}" >> "${DBG_JSON}"; }
dbg_line "START ${SCRIPT_NAME} v${SCRIPT_VERSION} run_id=${RUN_ID} cwd=${ORIG_CWD} debug=${DEBUG} dry=${DRY_RUN}"
dbg_json "start" "\"script\":\"${SCRIPT_NAME}\",\"version\":\"${SCRIPT_VERSION}\",\"run_id\":\"${RUN_ID}\",\"cwd\":\"${ORIG_CWD}\",\"debug\":\"${DEBUG}\",\"dry\":\"${DRY_RUN}\""
cleanup(){ set +e; exec 19>&- 2>/dev/null; }
trap cleanup EXIT

# ───────────────────────── Optionen-Zelle (non-break hyphen) ─────────────────────────
nbhy_all(){ printf '%s' "${1//-/$'\u2011'}"; }  # U+2011
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

# ───────────────────────── Gatekeeper ─────────────────────────
PROJECT_ROOT="$ORIG_CWD"
if [[ ! -f "${PROJECT_ROOT}/.env" ]]; then
  echo "Fehler: .env fehlt (im Projekt-Root ausführen)" >&2
  GATE_ERR=".env missing"; GATE_FAIL=1
else
  GATE_FAIL=0
fi
if ! command -v pg_dump >/dev/null 2>&1; then
  echo "Fehler: pg_dump nicht gefunden" >&2
  GATE_ERR="${GATE_ERR:-} pg_dump missing"; GATE_FAIL=1
fi
(( GATE_FAIL==1 )) && EXIT=2 || EXIT=0

# ───────────────────────── log_core.part (optional) ─────────────────────────
export SCRIPT_NAME SCRIPT_VERSION VERSION SCRIPT
SCRIPT="${SCRIPT_NAME}"
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
    lc_init_ctx "PRIMARY" "${PROJECT_ROOT}" "${RUN_ID}" "${SCRIPT_NAME}" "${SCRIPT_VERSION}" "${ORIG_CWD}" "backup,db"
    if declare -p CTX_NAMES >/dev/null 2>&1; then :; else declare -g -a CTX_NAMES; fi
    CTX_NAMES=("PRIMARY")
    [[ "${LC_HAS_SETOPT}" -eq 1 ]] && lc_set_opt_cell "${LC_OPT_CELL}" "${LC_OPT_CELL_IS_HTML}"
    set -u
  fi
else
  echo "⚠️ log_core.part nicht geladen → kein Markdown/JSON-Lauf-Log (nur Debugfiles)."
fi
safe_log(){ if [[ "${LC_OK}" -eq 1 ]]; then set +u; lc_log_event_all "$@"; set -u; fi; }

# Gatekeeper-Fehler jetzt sauber loggen + Exit
if (( GATE_FAIL==1 )); then
  safe_log ERROR "db" "gate" "\`strict-root\`" "❌" 0 2 "Root=\`${PROJECT_ROOT}\`" "backup,db,gatekeeper$([ "${DEBUG}" = "TRACE" ] && echo ',trace')" "${GATE_ERR:-missing prerequisites}"
  exit 2
fi

# ───────────────────────── .env lesen ─────────────────────────
dotenv_get() {
  local key="$1"
  sed -nE "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*['\"]?([^\"'#]*)['\"]?.*$/\1/p" .env \
    | tail -n1 | tr -d '\r'
}
DB_HOST="$(dotenv_get DB_HOST)"
DB_PORT="$(dotenv_get DB_PORT)"
DB_DATABASE="$(dotenv_get DB_DATABASE)"
DB_USERNAME="$(dotenv_get DB_USERNAME)"
DB_PASSWORD="$(dotenv_get DB_PASSWORD)"

if [[ -z "${DB_HOST}" || -z "${DB_PORT}" || -z "${DB_DATABASE}" || -z "${DB_USERNAME}" ]]; then
  safe_log ERROR "db" "config" "\`missing-env\`" "❌" 0 4 "Keys=\`DB_HOST,DB_PORT,DB_DATABASE,DB_USERNAME\`" "backup,db,env" "incomplete"
  echo "DB-Konfiguration unvollständig (.env)" >&2
  exit 4
fi
[[ -z "${DB_PASSWORD}" ]] && dbg_line "DB_PASSWORD not set — expecting .pgpass/peer auth"

# ───────────────────────── Pfade vorbereiten ─────────────────────────
# ~ expandieren, relative Pfade projektrelativ interpretieren
expand_path(){
  local p="$1"
  if [[ "$p" == ~* ]]; then
    eval "printf '%s' \"$p\""
  elif [[ "$p" = /* ]]; then
    printf '%s' "$p"
  else
    printf '%s/%s' "${PROJECT_ROOT}" "$p"
  fi
}
OUT_DIR_ABS="$(expand_path "${OUT_DIR}")"
mkdir -p "${OUT_DIR_ABS}"

TS="$(date +%Y%m%d_%H%M%S)"
DUMP_FILE="${OUT_DIR_ABS}/${DB_DATABASE}_${TS}.sql.gz"
SHA_FILE="${DUMP_FILE}.sha256"

safe_log INFO "db" "start" "\`${DB_DATABASE}\`" "✅" 0 0 "OutDir=\`${OUT_DIR_ABS}\`; Keep=\`${KEEP}\`" \
  "backup,db,pgdump,begin$([ "${DEBUG}" = "TRACE" ] && echo ',trace')$([ ${DRY_RUN} -eq 1 ] && echo ',dry-run')" \
  "host=${DB_HOST}; port=${DB_PORT}; user=$(printf '%s' "${DB_USERNAME}" | sed -E 's/(..).+$/\1******/'); pass=$( [[ -n "${DB_PASSWORD}" ]] && echo '***' || echo '-')"

# ───────────────────────── Dump ausführen ─────────────────────────
DUMP_START=$(date +%s)
PR_BYTES=0
if [[ ${DRY_RUN} -eq 1 ]]; then
  safe_log INFO "db" "dump" "\`dry-run\`" "✅" 0 0 "Target=\`${DUMP_FILE}\`" "backup,db,pgdump,dry-run" \
    "PGPASSWORD=*** pg_dump -h '${DB_HOST}' -p '${DB_PORT}' -U '${DB_USERNAME}' '${DB_DATABASE}' | gzip -9 > '${DUMP_FILE}'"
else
  export PGPASSWORD="${DB_PASSWORD:-}"
  if pg_dump -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USERNAME}" "${DB_DATABASE}" | gzip -9 > "${DUMP_FILE}"; then
    PR_BYTES=$(stat -c '%s' "${DUMP_FILE}" 2>/dev/null || echo 0)
    safe_log INFO "db" "dump" "\`write\`" "✅" $(( $(date +%s)-DUMP_START )) 0 "File=\`$(basename -- "${DUMP_FILE}")\`" "backup,db,pgdump" "bytes=${PR_BYTES}"
  else
    safe_log ERROR "db" "dump" "\`write\`" "❌" $(( $(date +%s)-DUMP_START )) 10 "File=\`$(basename -- "${DUMP_FILE}")\`" "backup,db,pgdump" "failed"
    echo "Dump fehlgeschlagen (Credentials/pg_hba prüfen)" >&2
    exit 10
  fi
fi

# ───────────────────────── Checksumme ─────────────────────────
if (( DO_CHECKSUM==1 )); then
  if [[ ${DRY_RUN} -eq 1 ]]; then
    safe_log INFO "db" "checksum" "\`dry-run\`" "✅" 0 0 "SHA=\`$(basename -- "${SHA_FILE}")\`" "backup,db,checksum,dry-run" \
      "sha256sum '${DUMP_FILE}' > '${SHA_FILE}'"
  else
    if command -v sha256sum >/dev/null 2>&1; then
      if sha256sum "${DUMP_FILE}" > "${SHA_FILE}" 2>/dev/null; then
        safe_log INFO "db" "checksum" "\`write\`" "✅" 0 0 "SHA=\`$(basename -- "${SHA_FILE}")\`" "backup,db,checksum" "ok"
      else
        safe_log WARN "db" "checksum" "\`write\`" "⚠️" 0 0 "SHA=\`$(basename -- "${SHA_FILE}")\`" "backup,db,checksum" "failed"
      fi
    else
      safe_log WARN "db" "checksum" "\`tool-missing\`" "⚠️" 0 0 "sha256sum not found" "backup,db,checksum" "skipped"
    fi
  fi
else
  safe_log INFO "db" "checksum" "\`disabled\`" "✅" 0 0 "" "backup,db,checksum" "skipped"
fi

# ───────────────────────── Rotation ─────────────────────────
ROT_START=$(date +%s)
PRUNED=0; SEEN=0
# list newest first; anything beyond KEEP -> delete (auch .sha256)
mapfile -t _files < <(ls -1t "${OUT_DIR_ABS}/"*.sql.gz 2>/dev/null || true)
SEEN=${#_files[@]}
if (( SEEN>KEEP )); then
  for ((i=KEEP;i<SEEN;i++)); do
    f="${_files[i]}"
    (( PRUNED++ ))
    if [[ ${DRY_RUN} -eq 1 ]]; then
      safe_log INFO "rotate" "prune" "\`dry-run\`" "✅" 0 0 "Target=\`${f}\`" "backup,db,rotate,dry-run" "would-delete; also \`${f}.sha256\`"
    else
      rm -f -- "${f}" "${f}.sha256" 2>/dev/null || true
      safe_log INFO "rotate" "prune" "\`delete\`" "✅" 0 0 "Target=\`${f}\`" "backup,db,rotate" "deleted"
    fi
  done
fi
safe_log INFO "rotate" "summary" "\`keep=${KEEP}\`" "✅" $(( $(date +%s)-ROT_START )) 0 \
  "seen=${SEEN}; pruned=${PRUNED}" "backup,db,rotate,summary" \
  "$( ((PRUNED>0)) && printf '***pruned=%d***' "${PRUNED}" || printf 'pruned=0' )"

# ───────────────────────── Summary ─────────────────────────
SUMMARY="file=\`$(basename -- "${DUMP_FILE}")\`; bytes=${PR_BYTES}; keep=${KEEP}; seen=${SEEN}; $( ((PRUNED>0)) && printf '***pruned=%d***' "${PRUNED}" || printf 'pruned=0' )"
safe_log INFO "db" "summary" "\`${DB_DATABASE}\`" "✅" 0 0 "OutDir=\`${OUT_DIR_ABS}\`" \
  "backup,db,summary$([ "${DEBUG}" = "TRACE" ] && echo ',trace')$([ ${DRY_RUN} -eq 1 ] && echo ',dry-run')" \
  "${SUMMARY}"

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

exit 0
