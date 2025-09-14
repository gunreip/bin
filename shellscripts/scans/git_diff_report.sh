#!/usr/bin/env bash
# git_diff_report.sh — schreibt Diff-Report als Markdown nach .wiki/git_diffs/ (nur im Projekt-Root)
# Version: 0.6.0   # +options cell fix (export), +auto log_render_html (ON by default), +--render-delay

# ───────────────────────── Shell-Safety ─────────────────────────
if [ -z "${BASH_VERSION-}" ]; then exec bash "$0" "$@"; fi
set -Euo pipefail
IFS=$'\n\t'

SCRIPT_NAME="git_diff_report.sh"
SCRIPT_VERSION="0.6.0"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
ORIG_ARGS=("$@")
ORIG_CWD="$(pwd)"

# ───────────────────────── Defaults ─────────────────────────
DRY=0
STAGED=0
AGAINST=""
FORMAT="summary"     # summary | name-only | full
MAX=5
DEBUG="OFF"          # OFF|ON|TRACE
DO_LOG_RENDER="ON"   # ON|OFF
RENDER_DELAY=1       # Sekunden

# ───────────────────────── Usage ─────────────────────────
print_help(){ cat <<'HLP'
git_diff_report.sh — schreibt Diff-Report als Markdown nach .wiki/git_diffs/ (nur im Projekt-WD)

USAGE
  git_diff_report.sh [OPTS]

OPTIONEN (Defaults in Klammern)
  --against <ref>         Vergleichs-Ref (Upstream, sonst origin/<branch>, sonst HEAD~1)
  --staged                Nur staged Änderungen (aus)
  --format <f>            summary | name-only | full (summary)
  --max <N>               Max. Anzahl Reports behalten (5)
  --dry-run               Nur anzeigen, was geschrieben würde (aus)
  --do-log-render=ON|OFF  Nachlaufend log_render_html ausführen (ON)
  --render-delay=<sec>    Verzögerung vor Render-Aufruf (1)
  --debug=LEVEL           OFF | ON | TRACE (OFF)
  --version               Skriptversion
  -h, --help              Hilfe

HINWEIS
  • Gatekeeper: Skript muss im Projekt-WD mit .env laufen.
HLP
}
usage(){ print_help; exit 1; }

# ───────────────────────── Parse Args ─────────────────────────
while (($#)); do
  case "$1" in
    --against) AGAINST="$2"; shift 2;;
    --staged) STAGED=1; shift;;
    --format) FORMAT="$2"; shift 2;;
    --max) MAX="$2"; shift 2;;
    --dry-run) DRY=1; shift;;
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
DBG_TXT="${DEBUG_DIR}/git_diff_report.debug.log"
DBG_JSON="${DEBUG_DIR}/git_diff_report.debug.jsonl"
XTRACE="${DEBUG_DIR}/git_diff_report.xtrace.log"
: > "${DBG_TXT}"
: > "${DBG_JSON}"
if [ "${DEBUG}" = "TRACE" ]; then
  : > "${XTRACE}"
  exec 19>>"${XTRACE}"
  export BASH_XTRACEFD=19
  export PS4='+ git_diff_report.sh:${LINENO}:${FUNCNAME[0]-main} '
  set -x
fi
dbg_line(){ [ "${DEBUG}" != "OFF" ] && printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "${DBG_TXT}"; }
dbg_json(){ [ "${DEBUG}" != "OFF" ] && printf '{"ts":"%s","event":"%s"%s}\n'  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "${2:+,$2}" >> "${DBG_JSON}"; }
dbg_line "START ${SCRIPT_NAME} v${SCRIPT_VERSION} run_id=${RUN_ID} dry_run=${DRY} debug=${DEBUG}"
dbg_json "start" "\"script\":\"${SCRIPT_NAME}\",\"version\":\"${SCRIPT_VERSION}\",\"run_id\":\"${RUN_ID}\",\"cwd\":\"${ORIG_CWD}\",\"dry_run\":\"${DRY}\",\"debug\":\"${DEBUG}\""

