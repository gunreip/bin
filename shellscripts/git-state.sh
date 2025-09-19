#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# git-state — kompaktes Repo-Status-Overview (read-only)
# Version: v0.1.0
# -----------------------------------------------------------------------------
set -euo pipefail
IFS=$'\n\t'

SCRIPT_ID="git-state"
SCRIPT_VERSION="v0.1.0"
DEBUG_DIR="${HOME}/code/bin/shellscripts/debugs/${SCRIPT_ID}"

# Defaults (Testphase)
LOG_LEVEL="trace"       # überschreibbar via --debug=dbg|trace
DRY_RUN="no"
NO_COLOR_FORCE="no"
MODE_OUT="long"         # summary-only | long | porcelain

# Farben
BOLD=""; YEL=""; GRN=""; RED=""; BLU=""; RST=""
color_init() {
  if [ "$NO_COLOR_FORCE" = "yes" ] || [ -n "${NO_COLOR:-}" ] || [ ! -t 1 ]; then
    BOLD=""; YEL=""; GRN=""; RED=""; BLU=""; RST=""
  else
    BOLD=$'\033[1m'; YEL=$'\033[33m'; GRN=$'\033[32m'; RED=$'\033[31m'; BLU=$'\033[34m'; RST=$'\033[0m'
  fi
}

# Logging
ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
dbg_path() { printf '%s/%s.%s.%s.jsonl\n' "$DEBUG_DIR" "$SCRIPT_ID" "$LOG_LEVEL" "$(date +%Y%m%d-%H%M%S)"; }

LOG_PATH=""
log_init() {
  mkdir -p "$DEBUG_DIR"
  LOG_PATH="$(dbg_path)"
  : > "$LOG_PATH"
  printf '{"ts":"%s","script":"%s","level":"%s","event":"boot","msg":"start"}\n' "$(ts)" "$SCRIPT_ID" "$LOG_LEVEL" >> "$LOG_PATH"
  if [ "$DRY_RUN" = "yes" ]; then
    if [ -n "$BOLD" ]; then printf "%sDEBUG%s %s(dry-run)%s: %s%s%s\n" "$YEL$BOLD" "$RST" "$GRN" "$RST" "$RED" "$LOG_PATH" "$RST"; else echo "DEBUG (dry-run): $LOG_PATH"; fi
  else
    if [ -n "$BOLD" ]; then printf "%sDEBUG%s: %s%s%s\n" "$YEL$BOLD" "$RST" "$RED" "$LOG_PATH" "$RST"; else echo "DEBUG: $LOG_PATH"; fi
  fi
}

# Args
for arg in "$@"; do
  case "$arg" in
    --help)    echo "$SCRIPT_ID $SCRIPT_VERSION"; exit 0 ;;
    --version) echo "$SCRIPT_ID $SCRIPT_VERSION"; exit 0 ;;
    --dry-run) DRY_RUN="yes" ;;
    --debug=*) LOG_LEVEL="${arg#*=}" ;;
    --no-color) NO_COLOR_FORCE="yes" ;;
    --summary-only) MODE_OUT="summary" ;;
    --long) MODE_OUT="long" ;;
    --porcelain) MODE_OUT="porcelain" ;;
    --project=*) : ;;  # No-Op (Altlast)
    *) echo "Unbekannte Option: $arg"; echo "Nutze --help"; exit 3 ;;
  esac
done

color_init; log_init

