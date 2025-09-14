#!/usr/bin/env bash
# git_status_short.sh — kompakter Git-Status mit optionalem Datei-Output + Projekt-Log
# Version: 0.5.0   # +gatekeeper (hart), +log_core integration, +Options-Zelle, +TRACE-Logs, +auto log_render_html, +prune, +--dry-run

# ───────────────────────── Shell-Safety ─────────────────────────
if [ -z "${BASH_VERSION-}" ]; then exec bash "$0" "$@"; fi
set -Euo pipefail
IFS=$'\n\t'

SCRIPT_NAME="git_status_short.sh"
SCRIPT_VERSION="0.5.0"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
ORIG_ARGS=("$@")
ORIG_CWD="$(pwd)"

# ───────────────────────── Defaults ─────────────────────────
DO_OUT=0                  # Datei-Output aus
FORMAT="txt"              # txt | md
MAX=10                    # wie viele Status-Dateien behalten
DRY_RUN=0                 # nur anzeigen, nichts schreiben
DEBUG="OFF"               # OFF|ON|TRACE
DO_LOG_RENDER="ON"        # am Ende log_render_html(.sh) starten
RENDER_DELAY=1            # Sekunden

# ───────────────────────── Usage ─────────────────────────
print_help(){ cat <<'HLP'
git_status_short.sh — kompakter Git-Status mit optionalem Datei-Output + Projekt-Log

USAGE
  git_status_short.sh [OPTS]

OPTIONEN (Defaults in Klammern)
  --out                   Datei-Output nach .wiki/git_status (aus)
  --format <txt|md>       Ausgabeformat (txt)
  --max <N>               Max. Dateien im Ordner behalten (10)
  --dry-run               Nur anzeigen, nichts schreiben (aus)
  --do-log-render=ON|OFF  Nachlaufend log_render_html ausführen (ON)
  --render-delay=<sec>    Verzögerung vor Render-Aufruf (1)
  --debug=LEVEL           OFF | ON | TRACE (OFF)
  --version               Skriptversion
  -h, --help              Hilfe

HINWEISE
  • Gatekeeper: Skript MUSS im Projekt-Root mit vorhandener .env laufen.
HLP
}
usage(){ print_help; exit 0; }

# ───────────────────────── Parse Args ─────────────────────────
while (($#)); do
  case "$1" in
    --out) DO_OUT=1; shift;;
    --format) FORMAT="${2:-txt}"; shift 2;;
    --max) MAX="${2:-10}"; shift 2;;
    --dry-run) DRY_RUN=1; shift;;
    --do-log-render=*) DO_LOG_RENDER="${1#*=}"; DO_LOG_RENDER="${DO_LOG_RENDER^^}"; shift;;
    --render-delay=*) RENDER_DELAY="${1#*=}"; shift;;
    --debug=*) DEBUG="${1#*=}"; DEBUG="${DEBUG^^}"; shift;;
    --version) echo "${SCRIPT_NAME} ${SCRIPT_VERSION}"; exit 0;;
    -h|--help) print_help; exit 0;;
    *) echo "Unbekannter Parameter: $1" >&2; usage;;
  esac
done

# ───────────────────────── Debug-Setup ─────────────────────────
DEBUG_DIR="${HOME}/bin/debug"; mkdir -p "${DEBUG_DIR}"
DBG_TXT="${DEBUG_DIR}/git_status_short.debug.log"
DBG_JSON="${DEBUG_DIR}/git_status_short.debug.jsonl"
XTRACE="${DEBUG_DIR}/git_status_short.xtrace.log"
: > "${DBG_TXT}"
: > "${DBG_JSON}"
if [ "${DEBUG}" = "TRACE" ]; then
  : > "${XTRACE}"
  exec 19>>"${XTRACE}"
  export BASH_XTRACEFD=19
  export PS4='+ git_status_short.sh:${LINENO}:${FUNCNAME[0]-main} '
  set -x
