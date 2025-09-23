#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# git-state — kompaktes Repo-Status-Overview (read-only)
# Version: v0.3.1
# -----------------------------------------------------------------------------
set -euo pipefail
IFS=$'\n\t'

: "${LOG_LEVEL:=trace}"      # off|dbg|trace|xtrace
# shellcheck source=/dev/null
. "$HOME/code/bin/shellscripts/lib/logfx.sh"

SCRIPT_ID="git-state"
SCRIPT_VERSION="v0.3.1"

NO_COLOR_FORCE="no"
MODE_OUT="long"         # summary|long|porcelain|json
REMOTE_NAME="origin"
DO_REFRESH="no"

usage(){
  cat <<H
$SCRIPT_ID $SCRIPT_VERSION

Usage:
  git-state [--summary-only | --long | --porcelain | --json]
            [--remote=<name>] [--refresh] [--no-color]
            [--debug=dbg|trace|xtrace] [--help] [--version]
H
}

BOLD=""; YEL=""; GRN=""; RED=""; BLU=""; RST=""
color_init() {
  if [ "$NO_COLOR_FORCE" = "yes" ] || [ -n "${NO_COLOR:-}" ] || [ ! -t 1 ]; then
    BOLD=""; YEL=""; GRN=""; RED=""; BLU=""; RST=""
  else
    BOLD=$'\033[1m'; YEL=$'\033[33m'; GRN=$'\033[32m'; RED=$'\033[31m'; BLU=$'\033[34m'; RST=$'\033[0m'
  fi
}

for arg in "$@"; do
  case "$arg" in
    --help)    usage; exit 0 ;;
    --version) echo "$SCRIPT_ID $SCRIPT_VERSION"; exit 0 ;;
    --no-color) NO_COLOR_FORCE="yes" ;;
    --debug=dbg)    LOG_LEVEL="dbg" ;;
    --debug=trace)  LOG_LEVEL="trace" ;;
    --debug=xtrace) LOG_LEVEL="xtrace" ;;
    --summary-only) MODE_OUT="summary" ;;
    --long)         MODE_OUT="long" ;;
    --porcelain)    MODE_OUT="porcelain" ;;
    --json)         MODE_OUT="json" ;;
    --remote=*)     REMOTE_NAME="${arg#*=}" ;;
    --refresh)      DO_REFRESH="yes" ;;
    --project=*) : ;; # Altlast
    *) echo "Unbekannte Option: $arg"; echo "Nutze --help"; exit 3 ;;
  esac
done

color_init
logfx_init "$SCRIPT_ID" "$LOG_LEVEL"
[ "$LOG_LEVEL" = "xtrace" ] && logfx_xtrace_on || true

# ---------- Gatekeeper / Kontext ----------
S_ctx="$(logfx_scope_begin "context-detect")"
BIN_PATH="$HOME/code/bin"
PWD_P="$(pwd -P)"
MODE="unknown"
REPO_ROOT=""

command -v git >/dev/null 2>&1 || { echo "Fehler: git fehlt"; logfx_event "dependency" "missing" "git"; exit 4; }

if [ "$PWD_P" = "$BIN_PATH" ]; then
  MODE="bin"
  if [ ! -d "$BIN_PATH/.git" ]; then
    msg="${BIN_PATH} - Ist noch kein Git-Repo (git-init fehlt, oder in <project> ausführen)"
    [ -n "$BOLD" ] && printf "%sGatekeeper:%s %s%s%s\n" "$YEL$BOLD" "$RST" "$RED" "$msg" "$RST" || echo "Gatekeeper: $msg"
    logfx_event "gatekeeper" "reason" "bin-no-git" "pwd" "$PWD_P"
    exit 2
  fi
  REPO_ROOT="$BIN_PATH"
else
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    MODE="project"
    REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  else
    [ -n "$BOLD" ] && printf "%sGatekeeper:%s Kein Git-Repo.\n" "$YEL$BOLD" "$RST" || echo "Gatekeeper: Kein Git-Repo."
    logfx_event "gatekeeper" "reason" "no-repo" "pwd" "$PWD_P"
    exit 2
  fi
fi

if [ "$PWD_P" != "$REPO_ROOT" ]; then
  msg="Bitte aus Repo-Wurzel starten: $REPO_ROOT"
  [ -n "$BOLD" ] && printf "%sGatekeeper:%s %s\n" "$YEL$BOLD" "$RST" "$msg" || echo "Gatekeeper: $msg"
  logfx_event "gatekeeper" "reason" "not-root" "repo_root" "$REPO_ROOT" "pwd" "$PWD_P"
  exit 2
fi