# Gatekeeper (Projekt .env ODER Bin-Repo ~/code/bin)
gatekeeper() {
  local bin_path="$HOME/code/bin"
  command -v git >/dev/null 2>&1 || { echo "Fehler: git fehlt"; exit 4; }

  local GIT_ROOT
  GIT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"

  if [ -z "$GIT_ROOT" ]; then
    if [ "$(pwd -P)" = "$bin_path" ]; then
      if [ ! -d "$bin_path/.git" ]; then
        local msg="Gatekeeper: ${bin_path} - Ist noch kein Git-Repo (git-init fehlt, oder in <project> ausführen)."
        if [ "$DRY_RUN" = "yes" ]; then
          [ -n "$BOLD" ] && printf "%s%s%s\n" "$YEL$BOLD" "$msg" "$RST" || echo "$msg"
          exit 0
        else
          [ -n "$BOLD" ] && printf "%s%s%s\n" "$YEL$BOLD" "$msg" "$RST" || echo "$msg"
          exit 2
        fi
      fi
      GIT_ROOT="$bin_path"
    else
      local msg="Gatekeeper: Kein Git-Repo."
      [ -n "$BOLD" ] && printf "%s%s%s\n" "$YEL$BOLD" "$msg" "$RST" || echo "$msg"
      exit 2
    fi
  fi

  if [ "$(pwd -P)" != "$GIT_ROOT" ]; then
    local msg="Gatekeeper: Bitte aus Repo-Wurzel starten: $GIT_ROOT"
    [ -n "$BOLD" ] && printf "%s%s%s\n" "$YEL$BOLD" "$msg" "$RST" || echo "$msg"
    exit 2
  fi

  MODE="bin"; PROJ_NAME="bin"; APP_NAME=""
  if [ "$GIT_ROOT" != "$bin_path" ]; then
    MODE="project"
    local ENV_FILE="$GIT_ROOT/.env"
    if [ ! -f "$ENV_FILE" ]; then
      local msg="Gatekeeper: .env fehlt"
      [ -n "$BOLD" ] && printf "%s%s%s\n" "$YEL$BOLD" "$msg" "$RST" || echo "$msg"
      exit 2
    fi
    # PROJ_NAME (Pflicht in Project-Mode)
    PROJ_NAME="$(grep -E '^[[:space:]]*PROJ_NAME[[:space:]]*=' "$ENV_FILE" | tail -1 | cut -d'=' -f2- | tr -d '[:space:]' | tr -d '"' || true)"
    [ -n "$PROJ_NAME" ] || PROJ_NAME="$(grep -E '^[[:space:]]*PROJ-NAME[[:space:]]*=' "$ENV_FILE" | tail -1 | cut -d'=' -f2- | tr -d '[:space:]' | tr -d '"' || true)"
    [ -n "$PROJ_NAME" ] || { [ -n "$BOLD" ] && printf "%sGatekeeper:%s PROJ_NAME fehlt/leer\n" "$YEL$BOLD" "$RST" || echo "Gatekeeper: PROJ_NAME fehlt/leer"; exit 2; }
    # APP_NAME (optional)
    APP_NAME="$(grep -E '^[[:space:]]*APP_NAME[[:space:]]*=' "$ENV_FILE" | tail -1 | cut -d'=' -f2- | sed 's/^["'\'']//; s/["'\'']$//' | tr -d '\r' || true)"
  fi

  REPO_ROOT="$GIT_ROOT"
}

gatekeeper

# Status sammeln
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
UPSTREAM="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"
REMOTE="origin"
REMOTE_URL="$(git remote get-url "$REMOTE" 2>/dev/null || true)"

AHEAD="n/a"; BEHIND="n/a"
if [ -n "$UPSTREAM" ]; then
  LR="$(git rev-list --left-right --count "$UPSTREAM...HEAD" 2>/dev/null || true)"
  if [ -n "$LR" ]; then
    BEHIND="$(echo "$LR" | awk '{print $1}')"
    AHEAD="$(echo "$LR" | awk '{print $2}')"
  fi
fi

# Porcelain auswerten
staged=0; unstaged=0; untracked=0; conflicts=0
while IFS= read -r line; do
  code="${line:0:2}"
  x="${code:0:1}"; y="${code:1:1}"
  if [ "$code" = "??" ]; then
    untracked=$((untracked+1))
  else
    [ "$x" != " " ] && staged=$((staged+1))
    [ "$y" != " " ] && unstaged=$((unstaged+1))
    case "$code" in
      UU|DD|AA|U?|?U) conflicts=$((conflicts+1)) ;;
    esac
  fi
done < <(git status --porcelain 2>/dev/null || true)

CLEAN="yes"
if [ "$staged" -ne 0 ] || [ "$unstaged" -ne 0 ] || [ "$untracked" -ne 0 ] || [ "$conflicts" -ne 0 ]; then
  CLEAN="no"
fi

TAGS_TOTAL="$(git tag -l 2>/dev/null | wc -l | tr -d '[:space:]' || echo 0)"

