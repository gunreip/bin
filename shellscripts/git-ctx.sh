#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# git-ctx — kompakte Repo-Statuszeile (für Kopf der Skriptausgaben)
# Version: v1.2.0
# -----------------------------------------------------------------------------
set -euo pipefail
IFS=$'\n\t'

# >>> LOGFX INIT >>>
: "${LOG_LEVEL:=off}"       # off|dbg|trace|xtrace (für ctx: Default off)
# shellcheck source=/dev/null
. "$HOME/code/bin/shellscripts/lib/logfx.sh"
# <<< LOGFX INIT <<<

SCRIPT_ID="git-ctx"
SCRIPT_VERSION="v1.2.0"

# Optionen
NO_COLOR_FORCE="no"
REFRESH="no"
REMOTE_NAME="origin"
OUT_JSON="no"

usage(){ cat <<HLP
$SCRIPT_ID $SCRIPT_VERSION
Usage:
  git-ctx [--no-color] [--refresh] [--remote=<name>] [--json]
          [--debug=dbg|trace|xtrace] [--help] [--version]

Optionen:
  --no-color        Ausgaben ohne Farben
  --refresh         stilles 'git fetch --prune <remote>' vor Anzeige
  --remote=<name>   Remote-Name (Default: origin)
  --json            Nur eine JSON-Zeile statt formatiertem Text
  --debug=...       logfx: dbg|trace|xtrace (Schreibt JSONL nach ~/code/bin/shellscripts/debugs/git-ctx/)
HLP
}

for arg in "$@"; do
  case "$arg" in
    --help) usage; exit 0 ;;
    --version) echo "$SCRIPT_ID $SCRIPT_VERSION"; exit 0 ;;
    --no-color) NO_COLOR_FORCE="yes" ;;
    --refresh)  REFRESH="yes" ;;
    --remote=*) REMOTE_NAME="${arg#*=}" ;;
    --json)     OUT_JSON="yes" ;;
    --debug=dbg)    LOG_LEVEL="dbg" ;;
    --debug=trace)  LOG_LEVEL="trace" ;;
    --debug=xtrace) LOG_LEVEL="xtrace" ;;
    *) echo "Unbekannte Option: $arg"; echo "Nutze --help"; exit 2 ;;
  esac
done

# Farben
BOLD=""; YEL=""; GRN=""; RED=""; BLU=""; RST=""
color_init() {
  if [ "$NO_COLOR_FORCE" = "yes" ] || [ -n "${NO_COLOR:-}" ] || [ ! -t 1 ]; then
    BOLD=""; YEL=""; GRN=""; RED=""; BLU=""; RST=""
  else
    BOLD=$'\033[1m'; YEL=$'\033[33m'; GRN=$'\033[32m'; RED=$'\033[31m'; BLU=$'\033[34m'; RST=$'\033[0m'
  fi
}
color_init

logfx_init "$SCRIPT_ID" "$LOG_LEVEL"
[ "$LOG_LEVEL" = "xtrace" ] && logfx_xtrace_on || true

S_ctx="$(logfx_scope_begin "detect")"

PWD_P="$(pwd -P)"
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if [ "$OUT_JSON" = "yes" ]; then
    printf '{"repo":null,"mode":null,"origin":null,"branch":null,"upstream":null,"ahead":0,"behind":0,"staged":0,"changed":0,"untracked":0,"pwd":"%s","note":"not-a-git-repo"}\n' "$PWD_P"
  else
    printf "%sCTX%s  %sNicht im Git-Repo%s  |  PWD: %s\n" "$BLU$BOLD" "$RST" "$RED" "$RST" "$PWD_P"
  fi
  logfx_event "no-repo" "pwd" "$PWD_P"
  logfx_scope_end "$S_ctx" "warn"
  exit 2
fi

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD_P")"
MODE="project"; [ "$ROOT" = "$HOME/code/bin" ] && MODE="bin"

# optional: Refresh
if [ "$REFRESH" = "yes" ]; then
  logfx_run "fetch-prune" -- git fetch "$REMOTE_NAME" --prune --quiet || true
fi

# Daten einsammeln
origin="$(git remote get-url "$REMOTE_NAME" 2>/dev/null || echo "-")"
branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "-")"
upstream="$(git rev-parse --abbrev-ref --symbolic-full-name @{u} 2>/dev/null || echo "-")"

# ahead/behind
ahead="0"; behind="0"
if [ "$upstream" != "-" ]; then
  # "behind  ahead"
  set +e
  counts="$(git rev-list --left-right --count "$upstream...HEAD" 2>/dev/null)"
  rc=$?
  set -e
  if [ $rc -eq 0 ] && [ -n "${counts:-}" ]; then
    behind="$(printf "%s\n" "$counts" | awk '{print $1}')"
    ahead="$(printf  "%s\n" "$counts" | awk '{print $2}')"
  fi
fi

# porcelain counters
porc="$(git status --porcelain 2>/dev/null || true)"
staged="$(printf "%s\n" "$porc" | grep -E '^[AMDR]'        | wc -l | tr -d ' ' || true)"
changed="$(printf "%s\n" "$porc" | grep -E '^[ MARC][MD]'  | wc -l | tr -d ' ' || true)"
untracked="$(printf "%s\n" "$porc" | grep -E '^\?\?'       | wc -l | tr -d ' ' || true)"
: "${staged:=0}"; : "${changed:=0}"; : "${untracked:=0}"

logfx_var "repo" "$ROOT" "mode" "$MODE" "remote" "$REMOTE_NAME" "origin_url" "$origin" \
          "branch" "$branch" "upstream" "$upstream" "ahead" "$ahead" "behind" "$behind" \
          "staged" "$staged" "changed" "$changed" "untracked" "$untracked"
logfx_scope_end "$S_ctx" "ok"

# Ausgabe
if [ "$OUT_JSON" = "yes" ]; then
  printf '{"repo":"%s","mode":"%s","origin":"%s","branch":"%s","upstream":"%s","ahead":%s,"behind":%s,"staged":%s,"changed":%s,"untracked":%s}\n' \
    "$ROOT" "$MODE" "$origin" "$branch" "$upstream" "$ahead" "$behind" "$staged" "$changed" "$untracked"
else
  printf "%sCTX%s  Repo: %s  |  Mode: %s  |  Origin: %s  |  Branch: %s  ->  %s  (ahead:%s behind:%s)  |  WT: staged:%s changed:%s untracked:%s\n" \
    "$BLU$BOLD" "$RST" "$ROOT" "$MODE" "$origin" "$branch" "$upstream" "$ahead" "$behind" "$staged" "$changed" "$untracked"
fi

exit 0
