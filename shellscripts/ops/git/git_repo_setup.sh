#!/usr/bin/env bash
# git_repo_setup.sh — initialisiert/vereinheitlicht ein Git-Repo im Projekt-Root
# Version: 0.4.0   # +gatekeeper, +log_core integration, +Options-Zelle, +TRACE-Logs, +auto log_render_html, +robuste Meldungen

# ───────────────────────── Shell-Safety ─────────────────────────
if [ -z "${BASH_VERSION-}" ]; then exec bash "$0" "$@"; fi
set -Euo pipefail
IFS=$'\n\t'

SCRIPT_NAME="git_repo_setup.sh"
SCRIPT_VERSION="0.4.0"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
ORIG_ARGS=("$@")
ORIG_CWD="$(pwd)"

# ───────────────────────── Defaults ─────────────────────────
PROJECT_PATH=""
BRANCH="main"
REMOTE_NAME="origin"
REMOTE_URL=""
REINIT=0
NO_PUSH=0
DRY_RUN=0
DEBUG="OFF"           # OFF|ON|TRACE
DO_LOG_RENDER="ON"    # ON|OFF
RENDER_DELAY=1        # Sekunden

# ───────────────────────── Usage ─────────────────────────
usage() {
  cat <<HLP
${SCRIPT_NAME} — initialisiert/vereinheitlicht ein Git-Repo im Projekt-Root

USAGE
  ${SCRIPT_NAME} [OPTS]

OPTIONEN (Defaults in Klammern)
  -p, --path <dir>        Projektpfad (aktuelles Verzeichnis)
  --branch <name>         Ziel-Branch (main)
  -r, --remote <url>      Remote-URL setzen (leer = unverändert)
  --remote-name <name>    Remote-Name (origin)
  --reinit                .git neu anlegen (löscht .git) (aus)
  --no-push               Kein Push nach dem Setup (aus)
  --dry-run               Nur anzeigen, was passieren würde (aus)
  --do-log-render=ON|OFF  Nachlaufend log_render_html ausführen (ON)
  --render-delay=<sec>    Verzögerung vor Render-Aufruf (1)
  --debug=LEVEL           OFF | ON | TRACE (OFF)
  --version               Skriptversion
  -h, --help              Hilfe

HINWEISE
  • Gatekeeper: Skript MUSS im Projekt-Root mit vorhandener .env laufen (oder via --path dahin wechseln).
  • Reihenfolge: (optional) reinit → init/checkout -B → stage → commit → remote add/set-url → push.
HLP
}

# ───────────────────────── Parse Args ─────────────────────────
while (($#)); do
  case "$1" in
    -p|--path)           PROJECT_PATH="${2:-}"; shift 2;;
    --branch)            BRANCH="${2:-}"; shift 2;;
    -r|--remote)         REMOTE_URL="${2:-}"; shift 2;;
    --remote-name)       REMOTE_NAME="${2:-}"; shift 2;;
    --reinit)            REINIT=1; shift;;
    --no-push)           NO_PUSH=1; shift;;
    --dry-run)           DRY_RUN=1; shift;;
    --do-log-render=*)   DO_LOG_RENDER="${1#*=}"; DO_LOG_RENDER="${DO_LOG_RENDER^^}"; shift;;
    --render-delay=*)    RENDER_DELAY="${1#*=}"; shift;;
    --debug=*)           DEBUG="${1#*=}"; DEBUG="${DEBUG^^}"; shift;;
    --version)           echo "${SCRIPT_NAME} ${SCRIPT_VERSION}"; exit 0;;
    -h|--help)           usage; exit 0;;
    *) echo "Unbekannte Option: $1" >&2; usage; exit 64;;
  esac
done

# ───────────────────────── Debug-Setup ─────────────────────────
DEBUG_DIR="${HOME}/bin/debug"; mkdir -p "${DEBUG_DIR}"
DBG_TXT="${DEBUG_DIR}/git_repo_setup.debug.log"
DBG_JSON="${DEBUG_DIR}/git_repo_setup.debug.jsonl"
XTRACE="${DEBUG_DIR}/git_repo_setup.xtrace.log"
: > "${DBG_TXT}"
: > "${DBG_JSON}"
if [ "${DEBUG}" = "TRACE" ]; then
  : > "${XTRACE}"
  exec 19>>"${XTRACE}"
  export BASH_XTRACEFD=19
  export PS4='+ git_repo_setup.sh:${LINENO}:${FUNCNAME[0]-main} '
  set -x