fi
dbg_line(){ [ "${DEBUG}" != "OFF" ] && printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "${DBG_TXT}"; }
dbg_json(){ [ "${DEBUG}" != "OFF" ] && printf '{"ts":"%s","event":"%s"%s}\n'  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "${2:+,$2}" >> "${DBG_JSON}"; }
dbg_line "START ${SCRIPT_NAME} v${SCRIPT_VERSION} run_id=${RUN_ID} dry=${DRY_RUN} debug=${DEBUG}"
dbg_json "start" "\"script\":\"${SCRIPT_NAME}\",\"version\":\"${SCRIPT_VERSION}\",\"run_id\":\"${RUN_ID}\",\"cwd\":\"${ORIG_CWD}\",\"dry\":\"${DRY_RUN}\",\"debug\":\"${DEBUG}\""

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
    local i; for ((i=0;i<${#out[@]};i++)); do printf '%s' "${out[i]}"; ((i<${#out[@]}-1)) && printf '<br />'; done
  fi
}
LC_OPT_CELL="keine"; LC_OPT_CELL_IS_HTML=1
LC_OPT_CELL="$(render_opt_cell_html_multiline)"
export LC_OPT_CELL LC_OPT_CELL_IS_HTML

# ───────────────────────── Gatekeeper & Reqs ─────────────────────────
if [ ! -f ".env" ]; then
  echo '❌ Gatekeeper: .env nicht gefunden (im Projekt-Root ausführen).' >&2
  # wir loggen gleich nach dem Laden von log_core (falls verfügbar)
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
    lc_init_ctx "PRIMARY" "$(pwd)" "${RUN_ID}" "${SCRIPT_NAME}" "${SCRIPT_VERSION}" "${ORIG_CWD}" "git-status"
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
  safe_log ERROR "gate" "project" "missing .env" "❌" 0 2 "Start in project root required" "git,status,gatekeeper" "aborted"
  exit 2
fi
if (( GIT_FAIL==1 )); then
  safe_log ERROR "req" "git" "missing" "❌" 0 3 "" "git,status" "not installed"
  exit 3
fi

# ───────────────────────── Status sammeln ─────────────────────────
repo_name="$(basename -- "$(pwd)")"
branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "-")"
commit="$(git rev-parse --short HEAD 2>/dev/null || echo "-")"
upstream="$(git rev-parse --abbrev-ref --symbolic-full-name @{u} 2>/dev/null || echo "-")"

ahead="0"; behind="0"
if [ "${upstream}" != "-" ]; then
  read -r behind ahead < <(git rev-list --left-right --count "${upstream}...HEAD" 2>/dev/null || echo "0 0")
fi

stashes="$(git stash list 2>/dev/null | wc -l | tr -d ' ' || echo 0)"
last_tag="$(git describe --tags --abbrev=0 2>/dev/null || echo "-")"
remote="$(git remote get-url origin 2>/dev/null || echo "-")"

# staged
mapfile -t staged_arr < <(git diff --cached --name-status 2>/dev/null || true)
stA=0; stM=0; stD=0; stR=0
for l in "${staged_arr[@]}"; do
  c="${l%%$'\t'*}"
  case "$c" in
    A*) ((stA++));;
    M*) ((stM++));;
    D*) ((stD++));;
    R*|C*) ((stR++));;
  esac
done
staged_total=$((stA+stM+stD+stR))

# unstaged
mapfile -t unstaged_arr < <(git diff --name-status 2>/dev/null || true)
unM=0; unD=0; unR=0
for l in "${unstaged_arr[@]}"; do
  c="${l%%$'\t'*}"
  case "$c" in
    M*) ((unM++));;
    D*) ((unD++));;
    R*|C*) ((unR++));;
  esac
done
unstaged_total=$((unM+unD+unR))

untracked=$(git ls-files --others --exclude-standard 2>/dev/null | wc -l | tr -d ' ' || echo 0)
conflicts=$(git diff --name-only --diff-filter=U 2>/dev/null | wc -l | tr -d ' ' || echo 0)

# ───────────────────────── BEGIN-Log ─────────────────────────
safe_log INFO "status" "start" "\`${repo_name}\`" "✅" 0 0 \
  "Branch=\`${branch}\`; Upstream=\`${upstream}\`" \
  "git,status,begin$([ "${DEBUG}" = "TRACE" ] && echo ',trace')$([ ${DRY_RUN} -eq 1 ] && echo ',dry-run')" \
  "collecting"

