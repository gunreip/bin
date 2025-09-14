#!/usr/bin/env bash
# git_commit_push.sh — staged Änderungen committen & pushen (nur im Projekt-Working-Dir)
# Version: 0.4.0   # +auto log_render_html (default ON), +--render-delay, stabile Optionszelle, CTX fix

# ───────────────────────── Shell-Safety ─────────────────────────
if [ -z "${BASH_VERSION-}" ]; then exec bash "$0" "$@"; fi
set -Euo pipefail
IFS=$'\n\t'

SCRIPT_NAME="git_commit_push.sh"
SCRIPT_VERSION="0.4.0"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
ORIG_ARGS=("$@")
ORIG_CWD="$(pwd)"

# ───────────────────────── Defaults/Optionen ─────────────────────────
REMOTE="origin"
BRANCH=""
DRY_RUN=0
AMEND=0
NO_VERIFY=0
ADD_ALL=0
ADD_PATHS=""
MSG=""
DEBUG="OFF"           # OFF|ON|TRACE
DO_LOG_RENDER="ON"    # ON|OFF  → am Ende automatisch log_render_html(.sh) ausführen
RENDER_DELAY=1        # Sekunden Verzögerung vor dem Rendern

usage() {
  cat <<'HLP'
git_commit_push.sh — staged Änderungen committen & pushen (nur im Projekt-Working-Dir)

USAGE
  git_commit_push.sh [OPTS]

OPTIONEN (Defaults in Klammern)
  --all                   Alle Änderungen stagen (git add -A) (aus)
  --add "<paths>"         Bestimmte Dateien/Pattern stagen (leer)
  -m "<message>"          Commit-Message (Pflicht, außer --amend)
  --amend                 Letzten Commit ändern (aus)
  --no-verify             Git-Hooks beim Commit/Push überspringen (aus)
  --remote <name>         Remote-Name (origin)
  --branch <name>         Branch (aktueller Branch)
  --dry-run               Nur anzeigen, was ausgeführt würde (aus)
  --do-log-render=ON|OFF  Nachlaufend log_render_html ausführen (ON)
  --render-delay=<sec>    Verzögerung vor Render-Aufruf (1)
  --debug=LEVEL           OFF (Default) | ON | TRACE
  --version               Skriptversion
  -h, --help              Diese Hilfe

HINWEIS
  • Gatekeeper: Skript muss im Projekt-Root laufen (mit .env).
HLP
}

# ───────────────────────── Parse Args ─────────────────────────
while (($#)); do
  case "$1" in
    --remote) REMOTE="$2"; shift 2;;
    --branch) BRANCH="$2"; shift 2;;
    --all) ADD_ALL=1; shift;;
    --add) ADD_PATHS="$2"; shift 2;;
    -m) MSG="$2"; shift 2;;
    --amend) AMEND=1; shift;;
    --no-verify) NO_VERIFY=1; shift;;
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
DBG_TXT="${DEBUG_DIR}/git_commit_push.debug.log"
DBG_JSON="${DEBUG_DIR}/git_commit_push.debug.jsonl"
XTRACE="${DEBUG_DIR}/git_commit_push.xtrace.log"
: > "${DBG_TXT}"
: > "${DBG_JSON}"
if [ "${DEBUG}" = "TRACE" ]; then
  : > "${XTRACE}"
  exec 19>>"${XTRACE}"
  export BASH_XTRACEFD=19
  export PS4='+ git_commit_push.sh:${LINENO}:${FUNCNAME[0]-main} '
  set -x
fi
dbg_line(){ [ "${DEBUG}" != "OFF" ] && printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "${DBG_TXT}"; }
dbg_json(){ [ "${DEBUG}" != "OFF" ] && printf '{"ts":"%s","event":"%s"%s}\n'  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "${2:+,$2}" >> "${DBG_JSON}"; }
dbg_line "START ${SCRIPT_NAME} v${SCRIPT_VERSION} run_id=${RUN_ID} dry_run=${DRY_RUN} debug=${DEBUG}"
dbg_json "start" "\"script\":\"${SCRIPT_NAME}\",\"version\":\"${SCRIPT_VERSION}\",\"run_id\":\"${RUN_ID}\",\"cwd\":\"${ORIG_CWD}\",\"dry_run\":\"${DRY_RUN}\",\"debug\":\"${DEBUG}\""

