#!/usr/bin/env bash
# git_repo_clean_old_remote.sh — Remote(s) sicher prüfen/anpassen (nur im Projekt-Working-Dir)
# Version: 0.4.0   # +gatekeeper, +log_core integration, +Options-Zelle, +TRACE-Logs, +auto log_render_html, +robuste Meldungen

# ───────────────────────── Shell-Safety ─────────────────────────
if [ -z "${BASH_VERSION-}" ]; then exec bash "$0" "$@"; fi
set -Euo pipefail
IFS=$'\n\t'

SCRIPT_NAME="git_repo_clean_old_remote.sh"
SCRIPT_VERSION="0.4.0"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
ORIG_ARGS=("$@")
ORIG_CWD="$(pwd)"

# ───────────────────────── Defaults ─────────────────────────
PROJECT_PATH=""        # default: cwd
REMOTE="origin"
REMOVE=0
RENAME_TO=""
NEW_URL=""
DRY_RUN=0
DEBUG="OFF"           # OFF|ON|TRACE
DO_LOG_RENDER="ON"    # ON|OFF
RENDER_DELAY=1        # Sekunden

usage() {
  cat <<'HLP'
git_repo_clean_old_remote.sh — Remote(s) sicher prüfen/anpassen (nur im Projekt-Working-Dir)

USAGE
  git_repo_clean_old_remote.sh [OPTS]

OPTIONEN (Defaults in Klammern)
  -p <path>               Projektpfad (aktuelles Verzeichnis)
  --remote <name>         Remote-Name (origin)
  --remove                Remote entfernen (aus)
  --rename <new_name>     Remote umbenennen (leer)
  --url <new_url>         Remote-URL setzen (leer)
  --dry-run               Nur anzeigen, was passieren würde (aus)
  --do-log-render=ON|OFF  Nachlaufend log_render_html ausführen (ON)
  --render-delay=<sec>    Verzögerung vor dem Render-Aufruf (1)
  --debug=LEVEL           OFF | ON | TRACE (OFF)
  --version               Skriptversion
  -h, --help              Hilfe

HINWEISE
  • Gatekeeper: Skript im Projekt-Root mit vorhandener .env ausführen (oder via -p dahin wechseln).
  • Aktionen-Reihenfolge: remove → rename → set-url (falls kombiniert).
HLP
}

# ───────────────────────── Parse Args ─────────────────────────
while (($#)); do
  case "$1" in
    -p) PROJECT_PATH="${2:-}"; shift 2;;
    --remote) REMOTE="${2:-}"; shift 2;;
    --remove) REMOVE=1; shift;;
    --rename) RENAME_TO="${2:-}"; shift 2;;
    --url) NEW_URL="${2:-}"; shift 2;;
    --dry-run) DRY_RUN=1; shift;;
    --do-log-render=*) DO_LOG_RENDER="${1#*=}"; DO_LOG_RENDER="${DO_LOG_RENDER^^}"; shift;;
    --render-delay=*) RENDER_DELAY="${1#*=}"; shift;;
    --debug=*) DEBUG="${1#*=}"; DEBUG="${DEBUG^^}"; shift;;
    --version) echo "${SCRIPT_NAME} ${SCRIPT_VERSION}"; exit 0;;
    -h|--help) usage; exit 0;;
    *) printf 'Unbekannte Option: %s\n' "$1" >&2; usage; exit 64;;
  esac
done

# ───────────────────────── Debug-Setup ─────────────────────────
DEBUG_DIR="${HOME}/bin/debug"; mkdir -p "${DEBUG_DIR}"
DBG_TXT="${DEBUG_DIR}/git_repo_clean_old_remote.debug.log"
DBG_JSON="${DEBUG_DIR}/git_repo_clean_old_remote.debug.jsonl"
XTRACE="${DEBUG_DIR}/git_repo_clean_old_remote.xtrace.log"
: > "${DBG_TXT}"
: > "${DBG_JSON}"
if [ "${DEBUG}" = "TRACE" ]; then
  : > "${XTRACE}"
  exec 19>>"${XTRACE}"
  export BASH_XTRACEFD=19
  export PS4='+ git_repo_clean_old_remote.sh:${LINENO}:${FUNCNAME[0]-main} '
  set -x