PROJ_NAME=""; APP_NAME=""
if [ "$MODE" = "project" ]; then
  ENV_FILE="$REPO_ROOT/.env"
  if [ ! -f "$ENV_FILE" ]; then
    [ -n "$BOLD" ] && printf "%sGatekeeper:%s .env fehlt\n" "$YEL$BOLD" "$RST" || echo "Gatekeeper: .env fehlt"
    logfx_event "gatekeeper" "reason" "env-missing" "repo_root" "$REPO_ROOT"
    exit 2
  fi
  PROJ_NAME="$(grep -E '^[[:space:]]*PROJ_NAME[[:space:]]*=' "$ENV_FILE" | tail -1 | cut -d'=' -f2- | sed 's/^["'\'']//; s/["'\'']$//' | tr -d '\r' || true)"
  [ -z "$PROJ_NAME" ] && PROJ_NAME="$(grep -E '^[[:space:]]*PROJ-NAME[[:space:]]*=' "$ENV_FILE" | tail -1 | cut -d'=' -f2- | sed 's/^["'\'']//; s/["'\'']$//' | tr -d '\r' || true)"
  APP_NAME="$(grep -E '^[[:space:]]*APP_NAME[[:space:]]*=' "$ENV_FILE" | tail -1 | cut -d'=' -f2- | sed 's/^["'\'']//; s/["'\'']$//' | tr -d '\r' || true)"
fi

logfx_var "mode" "$MODE" "repo_root" "$REPO_ROOT"
logfx_scope_end "$S_ctx" "ok"

# Kopfzeile
if command -v git-ctx >/dev/null 2>&1; then git-ctx ${NO_COLOR_FORCE:+--no-color} || true; fi

# ---------- Daten einsammeln ----------
S_collect="$(logfx_scope_begin "collect")"

[ "$DO_REFRESH" = "yes" ] && logfx_run "fetch-prune" -- git fetch "$REMOTE_NAME" --prune --quiet || true

REMOTE_URL="$(git remote get-url "$REMOTE_NAME" 2>/dev/null || echo "-")"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "-")"
UPSTREAM="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || echo "-")"

ahead="0"; behind="0"
if [ "$UPSTREAM" != "-" ]; then
  set +e
  counts="$(git rev-list --left-right --count "$UPSTREAM...HEAD" 2>/dev/null)"
  rc=$?; set -e
  if [ $rc -eq 0 ] && [ -n "${counts:-}" ]; then
    behind="$(printf "%s\n" "$counts" | awk '{print $1}')"
    ahead="$( printf "%s\n" "$counts" | awk '{print $2}')"
  fi
fi

porc="$(git status --porcelain 2>/dev/null || true)"

# --- robuste Zählungen (kein doppeltes "0") ---
staged="$(printf "%s\n" "$porc" | grep -E -c '^[AMDR]' || true)"
unstaged="$(printf "%s\n" "$porc" | grep -E -c '^[ MARC][MD]' || true)"
untracked="$(printf "%s\n" "$porc" | grep -E -c '^\?\?' || true)"
conflicts="$(printf "%s\n" "$porc" | grep -E -c '^(UU|AA|DD|U.|.U)' || true)"

# newline/space weg
staged="$(printf "%s" "$staged" | tr -d '[:space:]')"
unstaged="$(printf "%s" "$unstaged" | tr -d '[:space:]')"
untracked="$(printf "%s" "$untracked" | tr -d '[:space:]')"
conflicts="$(printf "%s" "$conflicts" | tr -d '[:space:]')"

clean="yes"
if [ "$staged" -ne 0 ] || [ "$unstaged" -ne 0 ] || [ "$untracked" -ne 0 ] || [ "$conflicts" -ne 0 ]; then
  clean="no"
fi

tags_total="$(git tag -l 2>/dev/null | wc -l | tr -d '[:space:]' || echo 0)"

logfx_var "remote" "$REMOTE_NAME" "remote_url" "$REMOTE_URL" "branch" "$BRANCH" "upstream" "$UPSTREAM" \
          "ahead" "$ahead" "behind" "$behind" "staged" "$staged" "unstaged" "$unstaged" "untracked" "$untracked" \
          "conflicts" "$conflicts" "clean" "$clean" "tags_total" "$tags_total" \
          "proj_name" "${PROJ_NAME:-}" "app_name" "${APP_NAME:-}"
logfx_scope_end "$S_collect" "ok"