fi
dbg_line(){ [ "${DEBUG}" != "OFF" ] && printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "${DBG_TXT}"; }
dbg_json(){ [ "${DEBUG}" != "OFF" ] && printf '{"ts":"%s","event":"%s"%s}\n'  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "${2:+,$2}" >> "${DBG_JSON}"; }
dbg_line "START ${SCRIPT_NAME} v${SCRIPT_VERSION} run_id=${RUN_ID} debug=${DEBUG} dry=${DRY_RUN}"
dbg_json "start" "\"script\":\"${SCRIPT_NAME}\",\"version\":\"${SCRIPT_VERSION}\",\"run_id\":\"${RUN_ID}\",\"cwd\":\"${ORIG_CWD}\",\"debug\":\"${DEBUG}\",\"dry\":\"${DRY_RUN}\""

cleanup(){ set +e; exec 19>&- 2>/dev/null; }
trap cleanup EXIT

# ───────────────────────── Optionen-Zelle (non-break) ─────────────────────────
nbhy_all(){ printf '%s' "${1//-/$'\u2011'}"; }  # U+2011 non-breaking hyphen
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

# ───────────────────────── Gatekeeper & Projekt ─────────────────────────
if [ -z "${PROJECT_PATH}" ]; then PROJECT_PATH="$(pwd)"; fi
if [ ! -d "${PROJECT_PATH}" ]; then
  echo "❌ Project path not found: ${PROJECT_PATH}" >&2; exit 2
fi
cd "${PROJECT_PATH}"

if [ ! -f ".env" ]; then
  echo "❌ Gatekeeper: .env nicht gefunden (im Projekt-Root ausführen)." >&2
  # Optional: log_core-Eintrag (falls verfügbar) folgt nach dem Laden
  GATE_FAIL=1
else
  GATE_FAIL=0
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
    lc_init_ctx "PRIMARY" "$(pwd)" "${RUN_ID}" "${SCRIPT_NAME}" "${SCRIPT_VERSION}" "${ORIG_CWD}" "git-setup"
    if declare -p CTX_NAMES >/dev/null 2>&1; then :; else declare -g -a CTX_NAMES; fi
    CTX_NAMES=("PRIMARY")
    [ "${LC_HAS_SETOPT}" -eq 1 ] && lc_set_opt_cell "${LC_OPT_CELL}" "${LC_OPT_CELL_IS_HTML}"
    set -u
  fi
else
  echo "⚠️ log_core.part nicht geladen → kein Markdown/JSON-Lauf-Log (nur Debugfiles)."
fi
safe_log(){ if [ "${LC_OK}" -eq 1 ]; then set +u; lc_log_event_all "$@"; set -u; fi; }

if (( GATE_FAIL==1 )); then
  safe_log ERROR "gate" "project" "missing .env" "❌" 0 2 "Start in project root required" "git,setup,gatekeeper" "aborted"
  exit 2
fi

# ───────────────────────── Reqs ─────────────────────────
if ! command -v git >/dev/null 2>&1; then
  echo '❌ git nicht gefunden.' >&2
  safe_log ERROR "req" "git" "missing" "❌" 0 3 "" "git,setup" "not installed"
  exit 3
fi

# ───────────────────────── Helper ─────────────────────────
run(){ if [ "${DRY_RUN}" -eq 1 ]; then echo "[DRY] $*"; else eval "$@"; fi; }
mk_tags(){
  local out="git,setup"
  ((DRY_RUN==1)) && out="${out},dry-run"
  printf '%s' "$out"
}

errors=0
did_reinit=0; did_init=0; did_checkout=0; did_stage=0; did_commit=0; did_remote=0; did_push=0

# ───────────────────────── Reinit (optional) ─────────────────────────
if (( REINIT==1 )) && [ -d ".git" ]; then
  if run "rm -rf .git"; then
    echo "Reinit: .git entfernt."
    safe_log INFO "git" "reinit" "\`.git\`" "✅" 0 0 "Branch=\`${BRANCH}\`" "$(mk_tags)" "removed .git"
    did_reinit=1
  else
    ((errors++))
    safe_log ERROR "git" "reinit" "\`.git\`" "❌" 0 1 "Branch=\`${BRANCH}\`" "$(mk_tags)" "failed"
  fi
fi

# ───────────────────────── init / checkout -B ─────────────────────────
if [ ! -d ".git" ]; then
  if run "git init -b \"${BRANCH}\""; then
    echo "Repo initialisiert (Branch ${BRANCH})."
    safe_log INFO "git" "init" "\`${BRANCH}\`" "✅" 0 0 "" "$(mk_tags)" "git init -b ${BRANCH}"
    did_init=1
  else
    ((errors++))
    safe_log ERROR "git" "init" "\`${BRANCH}\`" "❌" 0 1 "" "$(mk_tags)" "failed"
  fi
else
  current="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')"
  if [ -n "${current}" ] && [ "${current}" != "${BRANCH}" ]; then
    if run "git checkout -B \"${BRANCH}\""; then
      echo "Branch umgestellt: ${current} → ${BRANCH}"
      safe_log INFO "git" "checkout" "\`${BRANCH}\`" "✅" 0 0 "" "$(mk_tags)" "checkout -B ${BRANCH}"
      did_checkout=1
    else
      ((errors++))
      safe_log ERROR "git" "checkout" "\`${BRANCH}\`" "❌" 0 1 "" "$(mk_tags)" "failed"
    fi
  fi