cleanup(){ set +e; exec 19>&- 2>/dev/null; }
trap cleanup EXIT

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

# ───────────────────────── Gatekeeper & Reqs ─────────────────────────
if [ ! -f ".env" ]; then
  echo '❌ Gatekeeper: .env fehlt. Skript nur im Projekt-Root ausführen.' >&2
  exit 2
fi
command -v git >/dev/null 2>&1 || { echo '❌ git nicht gefunden.' >&2; exit 3; }

# ───────────────────────── log_core.part (optional) ─────────────────────────
export SCRIPT_NAME SCRIPT_VERSION
export VERSION="${SCRIPT_VERSION}"
export SCRIPT="${SCRIPT_NAME}"

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
    lc_init_ctx "PRIMARY" "$(pwd)" "${RUN_ID}" "${SCRIPT_NAME}" "${SCRIPT_VERSION}" "${ORIG_CWD}" "git-diff"
    if declare -p CTX_NAMES >/dev/null 2>&1; then :; else declare -g -a CTX_NAMES; fi
    CTX_NAMES=("PRIMARY")
    [ "${LC_HAS_SETOPT}" -eq 1 ] && lc_set_opt_cell "${LC_OPT_CELL}" "${LC_OPT_CELL_IS_HTML}"
    set -u
  fi
else
  echo "⚠️ log_core.part nicht geladen → kein Markdown/JSON-Lauf-Log (nur Debugfiles)."
fi

safe_log(){
  if [ "${LC_OK}" -eq 1 ]; then set +u; lc_log_event_all "$@"; set -u; fi
}

# ───────────────────────── Helper ─────────────────────────
run(){ if [ "$DRY" -eq 1 ]; then echo "[DRY] $*"; else eval "$@"; fi; }
mk_tags(){
  local out="git,diff,report"
  [ "$STAGED" -eq 1 ] && out="${out},staged"
  [ "$FORMAT" = "name-only" ] && out="${out},name-only"
  [ "$FORMAT" = "full" ] && out="${out},full"
  [ "$DRY" -eq 1 ] && out="${out},dry-run"
  printf '%s' "$out"
}

# ───────────────────────── Kontext bestimmen ─────────────────────────
branch="$(git rev-parse --abbrev-ref HEAD)"
if [ -z "${AGAINST}" ]; then
  if git rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
    AGAINST='@{u}'
  elif git rev-parse "origin/${branch}" >/dev/null 2>&1; then
    AGAINST="origin/${branch}"
  else
    AGAINST="HEAD~1"
  fi
fi

case "$FORMAT" in
  summary)
    DIFF_CMD1="git diff --stat ${AGAINST} --"
    if [ "$STAGED" -eq 1 ]; then DIFF_CMD2="git diff --cached ${AGAINST}"
    else DIFF_CMD2="git diff ${AGAINST}"; fi
    ;;
  name-only)
    DIFF_CMD1="git diff --name-status ${AGAINST} --"
    if [ "$STAGED" -eq 1 ]; then DIFF_CMD2="git diff --cached --name-only ${AGAINST}"
    else DIFF_CMD2="git diff --name-only ${AGAINST}"; fi
    ;;
  full)
    DIFF_CMD1="git diff --stat ${AGAINST} --"
    if [ "$STAGED" -eq 1 ]; then DIFF_CMD2="git diff --cached ${AGAINST}"
    else DIFF_CMD2="git diff ${AGAINST}"; fi
    ;;
  *) echo '❌ Fehler: Unbekanntes Format.' >&2; exit 4;;
esac

outdir=".wiki/git_diffs"; mkdir -p "$outdir"
ts="$(date +%Y%m%d_%H%M%S)"
outfile="${outdir}/diff_${ts}.md"