case "$MODE_OUT" in
  json)
    printf '{"mode":"%s","repo_root":"%s","remote":"%s","remote_url":"%s","branch":"%s","upstream":"%s","ahead":%s,"behind":%s,"staged":%s,"unstaged":%s,"untracked":%s,"conflicts":%s,"clean":"%s","tags_total":%s,"proj_name":"%s","app_name":"%s"}\n' \
      "$MODE" "$REPO_ROOT" "$REMOTE_NAME" "$REMOTE_URL" "$BRANCH" "$UPSTREAM" \
      "$ahead" "$behind" "$staged" "$unstaged" "$untracked" "$conflicts" "$clean" "$tags_total" \
      "${PROJ_NAME:-}" "${APP_NAME:-}"
    ;;
  porcelain)
    echo "mode=$MODE"
    echo "repo_root=$REPO_ROOT"
    echo "remote=$REMOTE_NAME"
    echo "remote_url=$REMOTE_URL"
    echo "branch=$BRANCH"
    echo "upstream=$UPSTREAM"
    echo "ahead=$ahead"
    echo "behind=$behind"
    echo "staged=$staged"
    echo "unstaged=$unstaged"
    echo "untracked=$untracked"
    echo "conflicts=$conflicts"
    echo "clean=$clean"
    echo "tags_total=$tags_total"
    echo "proj_name=${PROJ_NAME:-}"
    echo "app_name=${APP_NAME:-}"
    ;;
  summary)
    if [ -n "$BOLD" ]; then
      printf "%sSTATE%s  %sMode%s:%s %s %sBranch%s:%s %s %sUpstream%s:%s %s %sAhead%s:%s %s %sBehind%s:%s %s %sClean%s:%s %s\n" \
        "$BOLD" "$RST" "$BOLD" "$RST" "$BLU" "$MODE" "$RST" \
        "$BOLD" "$RST" "$YEL" "$BRANCH" "$RST" \
        "$BOLD" "$RST" "$YEL" "$UPSTREAM" "$RST" \
        "$BOLD" "$RST" "$GRN" "$ahead" \
        "$BOLD" "$RST" "$RED" "$behind" \
        "$BOLD" "$RST" "$GRN" "$clean"
    else
      echo "STATE  Mode:$MODE  Branch:$BRANCH  Upstream:$UPSTREAM  Ahead:$ahead  Behind:$behind  Clean:$clean"
    fi
    ;;
  long|*)
    if [ -n "$BOLD" ]; then
      printf "%sMode%s: %s%s%s   %sRepo%s: %s%s%s\n" "$BOLD" "$RST" "$BLU" "$MODE" "$RST" "$BOLD" "$RST" "$BLU" "$REPO_ROOT" "$RST"
      [ "$MODE" = "project" ] && printf "%sAPP_NAME%s: %s%s%s   %sPROJ_NAME%s: %s%s%s\n" "$BOLD" "$RST" "$YEL" "${APP_NAME:-}" "$RST" "$BOLD" "$RST" "$YEL" "${PROJ_NAME:-}" "$RST"
      printf "%sBranch%s: %s%s%s   %sUpstream%s: %s%s%s\n" "$BOLD" "$RST" "$YEL" "$BRANCH" "$RST" "$BOLD" "$RST" "$YEL" "$UPSTREAM" "$RST"
      printf "%sRemote%s: %s%s%s   %sURL%s: %s%s%s\n" "$BOLD" "$RST" "$BLU" "$REMOTE_NAME" "$RST" "$BOLD" "$RST" "$BLU" "$REMOTE_URL" "$RST"
      printf "%sAhead%s: %s%s%s   %sBehind%s: %s%s%s   %sClean%s: %s%s%s\n" "$BOLD" "$RST" "$GRN" "$ahead" "$RST" "$BOLD" "$RST" "$RED" "$behind" "$RST" "$BOLD" "$RST" "$GRN" "$clean" "$RST"
      printf "%sStaged%s: %s%d%s   %sUnstaged%s: %s%d%s   %sUntracked%s: %s%d%s   %sConflicts%s: %s%d%s   %sTags%s: %s%s%s\n" \
        "$BOLD" "$RST" "$GRN" "$staged" "$RST" "$BOLD" "$RST" "$YEL" "$unstaged" "$RST" "$BOLD" "$RST" "$YEL" "$untracked" "$RST" "$BOLD" "$RST" "$RED" "$conflicts" "$RST" "$BOLD" "$RST" "$YEL" "$tags_total" "$RST"
    else
      echo "Mode: $MODE   Repo: $REPO_ROOT"
      [ "$MODE" = "project" ] && echo "APP_NAME: ${APP_NAME:-}   PROJ_NAME: ${PROJ_NAME:-}"
      echo "Branch: $BRANCH   Upstream: $UPSTREAM"
      echo "Remote: $REMOTE_NAME   URL: $REMOTE_URL"
      echo "Ahead: $ahead   Behind: $behind   Clean: $clean"
      echo "Staged: $staged   Unstaged: $unstaged   Untracked: $untracked   Conflicts: $conflicts   Tags: $tags_total"
    fi
    ;;
esac

exit 0