fi

# ───────────────────────── stage & initial commit ─────────────────────────
if run "git add -A"; then
  did_stage=1
  safe_log INFO "git" "stage" "\`index\`" "✅" 0 0 "" "$(mk_tags)" "git add -A"
else
  ((errors++))
  safe_log ERROR "git" "stage" "\`index\`" "❌" 0 1 "" "$(mk_tags)" "failed"
fi

if ! git diff --cached --quiet; then
  if [ "${DRY_RUN}" -eq 1 ]; then
    echo "[DRY] git commit -m \"chore: initial commit\""
    safe_log INFO "git" "commit" "\`initial\`" "✅" 0 0 "" "$(mk_tags)" "would commit"
  else
    if git commit -m "chore: initial commit"; then
      did_commit=1
      safe_log INFO "git" "commit" "\`initial\`" "✅" 0 0 "" "$(mk_tags)" "committed"
    else
      ((errors++))
      safe_log ERROR "git" "commit" "\`initial\`" "❌" 0 1 "" "$(mk_tags)" "failed"
    fi
  fi
else
  safe_log INFO "git" "commit" "\`skip\`" "✅" 0 0 "" "$(mk_tags)" "no staged changes"
fi

# ───────────────────────── remote add / set-url ─────────────────────────
if [ -n "${REMOTE_URL}" ]; then
  if git remote get-url "${REMOTE_NAME}" >/dev/null 2>&1; then
    if run "git remote set-url \"${REMOTE_NAME}\" \"${REMOTE_URL}\""; then
      did_remote=1
      safe_log INFO "git" "set-url" "\`${REMOTE_NAME}\`" "✅" 0 0 "" "$(mk_tags)" "new=\`${REMOTE_URL}\`"
    else
      ((errors++))
      safe_log ERROR "git" "set-url" "\`${REMOTE_NAME}\`" "❌" 0 1 "" "$(mk_tags)" "failed"
    fi
  else
    if run "git remote add \"${REMOTE_NAME}\" \"${REMOTE_URL}\""; then
      did_remote=1
      safe_log INFO "git" "remote-add" "\`${REMOTE_NAME}\`" "✅" 0 0 "" "$(mk_tags)" "url=\`${REMOTE_URL}\`"
    else
      ((errors++))
      safe_log ERROR "git" "remote-add" "\`${REMOTE_NAME}\`" "❌" 0 1 "" "$(mk_tags)" "failed"
    fi
  fi
else
  safe_log INFO "git" "remote" "\`skip\`" "✅" 0 0 "" "$(mk_tags)" "no url provided"
fi

# ───────────────────────── push (optional) ─────────────────────────
if (( NO_PUSH==0 )); then
  # Push nur versuchen, wenn URL vorhanden oder Remote existiert
  if git remote get-url "${REMOTE_NAME}" >/dev/null 2>&1; then
    if [ "${DRY_RUN}" -eq 1 ]; then
      echo "[DRY] git push -u \"${REMOTE_NAME}\" \"${BRANCH}\""
      safe_log INFO "git" "push" "\`${REMOTE_NAME}/${BRANCH}\`" "✅" 0 0 "" "$(mk_tags)" "would push"
    else
      if git push -u "${REMOTE_NAME}" "${BRANCH}"; then
        did_push=1
        safe_log INFO "git" "push" "\`${REMOTE_NAME}/${BRANCH}\`" "✅" 0 0 "" "$(mk_tags)" "pushed"
      else
        ((errors++))
        safe_log ERROR "git" "push" "\`${REMOTE_NAME}/${BRANCH}\`" "❌" 0 1 "" "$(mk_tags)" "failed"
      fi
    fi
  else
    safe_log INFO "git" "push" "\`skip\`" "✅" 0 0 "" "$(mk_tags)" "no remote"
  fi
else
  safe_log INFO "git" "push" "\`skip\`" "✅" 0 0 "" "$(mk_tags)" "--no-push"
fi

# ───────────────────────── Summary ─────────────────────────
summary="reinit=${did_reinit}; init=${did_init}; checkout=${did_checkout}; stage=${did_stage}; commit=${did_commit}; remote=${did_remote}; push=${did_push}; errors=${errors}"
safe_log "$([ ${errors} -eq 0 ] && echo INFO || echo ERROR)" \
  "git" "summary" "\`${BRANCH}\`" "$([ ${errors} -eq 0 ] && echo "✅" || echo "❌")" 0 "${errors}" \
  "Remote=\`${REMOTE_NAME}\`" \
  "git,setup,summary$([ ${DRY_RUN} -eq 1 ] && echo ',dry-run')" \
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