# ───────────────────────── BEGIN-Log ─────────────────────────
safe_log INFO "report" "start" "plan" "✅" 0 0 \
  "Branch: \`${branch}\`; Against: \`${AGAINST}\`" \
  "$(mk_tags)" \
  "format=${FORMAT}; staged=$([ ${STAGED} -eq 1 ] && echo yes || echo no); max=${MAX}"

# ───────────────────────── Report erstellen ─────────────────────────
write_rc=0
if [ "$DRY" -eq 0 ]; then
  {
    echo "# Diff-Report"
    echo "- Branch: ${branch}"
    echo "- Gegen:  ${AGAINST}"
    echo "- Staged: $([ $STAGED -eq 1 ] && echo yes || echo no)"
    echo "- Format: ${FORMAT}"
    echo "- Zeit:   $(date '+%Y-%m-%d %H:%M')"
    echo
    echo "## Zusammenfassung"; eval "$DIFF_CMD1"
    echo
    echo "## Änderungen";     eval "$DIFF_CMD2"
  } > "${outfile}" || write_rc=$?
  if [ "${write_rc}" -eq 0 ]; then
    echo "OK: ${outfile}"
    safe_log INFO "report" "write" "\`$(basename -- "${outfile}")\`" "✅" 0 0 \
      "Out: \`${outfile}\`" \
      "$(mk_tags)" \
      "wrote=\`${outfile}\`"
  else
    echo "❌ Schreibfehler: ${outfile}" >&2
    safe_log ERROR "report" "write" "\`$(basename -- "${outfile}")\`" "❌" 0 "${write_rc}" \
      "Out: \`${outfile}\`" \
      "$(mk_tags)" \
      "write failed"
    exit "${write_rc}"
  fi
else
  echo "[DRY] würde schreiben: ${outfile}"
  safe_log INFO "report" "write" "\`$(basename -- "${outfile}")\`" "✅" 0 0 \
    "Out: \`${outfile}\`" \
    "$(mk_tags)" \
    "would-write=\`${outfile}\`"
fi

# ───────────────────────── Housekeeping / Prune ─────────────────────────
pruned=0
prune_list=()
mapfile -t existing < <(ls -t "$outdir"/diff_*.md 2>/dev/null || true)
if ((${#existing[@]} > MAX)); then
  for ((i=MAX; i<${#existing[@]}; i++)); do
    f="${existing[$i]}"
    if [ "$DRY" -eq 1 ]; then
      echo "[DRY] würde löschen: ${f}"
      prune_list+=("$(basename -- "$f") (dry)")
      ((pruned++))
    else
      if rm -f -- "$f"; then
        prune_list+=("$(basename -- "$f")")
        ((pruned++))
      fi
    fi
  done
fi

if (( pruned > 0 )); then
  msg="count=${pruned}"
  if ((${#prune_list[@]})); then
    for ((i=0;i<${#prune_list[@]};i++)); do
      d="${prune_list[$i]}"
      if [ "$i" -eq 0 ]; then msg="${msg}; files=\`${d}\`"
      else msg="${msg}<br />\`${d}\`"; fi
    done
  fi
  safe_log INFO "report" "prune" "\`git_diffs\`" "✅" 0 0 \
    "Max=\`${MAX}\`" \
    "git,diff,report,prune$([ ${DRY} -eq 1 ] && echo ',dry-run')" \
    "${msg}"
else
  safe_log INFO "report" "prune" "\`git_diffs\`" "✅" 0 0 \
    "Max=\`${MAX}\`" \
    "git,diff,report,prune$([ ${DRY} -eq 1 ] && echo ',dry-run')" \
    "count=0"
fi

# ───────────────────────── finalize & optional HTML-Render ─────────────────────────
if command -v lc_finalize >/dev/null 2>&1 && [ "${LC_OK}" -eq 1 ]; then lc_finalize; fi

if [ "${DO_LOG_RENDER}" = "ON" ]; then
  # kleine Verzögerung, damit Log-Dateien abgeschlossen sind
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

exit 0