# Ausgabe
case "$MODE_OUT" in
  porcelain)
    echo "mode=$MODE"
    echo "repo_root=$REPO_ROOT"
    echo "branch=$BRANCH"
    echo "upstream=$UPSTREAM"
    echo "remote=$REMOTE"
    echo "remote_url=$REMOTE_URL"
    echo "ahead=$AHEAD"
    echo "behind=$BEHIND"
    echo "staged=$staged"
    echo "unstaged=$unstaged"
    echo "untracked=$untracked"
    echo "conflicts=$conflicts"
    echo "clean=$CLEAN"
    echo "tags_total=$TAGS_TOTAL"
    echo "proj_name=$PROJ_NAME"
    echo "app_name=$APP_NAME"
    ;;
  summary)
    if [ -n "$BOLD" ]; then
      printf "%sSTATE%s  %sMode%s:%s %s %sBranch%s:%s %s %sUpstream%s:%s %s %sAhead%s:%s %s %sBehind%s:%s %s %sClean%s:%s %s\n" \
        "$BOLD" "$RST" "$BOLD" "$RST" "$BLU" "$MODE" "$RST" \
        "$BOLD" "$RST" "$YEL" "$BRANCH" "$RST" \
        "$BOLD" "$RST" "$UPSTREAM" \
        "$BOLD" "$RST" "$GRN" "$AHEAD" \
        "$BOLD" "$RST" "$RED" "$BEHIND" \
        "$BOLD" "$RST" "$GRN" "$CLEAN"
    else
      echo "STATE  Mode:$MODE  Branch:$BRANCH  Upstream:$UPSTREAM  Ahead:$AHEAD  Behind:$BEHIND  Clean:$CLEAN"
    fi
    ;;
  long|*)
    if [ -n "$BOLD" ]; then
      printf "%sMode%s: %s%s%s   %sRepo%s: %s%s%s\n" "$BOLD" "$RST" "$BLU" "$MODE" "$RST" "$BOLD" "$RST" "$BLU" "$REPO_ROOT" "$RST"
      [ "$MODE" = "project" ] && printf "%sAPP_NAME%s: %s%s%s   %sPROJ_NAME%s: %s%s%s\n" "$BOLD" "$RST" "$YEL" "${APP_NAME:-}" "$RST" "$BOLD" "$RST" "$YEL" "$PROJ_NAME" "$RST"
      printf "%sBranch%s: %s%s%s   %sUpstream%s: %s%s%s\n" "$BOLD" "$RST" "$YEL" "$BRANCH" "$RST" "$BOLD" "$RST" "$YEL" "$UPSTREAM" "$RST"
      printf "%sRemote%s: %s%s%s   %sURL%s: %s%s%s\n" "$BOLD" "$RST" "$BLU" "$REMOTE" "$RST" "$BOLD" "$RST" "$BLU" "$REMOTE_URL" "$RST"
      printf "%sAhead%s: %s%s%s   %sBehind%s: %s%s%s   %sClean%s: %s%s%s\n" "$BOLD" "$RST" "$GRN" "$AHEAD" "$RST" "$BOLD" "$RST" "$RED" "$BEHIND" "$RST" "$BOLD" "$RST" "$GRN" "$CLEAN" "$RST"
      printf "%sStaged%s: %s%d%s   %sUnstaged%s: %s%d%s   %sUntracked%s: %s%d%s   %sConflicts%s: %s%d%s   %sTags%s: %s%s%s\n" \
        "$BOLD" "$RST" "$GRN" "$staged" "$RST" "$BOLD" "$RST" "$YEL" "$unstaged" "$RST" "$BOLD" "$RST" "$YEL" "$untracked" "$RST" "$BOLD" "$RST" "$RED" "$conflicts" "$RST" "$BOLD" "$RST" "$YEL" "$TAGS_TOTAL" "$RST"
    else
      echo "Mode: $MODE   Repo: $REPO_ROOT"
      [ "$MODE" = "project" ] && echo "APP_NAME: ${APP_NAME:-}   PROJ_NAME: $PROJ_NAME"
      echo "Branch: $BRANCH   Upstream: $UPSTREAM"
      echo "Remote: $REMOTE   URL: $REMOTE_URL"
      echo "Ahead: $AHEAD   Behind: $BEHIND   Clean: $CLEAN"
      echo "Staged: $staged   Unstaged: $unstaged   Untracked: $untracked   Conflicts: $conflicts   Tags: $TAGS_TOTAL"
    fi
    ;;
esac

exit 0