# ───────────────────────── Ausgabe bauen ─────────────────────────
if [ "${FORMAT}" = "md" ]; then
  out="$(
    printf "## Git Status (kurz)\n"
    printf "- branch: %s\n" "$branch"
    printf "- commit: %s\n" "$commit"
    printf "- upstream: %s\n" "$upstream"
    printf "- ahead/behind: %s/%s\n" "$ahead" "$behind"
    printf "- stashes: %s\n" "$stashes"
    printf "- last tag: %s\n" "$last_tag"
    printf "- remote: %s\n" "$remote"
    printf "- staged: %s (A:%s M:%s D:%s R:%s)\n" "$staged_total" "$stA" "$stM" "$stD" "$stR"
    printf "- unstaged: %s (M:%s D:%s R:%s)\n" "$unstaged_total" "$unM" "$unD" "$unR"
    printf "- untracked: %s\n" "$untracked"
    printf "- conflicts: %s\n" "$conflicts"
  )"
else
  out="$(
    printf "branch:       %s\n" "$branch"
    printf "commit:       %s\n" "$commit"
    printf "upstream:     %s\n" "$upstream"
    printf "ahead/behind: %s/%s\n" "$ahead" "$behind"
    printf "stashes:      %s\n" "$stashes"
    printf "last tag:     %s\n" "$last_tag"
    printf "remote:       %s\n" "$remote"
    printf "staged:       %s (A:%s M:%s D:%s R:%s)\n" "$staged_total" "$stA" "$stM" "$stD" "$stR"
    printf "unstaged:     %s (M:%s D:%s R:%s)\n" "$unstaged_total" "$unM" "$unD" "$unR"
    printf "untracked:    %s\n" "$untracked"
    printf "conflicts:    %s\n" "$conflicts"
  )"
fi

# Terminal
printf "%s\n" "$out"

# Log „collect“ (Detailzahlen)
safe_log INFO "status" "collect" "\`${repo_name}\`" "✅" 0 0 \
  "ahead=\`${ahead}\`; behind=\`${behind}\`" \
  "git,status,collect" \
  "staged=${staged_total} (A:${stA} M:${stM} D:${stD} R:${stR}); unstaged=${unstaged_total} (M:${unM} D:${unD} R:${unR}); untracked=${untracked}; conflicts=${conflicts}"

# ───────────────────────── Datei-Output + Housekeeping ─────────────────────────
file=""
pruned=0
pruned_list=()

if (( DO_OUT==1 )); then
  outdir=".wiki/git_status"; ext="${FORMAT}"; [ "${ext}" = "md" ] || ext="txt"
  ts="$(date +%Y%m%d_%H%M%S)"
  file="${outdir}/status_${ts}.${ext}"
  if [ "${DRY_RUN}" -eq 1 ]; then
    echo "[DRY] würde schreiben: ${file}"
    safe_log INFO "status" "write" "\`status_${ts}.${ext}\`" "✅" 0 0 \
      "Out: \`${file}\`" \
      "git,status,write,dry-run" \
      "would-write"
  else
    mkdir -p "${outdir}" || true
    if printf "%s\n" "$out" > "${file}"; then
      echo "OK: ${file}"
      safe_log INFO "status" "write" "\`$(basename -- "${file}")\`" "✅" 0 0 \
        "Out: \`${file}\`" \
        "git,status,write" \
        "wrote"
    else
      safe_log ERROR "status" "write" "\`$(basename -- "${file}")\`" "❌" 0 1 \
        "Out: \`${file}\`" \
        "git,status,write" \
        "write failed"
    fi

    # Prune
    mapfile -t files < <(ls -t "${outdir}"/status_*.${ext} 2>/dev/null || true)
    if ((${#files[@]} > MAX)); then
      for ((i=MAX;i<${#files[@]};i++)); do
        f="${files[$i]}"
        if rm -f -- "${f}"; then
          ((pruned++)); pruned_list+=("$(basename -- "${f}")")
        fi
      done
    fi
  fi
fi

# ───────────────────────── Summary ─────────────────────────
summary="file=$([ -n "${file}" ] && printf '%s' "$(basename -- "${file}")" || printf '-') ; pruned=${pruned}"
if (( pruned > 0 )); then
  for ((i=0;i<${#pruned_list[@]};i++)); do
    if [ "$i" -eq 0 ]; then summary="${summary}; files=\`${pruned_list[$i]}\`"
    else summary="${summary}<br />\`${pruned_list[$i]}\`"; fi
  done
fi
safe_log INFO "status" "summary" "\`${repo_name}\`" "✅" 0 0 \
  "Format=\`${FORMAT}\`; Max=\`${MAX}\`" \
  "git,status,summary$([ ${DRY_RUN} -eq 1 ] && echo ',dry-run')" \
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

# immer "grün" beenden
exit 0