# ───────────────────────── Optionen-Zelle (non-break) ─────────────────────────
nbhy_all(){ printf '%s' "${1//-/$'\u2011'}"; }  # U+2011 non-breaking hyphen
render_opt_cell_html_multiline(){
  local out=() t
  for t in "${ORIG_ARGS[@]}"; do
    out+=( "<span style=\"white-space:nowrap\"><code>$(nbhy_all "$t")</code></span>" )
  done
  if ((${#out[@]}==0)); then
    printf '%s' "keine"
  else
    local i n; n=${#out[@]}
    for ((i=0;i<n;i++)); do printf '%s' "${out[i]}"; ((i<n-1)) && printf '<br />'; done
  fi
}
LC_OPT_CELL="keine"; LC_OPT_CELL_IS_HTML=1
LC_OPT_CELL="$(render_opt_cell_html_multiline)"
export LC_OPT_CELL LC_OPT_CELL_IS_HTML  # wichtig für log_core

# ───────────────────────── log_core.part einbinden ─────────────────────────
export SCRIPT_NAME SCRIPT_VERSION VERSION="${SCRIPT_VERSION}" SCRIPT="${SCRIPT_NAME}"

LC_OK=0; LC_HAS_INIT=0; LC_HAS_FINALIZE=0; LC_HAS_SETOPT=0
if [ -r "${HOME}/bin/parts/log_core.part" ]; then
  # shellcheck disable=SC1090
  . "${HOME}/bin/parts/log_core.part" || true
  set +u; LC_ORIG_ARGS=("${ORIG_ARGS[@]}"); set -u
  if command -v lc_log_event_all >/dev/null 2>&1; then LC_OK=1; fi
  command -v lc_init_ctx     >/dev/null 2>&1 && LC_HAS_INIT=1 || true
  command -v lc_finalize     >/dev/null 2>&1 && LC_HAS_FINALIZE=1 || true
  command -v lc_set_opt_cell >/dev/null 2>&1 && LC_HAS_SETOPT=1 || true
else
  echo "⚠️ log_core.part nicht geladen → kein Markdown/JSON-Lauf-Log (nur Debugfiles)."
fi

# ───────────────────────── Gatekeeper ─────────────────────────
if [ ! -f ".env" ]; then
  echo "❌ Gatekeeper: .env nicht gefunden (im Projekt-Root ausführen)." >&2
  dbg_line "Gatekeeper failed: no .env"
  dbg_json "gatekeeper" "\"ok\":0"
  if [ "${LC_OK}" -eq 1 ]; then
    set +u; lc_log_event_all ERROR "gate" "project" "missing .env" "❌" 0 2 "Start in project root required" "git,commit,push,gatekeeper" "aborted"; set -u
  fi
  exit 2
fi

# ───────────────────────── Git vorhanden? ─────────────────────────
if ! command -v git >/dev/null 2>&1; then
  echo '❌ git nicht gefunden.' >&2
  exit 3
fi

# ───────────────────────── log_core-Kontext ─────────────────────────
if [ "${LC_OK}" -eq 1 ] && [ "${LC_HAS_INIT}" -eq 1 ]; then
  set +u
  lc_init_ctx "PRIMARY" "$(pwd)" "${RUN_ID}" "${SCRIPT_NAME}" "${SCRIPT_VERSION}" "${ORIG_CWD}" "git"
  # Kontextliste hart setzen, damit lc_log_event_all einen gültigen Prefix hat
  if declare -p CTX_NAMES >/dev/null 2>&1; then :; else declare -g -a CTX_NAMES; fi
  CTX_NAMES=("PRIMARY")
  [ "${LC_HAS_SETOPT}" -eq 1 ] && lc_set_opt_cell "${LC_OPT_CELL}" "${LC_OPT_CELL_IS_HTML}"
  set -u
fi

# ───────────────────────── Helper ─────────────────────────
run_git(){
  if [ "${DRY_RUN}" -eq 1 ]; then
    echo "[DRY] $*"
    return 0
  else
    eval "$@"
  fi
}
mk_tags(){
  local out="git"
  [ "$1" = "stage" ]  && out="${out},stage"
  [ "$1" = "commit" ] && out="${out},commit"
  [ "$1" = "push" ]   && out="${out},push"
  ((DRY_RUN==1))   && out="${out},dry-run"
  ((NO_VERIFY==1)) && out="${out},no-verify"
  ((AMEND==1))     && out="${out},amend"
  printf '%s' "$out"
}

# ───────────────────────── Staging ─────────────────────────
stage_note=""
stage_rc=0
if ((ADD_ALL==1)); then
  run_git "git add -A" || stage_rc=$?
  stage_note="git add -A"
fi
if [ -n "${ADD_PATHS}" ]; then
  run_git "git add -- ${ADD_PATHS}" || stage_rc=$?
  stage_note="${stage_note:+${stage_note}; }git add -- ${ADD_PATHS}"
fi
[ -z "${stage_note}" ] && stage_note="(none)"

if [ "${LC_OK}" -eq 1 ]; then
  set +u
  lc_log_event_all "$([ ${stage_rc} -eq 0 ] && echo INFO || echo ERROR)" \
    "git" "stage" "\`index\`" "$([ ${stage_rc} -eq 0 ] && echo "✅" || echo "❌")" 0 "${stage_rc}" \
    "Branch: \`${BRANCH:-(auto)}\`; Remote: \`${REMOTE}\`" \
    "$(mk_tags stage)" \
    "staged: ${stage_note}"
  set -u
fi
[ "${stage_rc}" -ne 0 ] && exit "${stage_rc}"

# ───────────────────────── Branch ermitteln ─────────────────────────
if [ -z "${BRANCH:-}" ]; then
  BRANCH="$(git rev-parse --abbrev-ref HEAD)"
fi

# ───────────────────────── Commit ─────────────────────────
commit_rc=0
commit_action=""
commit_note=""

if ! git diff --quiet --cached; then
  if ((AMEND==1)); then
    commit_action="amend"
    if [ -n "${MSG}" ]; then
      commit_note="--amend -m (custom message)"
      run_git "git commit --amend -m \"$(printf '%s' "$MSG")\" $([ ${NO_VERIFY} -eq 1 ] && printf -- '--no-verify')" || commit_rc=$?
    else
      commit_note="--amend --no-edit"
      run_git "git commit --amend --no-edit $([ ${NO_VERIFY} -eq 1 ] && printf -- '--no-verify')" || commit_rc=$?
    fi
  else
    commit_action="commit"
    if [ -z "${MSG}" ]; then
      echo '❌ Commit-Message fehlt (verwende -m "...").' >&2
      commit_rc=4
    else
      commit_note="-m …"
      run_git "git commit -m \"$(printf '%s' "$MSG")\" $([ ${NO_VERIFY} -eq 1 ] && printf -- '--no-verify')" || commit_rc=$?
    fi
  fi
else
  if ((AMEND==1)); then
    commit_action="amend(no-changes)"
    if [ -n "${MSG}" ]; then
      commit_note="--amend -m (force amend)"
      run_git "git commit --amend -m \"$(printf '%s' "$MSG")\" $([ ${NO_VERIFY} -eq 1 ] && printf -- '--no-verify')" || commit_rc=$?
    else
      commit_note="--amend --no-edit (force amend)"
      run_git "git commit --amend --no-edit $([ ${NO_VERIFY} -eq 1 ] && printf -- '--no-verify')" || commit_rc=$?
    fi
  else
    commit_action="skip"
    commit_note="no staged changes"
  fi
fi

if [ "${LC_OK}" -eq 1 ]; then
  set +u
  lc_log_event_all "$([ ${commit_rc} -eq 0 ] && echo INFO || echo ERROR)" \
    "git" "commit" "\`${commit_action}\`" "$([ ${commit_rc} -eq 0 ] && echo "✅" || echo "❌")" 0 "${commit_rc}" \
    "Branch: \`${BRANCH}\`" \
    "$(mk_tags commit)" \
    "action=${commit_action}; ${commit_note}"
  set -u
fi
[ "${commit_rc}" -ne 0 ] && exit "${commit_rc}"

# ───────────────────────── Push ─────────────────────────
push_rc=0
if git remote get-url "${REMOTE}" >/dev/null 2>&1; then
  run_git "git push -u \"${REMOTE}\" \"${BRANCH}\" $([ ${NO_VERIFY} -eq 1 ] && printf -- '--no-verify')" || push_rc=$?
else
  echo "❌ Remote \"${REMOTE}\" existiert nicht." >&2
  push_rc=5
fi

if [ "${LC_OK}" -eq 1 ]; then
  set +u
  lc_log_event_all "$([ ${push_rc} -eq 0 ] && echo INFO || echo ERROR)" \
    "git" "push" "\`${REMOTE}/${BRANCH}\`" "$([ ${push_rc} -eq 0 ] && echo "✅" || echo "❌")" 0 "${push_rc}" \
    "Remote: \`${REMOTE}\`; Branch: \`${BRANCH}\`" \
    "$(mk_tags push)" \
    "pushed=${REMOTE}/${BRANCH}"
  [ "${LC_HAS_FINALIZE}" -eq 1 ] && lc_finalize
  set -u
fi

# ───────────────────────── optional HTML-Render ─────────────────────────
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

exit "${push_rc}"
