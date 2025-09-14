#!/usr/bin/env bash
# git_sync_rebase.sh — holt Änderungen vom Remote und rebased den lokalen Branch darauf (nur im Projekt-WD)
# Version: 0.5.0   # +gatekeeper, +log_core integration, +Options-Zelle, +TRACE-Logs, +auto log_render_html, robustes Stash, Summary

# ───────────────────────── Shell-Safety ─────────────────────────
if [ -z "${BASH_VERSION-}" ]; then exec bash "$0" "$@"; fi
set -Euo pipefail
IFS=$'\n\t'

SCRIPT_NAME="git_sync_rebase.sh"
SCRIPT_VERSION="0.5.0"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
ORIG_ARGS=("$@")
ORIG_CWD="$(pwd)"

# ───────────────────────── Defaults ─────────────────────────
REMOTE="origin"
BRANCH=""
STASH=0
DRY_RUN=0
DEBUG="OFF"           # OFF|ON|TRACE
DO_LOG_RENDER="ON"    # ON|OFF
RENDER_DELAY=1        # Sekunden

# ───────────────────────── Usage ─────────────────────────
print_help(){ cat <<'HLP'
git_sync_rebase.sh — holt Änderungen und rebased lokalen Branch auf Remote (nur im Projekt-WD)

USAGE
  git_sync_rebase.sh [OPTS]

OPTIONEN (Defaults in Klammern)
  --remote <name>         Remote-Name (origin)
  --branch <name>         Branch (aktueller Branch)
  --stash                 Unsaubere Arbeitsbäume vor Rebase stashen & danach poppen (aus)
  --dry-run               Nur anzeigen, was ausgeführt würde (aus)
  --do-log-render=ON|OFF  Nachlaufend log_render_html ausführen (ON)
  --render-delay=<sec>    Verzögerung vor Render-Aufruf (1)
  --debug=LEVEL           OFF | ON | TRACE (OFF)
  --version               Skriptversion
  -h, --help              Hilfe

HINWEISE
  • Gatekeeper: Skript MUSS im Projekt-Root mit vorhandener .env laufen.
  • Rebase-Ziel ist <remote>/<branch>; der lokale Branch bleibt gleich.
HLP
}
usage(){ print_help; exit 0; }

# ───────────────────────── Parse Args ─────────────────────────
while (($#)); do
  case "$1" in
    --remote) REMOTE="${2:-}"; shift 2;;
    --branch) BRANCH="${2:-}"; shift 2;;
    --stash) STASH=1; shift;;
    --dry-run) DRY_RUN=1; shift;;
    --do-log-render=*) DO_LOG_RENDER="${1#*=}"; DO_LOG_RENDER="${DO_LOG_RENDER^^}"; shift;;
    --render-delay=*) RENDER_DELAY="${1#*=}"; shift;;
    --debug=*) DEBUG="${1#*=}"; DEBUG="${DEBUG^^}"; shift;;
    --version) echo "${SCRIPT_NAME} ${SCRIPT_VERSION}"; exit 0;;
    -h|--help) print_help; exit 0;;
    *) printf 'Unbekannter Parameter: %s\n' "$1" >&2; usage;;
  esac
done

# ───────────────────────── Debug-Setup ─────────────────────────
DEBUG_DIR="${HOME}/bin/debug"; mkdir -p "${DEBUG_DIR}"
DBG_TXT="${DEBUG_DIR}/git_sync_rebase.debug.log"
DBG_JSON="${DEBUG_DIR}/git_sync_rebase.debug.jsonl"
XTRACE="${DEBUG_DIR}/git_sync_rebase.xtrace.log"
: > "${DBG_TXT}"
: > "${DBG_JSON}"
if [ "${DEBUG}" = "TRACE" ]; then
  : > "${XTRACE}"
  exec 19>>"${XTRACE}"
  export BASH_XTRACEFD=19
  export PS4='+ git_sync_rebase.sh:${LINENO}:${FUNCNAME[0]-main} '
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

# ───────────────────────── Gatekeeper & Reqs ─────────────────────────
if [ ! -f ".env" ]; then
  echo "❌ Gatekeeper: .env nicht gefunden (im Projekt-Root ausführen)." >&2
  GATE_FAIL=1
else
  GATE_FAIL=0
fi
if ! command -v git >/dev/null 2>&1; then
  echo '❌ git nicht gefunden.' >&2
  GIT_FAIL=1
else
  GIT_FAIL=0
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
    lc_init_ctx "PRIMARY" "$(pwd)" "${RUN_ID}" "${SCRIPT_NAME}" "${SCRIPT_VERSION}" "${ORIG_CWD}" "git-rebase"
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
  safe_log ERROR "gate" "project" "missing .env" "❌" 0 2 "Start in project root required" "git,rebase,gatekeeper" "aborted"
  exit 2
fi
if (( GIT_FAIL==1 )); then
  safe_log ERROR "req" "git" "missing" "❌" 0 3 "" "git,rebase" "not installed"
  exit 3
fi

# ───────────────────────── Helper ─────────────────────────
run_git(){ if [ "${DRY_RUN}" -eq 1 ]; then echo "[DRY] $*"; return 0; else eval "$@"; fi; }
mk_tags(){
  local out="git,rebase,sync"
  ((DRY_RUN==1)) && out="${out},dry-run"
  ((STASH==1))  && out="${out},stash"
  printf '%s' "$out"
}