fi
dbg_line(){ [ "${DEBUG}" != "OFF" ] && printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "${DBG_TXT}"; }
dbg_json(){ [ "${DEBUG}" != "OFF" ] && printf '{"ts":"%s","event":"%s"%s}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "${2:+,$2}" >> "${DBG_JSON}"; }
dbg_line "START ${SCRIPT_NAME} v${SCRIPT_VERSION} run_id=${RUN_ID} debug=${DEBUG} dry=${DRY_RUN}"
dbg_json "start" "\"script\":\"${SCRIPT_NAME}\",\"version\":\"${SCRIPT_VERSION}\",\"run_id\":\"${RUN_ID}\",\"cwd\":\"${ORIG_CWD}\",\"debug\":\"${DEBUG}\",\"dry\":\"${DRY_RUN}\""

cleanup(){ set +e; exec 19>&- 2>/dev/null; }
trap cleanup EXIT

# ───────────────────────── Optionen-Zelle (non-break) ─────────────────────────
nbhy_all(){ printf '%s' "${1//-/$'\u2011'}"; }  # U+2011 (non-breaking hyphen)
render_opt_cell_html_multiline(){
  local out=() t
  for t in "${ORIG_ARGS[@]}"; do
    out+=( "<span style=\"white-space:nowrap\"><code>$(nbhy_all "$t")</code></span>" )
  done
  if ((${#out[@]}==0)); then printf '%s' "keine"
  else
    local i; for ((i=0;i<${#out[@]};i++)); do
      printf '%s' "${out[i]}"; ((i<${#out[@]}-1)) && printf '<br />'
    done
  fi
}
LC_OPT_CELL="keine"; LC_OPT_CELL_IS_HTML=1
LC_OPT_CELL="$(render_opt_cell_html_multiline)"
export LC_OPT_CELL LC_OPT_CELL_IS_HTML

# ───────────────────────── Projekt/Gatekeeper ─────────────────────────
if [ -z "${PROJECT_PATH}" ]; then PROJECT_PATH="$(pwd)"; fi
if [ ! -d "${PROJECT_PATH}" ]; then
  echo "❌ Project path not found: ${PROJECT_PATH}" >&2; exit 2
fi
cd "${PROJECT_PATH}"
if [ ! -d ".git" ]; then
  echo "❌ Not a Git repository: ${PROJECT_PATH}" >&2; exit 2
fi
if [ ! -f ".env" ]; then
  echo "❌ Gatekeeper: .env nicht gefunden (im Projekt-Root ausführen)." >&2; exit 2
fi

# ───────────────────────── log_core.part (optional) ─────────────────────────
export SCRIPT_NAME SCRIPT_VERSION VERSION="${SCRIPT_VERSION}" SCRIPT="${SCRIPT_NAME}"
LC_OK=0; LC_HAS_INIT=0; LC_HAS_FINALIZE=0; LC_HAS_SETOPT=0
if [ -r "${HOME}/bin/parts/log_core.part" ]; then
  # shellcheck disable=SC1090
  . "${HOME}/bin/parts/log_core.part" || true
  set +u; LC_ORIG_ARGS=("${ORIG_ARGS[@]}"); set -u
  command -v lc_log_event_all >/dev/null 2>&1 && LC_OK=1 || LC_OK=0
  command -v lc_init_ctx     >/dev/null 2>&1 && LC_HAS_INIT=1 || true
  command -v lc_finalize     >/dev/null 2>&1 && LC_HAS_FINALIZE=1 || true
  command -v lc_set_opt_cell >/dev/null 2>&1 && LC_HAS_SETOPT=1 || true
  if [ "${LC_OK}" -eq 1 ] && [ "${LC_HAS_INIT}" -eq 1 ]; then
    set +u
    lc_init_ctx "PRIMARY" "$(pwd)" "${RUN_ID}" "${SCRIPT_NAME}" "${SCRIPT_VERSION}" "${ORIG_CWD}" "git-remote"
    if declare -p CTX_NAMES >/dev/null 2>&1; then :; else declare -g -a CTX_NAMES; fi
    CTX_NAMES=("PRIMARY")
    [ "${LC_HAS_SETOPT}" -eq 1 ] && lc_set_opt_cell "${LC_OPT_CELL}" "${LC_OPT_CELL_IS_HTML}"
    set -u
  fi
else
  echo "⚠️ log_core.part nicht geladen → kein Markdown/JSON-Lauf-Log (nur Debugfiles)."
fi
safe_log(){ if [ "${LC_OK}" -eq 1 ]; then set +u; lc_log_event_all "$@"; set -u; fi; }

# ───────────────────────── Helper ─────────────────────────
run(){ if [ "${DRY_RUN}" -eq 1 ]; then echo "[DRY] $*"; else eval "$@"; fi; }
mk_tags(){
  local out="git,remote"
  ((DRY_RUN==1)) && out="${out},dry-run"
  printf '%s' "$out"
}

# ───────────────────────── Zustand prüfen ─────────────────────────
if ! git remote | grep -qx "${REMOTE}"; then
  echo "❌ Remote '${REMOTE}' not found." >&2
  safe_log ERROR "remote" "check" "\`${REMOTE}\`" "❌" 0 2 "Repo: \`$(basename -- "$(pwd)")\`" "$(mk_tags)" "missing"
  exit 2
fi

CUR_URL="$(git remote get-url "${REMOTE}" 2>/dev/null || true)"
safe_log INFO "remote" "inspect" "\`${REMOTE}\`" "✅" 0 0 \
  "Repo: \`$(basename -- "$(pwd)")\`" \
  "$(mk_tags)" \
  "url=\`${CUR_URL:-<no-url>}\`"

echo "Current remote: ${REMOTE} -> ${CUR_URL:-<no-url>}"

# ───────────────────────── Aktionen ausführen ─────────────────────────
errors=0
did_remove=0; did_rename=0; did_seturl=0

if (( REMOVE==1 )); then
  if run "git remote remove \"${REMOTE}\""; then
    echo "Removed remote: ${REMOTE}"
    safe_log INFO "remote" "remove" "\`${REMOTE}\`" "✅" 0 0 "Repo: \`$(basename -- "$(pwd)")\`" "$(mk_tags)" "removed"
    did_remove=1
  else
    ((errors++))
    safe_log ERROR "remote" "remove" "\`${REMOTE}\`" "❌" 0 1 "Repo: \`$(basename -- "$(pwd)")\`" "$(mk_tags)" "failed"
  fi
fi

if [ -n "${RENAME_TO}" ] && (( did_remove==0 )); then
  if run "git remote rename \"${REMOTE}\" \"${RENAME_TO}\""; then
    echo "Renamed remote: ${REMOTE} -> ${RENAME_TO}"
    safe_log INFO "remote" "rename" "\`${REMOTE}\`→\`${RENAME_TO}\`" "✅" 0 0 "Repo: \`$(basename -- "$(pwd)")\`" "$(mk_tags)" "renamed"
    REMOTE="${RENAME_TO}"
    did_rename=1
  else
    ((errors++))
    safe_log ERROR "remote" "rename" "\`${REMOTE}\`→\`${RENAME_TO}\`" "❌" 0 1 "Repo: \`$(basename -- "$(pwd)")\`" "$(mk_tags)" "failed"
  fi
fi

if [ -n "${NEW_URL}" ] && (( did_remove==0 )); then
  if run "git remote set-url \"${REMOTE}\" \"${NEW_URL}\""; then
    echo "Updated URL for ${REMOTE} -> ${NEW_URL}"
    safe_log INFO "remote" "set-url" "\`${REMOTE}\`" "✅" 0 0 "Repo: \`$(basename -- "$(pwd)")\`" "$(mk_tags)" "new=\`${NEW_URL}\`"
    did_seturl=1
  else
    ((errors++))
    safe_log ERROR "remote" "set-url" "\`${REMOTE}\`" "❌" 0 1 "Repo: \`$(basename -- "$(pwd)")\`" "$(mk_tags)" "failed"
  fi
fi

if (( REMOVE==0 && did_rename==0 && did_seturl==0 )); then
  echo "ℹ️ Keine Aktion angefordert (nutze --remove / --rename / --url)."
  safe_log INFO "remote" "noop" "\`${REMOTE}\`" "✅" 0 0 "Repo: \`$(basename -- "$(pwd)")\`" "$(mk_tags)" "no-op"
fi

# ───────────────────────── Summary ─────────────────────────
summary="removed=${did_remove}; renamed=${did_rename}; seturl=${did_seturl}; errors=${errors}"
safe_log INFO "remote" "summary" "\`${REMOTE}\`" "$([ ${errors} -eq 0 ] && echo "✅" || echo "❌")" 0 "${errors}" \
  "Repo: \`$(basename -- "$(pwd)")\`" \
  "git,remote,summary$([ ${DRY_RUN} -eq 1 ] && echo ',dry-run')" \
  "${summary}"

# ───────────────────────── finalize & optional HTML-Render ─────────────────────────
command -v lc_finalize >/dev/null 2>&1 && [ "${LC_OK}" -eq 1 ] && lc_finalize || true

if [ "${DO_LOG_RENDER}" = "ON" ]; then
  sleep "${RENDER_DELAY}" || true
  LR_CMD=""
  if command -v log_render_html >/dev/null 2>&1; then
    LR_CMD="log_render_html"
  elif command -v log_render_html.sh >/dev/null 2>&1; then
    LR_CMD="log_render_html.sh"
  fi
  if [ -n "${LR_CMD}" ]; then
    LR_ARGS=()
    [ "${DEBUG}" = "TRACE" ] && LR_ARGS+=(--debug=TRACE)
    if "${LR_CMD}" "${LR_ARGS[@]}"; then
      echo "✅ LOG wurde gerendert!"
    else
      echo "⚠️ LOG-Rendering fehlgeschlagen (\"${LR_CMD} ${LR_ARGS[*]-}\")."
    fi
  else
    echo "ℹ️ log_render_html(.sh) nicht gefunden – Rendern übersprungen."
  fi
fi

exit "${errors}"