# ───────────────────────── Kontext bestimmen ─────────────────────────
if [ -z "${BRANCH:-}" ]; then
  BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')"
fi
if [ -z "${BRANCH}" ] || [ "${BRANCH}" = "HEAD" ]; then
  safe_log ERROR "git" "branch" "\`detect\`" "❌" 0 4 "" "$(mk_tags)" "cannot determine branch (detached HEAD?)"
  echo "❌ Branch konnte nicht ermittelt werden (evtl. detached HEAD)." >&2
  exit 4
fi

repo_name="$(basename -- "$(pwd)")"
safe_log INFO "rebase" "start" "\`${repo_name}\`" "✅" 0 0 \
  "Remote=\`${REMOTE}\`; Branch=\`${BRANCH}\`" \
  "$(mk_tags)" \
  "begin"

# ───────────────────────── Zustand / Stash ─────────────────────────
dirty=0; git diff --quiet || dirty=1; git diff --quiet --cached || dirty=1
auto_stash_ref=""
if (( dirty==1 )); then
  if (( STASH==0 )); then
    safe_log ERROR "rebase" "precheck" "\`dirty\`" "❌" 0 5 "" "$(mk_tags)" "working tree not clean"
    echo "❌ Arbeitsbaum nicht sauber. Verwende --stash oder committe zuerst." >&2
    exit 5
  else
    msg="auto-stash before rebase ${RUN_ID}"
    if run_git "git stash push -u -m \"${msg}\""; then
      auto_stash_ref="$(git rev-parse --quiet --verify refs/stash 2>/dev/null || true)"
      safe_log INFO "rebase" "stash" "\`push\`" "✅" 0 0 "" "$(mk_tags)" "created=\`${msg}\`"
    else
      safe_log ERROR "rebase" "stash" "\`push\`" "❌" 0 6 "" "$(mk_tags)" "failed"
      echo "❌ Stash fehlgeschlagen." >&2
      exit 6
    fi
  fi
fi

# ───────────────────────── Fetch ─────────────────────────
fetch_rc=0
if run_git "git fetch \"${REMOTE}\" --prune"; then
  safe_log INFO "rebase" "fetch" "\`${REMOTE}\`" "✅" 0 0 "" "$(mk_tags)" "prune"
else
  fetch_rc=$?
  safe_log ERROR "rebase" "fetch" "\`${REMOTE}\`" "❌" 0 "${fetch_rc}" "" "$(mk_tags)" "failed"
  [ -n "${auto_stash_ref}" ] && run_git "git stash pop || true" >/dev/null 2>&1 || true
  exit "${fetch_rc}"
fi

# Existiert Remote-Branch?
if ! git ls-remote --heads "${REMOTE}" "${BRANCH}" >/dev/null 2>&1; then
  safe_log ERROR "rebase" "check" "\`${REMOTE}/${BRANCH}\`" "❌" 0 7 "" "$(mk_tags)" "remote branch not found"
  echo "❌ Remote-Branch \`${REMOTE}/${BRANCH}\` existiert nicht." >&2
  [ -n "${auto_stash_ref}" ] && run_git "git stash pop || true" >/dev/null 2>&1 || true
  exit 7
fi

# ───────────────────────── Rebase ─────────────────────────
rebase_rc=0
if run_git "git rebase \"${REMOTE}/${BRANCH}\""; then
  safe_log INFO "rebase" "apply" "\`${REMOTE}/${BRANCH}\`" "✅" 0 0 "" "$(mk_tags)" "done"
else
  rebase_rc=$?
  safe_log ERROR "rebase" "apply" "\`${REMOTE}/${BRANCH}\`" "❌" 0 "${rebase_rc}" "" "$(mk_tags)" "conflicts?"
  echo "⚠️ Rebase abgebrochen/mit Konflikten. Bitte \`git status\`, dann \`git rebase --continue|--abort\`." >&2
fi

# ───────────────────────── Stash zurückholen (falls erzeugt) ─────────────────
stash_pop_rc=0
if [ -n "${auto_stash_ref}" ]; then
  if run_git "git stash pop || true"; then
    safe_log INFO "rebase" "stash" "\`pop\`" "✅" 0 0 "" "$(mk_tags)" "restored"
  else
    stash_pop_rc=1
    safe_log ERROR "rebase" "stash" "\`pop\`" "❌" 0 1 "" "$(mk_tags)" "conflicts-on-pop"
  fi
fi

# ───────────────────────── Abschluss / Ausgabe ─────────────────────────
# kleine Übersicht
run_git "git log --oneline -n 5 --decorate --graph" || true

errors=$(( (rebase_rc!=0) + (stash_pop_rc!=0) ))
summary="fetched=1; rebase_rc=${rebase_rc}; stash=$((STASH)); stash_pop_rc=${stash_pop_rc}; errors=${errors}"
safe_log "$([ ${errors} -eq 0 ] && echo INFO || echo ERROR)" \
  "rebase" "summary" "\`${repo_name}\`" "$([ ${errors} -eq 0 ] && echo "✅" || echo "❌")" 0 "${errors}" \
  "Remote=\`${REMOTE}\`; Branch=\`${BRANCH}\`" \
  "git,rebase,summary$([ ${DRY_RUN} -eq 1 ] && echo ',dry-run')" \
  "${summary}"

# ───────────────────────── finalize & optional HTML-Render ─────────────────────
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
