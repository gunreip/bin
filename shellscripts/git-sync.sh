#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# git-sync — fetch → ggf. pull (ff-only|rebase, optional autostash) → ggf. push
# Version: v0.1.5
# -----------------------------------------------------------------------------
set -euo pipefail
IFS=$'\n\t'

SCRIPT_ID="git-sync"
SCRIPT_VERSION="v0.1.5"
DEBUG_DIR="${HOME}/code/bin/shellscripts/debugs/${SCRIPT_ID}"

# Defaults (Testphase)
LOG_LEVEL="trace"       # überschreibbar via --debug=dbg|trace
DRY_RUN="no"
NO_COLOR_FORCE="no"
REMOTE="origin"
BRANCH=""
USE_REBASE="no"
AUTO_STASH="no"
DO_PUSH="no"
WITH_TAGS="no"

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

# Gemeinsames Arg-Parsing
parse_args() {
  for arg in "$@"; do
    case "$arg" in
      --help)    echo "$SCRIPT_ID $SCRIPT_VERSION"; exit 0 ;;
      --version) echo "$SCRIPT_ID $SCRIPT_VERSION"; exit 0 ;;
      --dry-run) DRY_RUN="yes" ;;
      --debug=*) LOG_LEVEL="${arg#*=}" ;;       # dbg|trace
      --no-color) NO_COLOR_FORCE="yes" ;;
      --remote=*) REMOTE="${arg#*=}" ;;
      --branch=*) BRANCH="${arg#*=}" ;;
      --rebase)   USE_REBASE="yes" ;;
      --autostash) AUTO_STASH="yes" ;;
      --push)     DO_PUSH="yes" ;;
      --with-tags) WITH_TAGS="yes" ;;
      --project=*) : ;;                         # No-Op (Altlast)
      *) echo "Unbekannte Option: ${arg}"; echo "Nutze --help"; exit 3 ;;
    esac
  done
}

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
          exit 0   # Dry-run: freundlich ohne roten Punkt
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

  if [ "$GIT_ROOT" = "$bin_path" ]; then
    MODE="bin"; PROJ_NAME="bin"
  else
    MODE="project"
    local ENV_FILE="$GIT_ROOT/.env"
    if [ ! -f "$ENV_FILE" ]; then
      local msg=".env fehlt"
      [ -n "$BOLD" ] && printf "%sGatekeeper:%s %s\n" "$YEL$BOLD" "$RST" "$msg" || echo "Gatekeeper: $msg"
      exit 2
    fi
    PROJ_NAME="$(grep -E '^[[:space:]]*PROJ_NAME[[:space:]]*=' "$ENV_FILE" | tail -1 | cut -d'=' -f2- | tr -d '[:space:]' || true)"
    [ -n "$PROJ_NAME" ] || PROJ_NAME="$(grep -E '^[[:space:]]*PROJ-NAME[[:space:]]*=' "$ENV_FILE" | tail -1 | cut -d'=' -f2- | tr -d '[:space:]' || true)"
    [ -n "$PROJ_NAME" ] || { [ -n "$BOLD" ] && printf "%sGatekeeper:%s PROJ_NAME fehlt/leer\n" "$YEL$BOLD" "$RST" || echo "Gatekeeper: PROJ_NAME fehlt/leer"; exit 2; }
  fi
}

# ----------------------------- main ------------------------------------------
parse_args "$@"
color_init
log_init            # Debug-Datei garantiert angelegt
gatekeeper          # prüft Kontext

# Branch/Remote bestimmen
[ -n "$BRANCH" ] || BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
[ -n "$BRANCH" ] || { echo "Fehler: Branch unbekannt"; exit 5; }

if ! git remote get-url "$REMOTE" >/dev/null 2>&1; then
  if [ "$DRY_RUN" = "yes" ]; then
    echo "WARN: Remote '$REMOTE' fehlt (dry-run: keine Ausführung)."
    exit 0
  else
    echo "Fehler: Remote '$REMOTE' existiert nicht."; exit 5
  fi
fi

# Clean-Check (wenn kein autostash)
if [ "$AUTO_STASH" = "no" ]; then
  if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "Abbruch: uncommitted Änderungen. Nutze --autostash, wenn gewünscht."; exit 3
  fi
fi

# Dry-run Voransage
if [ "$DRY_RUN" = "yes" ]; then
  PULL_MODE="--ff-only"; [ "$USE_REBASE" = "yes" ] && PULL_MODE="--rebase"
  echo "DRY-RUN: würde ausführen → git fetch; ggf. pull (${PULL_MODE}); ggf. push; with-tags=${WITH_TAGS}; autostash=${AUTO_STASH}"
fi

# fetch
FETCH_CMD=(git fetch "$REMOTE" "$BRANCH"); [ "$WITH_TAGS" = "yes" ] && FETCH_CMD+=(--tags)
if [ "$DRY_RUN" = "yes" ]; then
  printf "DRY-RUN: "; printf "%q " "${FETCH_CMD[@]}"; echo
else
  set +e; "${FETCH_CMD[@]}"; rc=$?; set -e
  [ $rc -eq 0 ] || { echo "Fehler: git fetch rc=$rc"; exit 5; }
fi

# ahead/behind
UPSTREAM="$(git rev-parse --abbrev-ref --symbolic-full-name "@{u}" 2>/dev/null || true)"
AHEAD=0; BEHIND=0
if [ -n "$UPSTREAM" ]; then
  LR="$(git rev-list --left-right --count "$UPSTREAM...HEAD" 2>/dev/null || true)"
  if [ -n "$LR" ]; then
    BEHIND="$(echo "$LR" | awk '{print $1}')"
    AHEAD="$(echo "$LR" | awk '{print $2}')"
  fi
fi

# pull (falls behind)
STASH_NAME=""
if [ -n "$UPSTREAM" ] && [ "${BEHIND:-0}" -gt 0 ]; then
  if [ "$AUTO_STASH" = "yes" ]; then
    STASH_NAME="git-sync autostash $(date +%Y%m%d-%H%M%S)"
    if [ "$DRY_RUN" = "yes" ]; then
      echo "DRY-RUN: git stash push -u -m \"$STASH_NAME\""
    else
      git stash push -u -m "$STASH_NAME" >/dev/null || true
    fi
  fi

  PULL_CMD=(git pull "$REMOTE" "$BRANCH"); [ "$USE_REBASE" = "yes" ] && PULL_CMD+=(--rebase) || PULL_CMD+=(--ff-only); [ "$WITH_TAGS" = "yes" ] && PULL_CMD+=(--tags)
  if [ "$DRY_RUN" = "yes" ]; then
    printf "DRY-RUN: "; printf "%q " "${PULL_CMD[@]}"; echo
  else
    set +e; "${PULL_CMD[@]}"; rc=$?; set -e
    if [ $rc -ne 0 ]; then
      echo "Fehler: git pull rc=$rc"
      if [ -n "$STASH_NAME" ] && git stash list | grep -q "$STASH_NAME"; then echo "Hinweis: Änderungen liegen im Stash."; fi
      exit 5
    fi
  fi

  if [ -n "$STASH_NAME" ]; then
    if [ "$DRY_RUN" = "yes" ]; then
      echo "DRY-RUN: git stash list | grep \"$STASH_NAME\" && git stash pop --index"
    else
      if git stash list | grep -q "$STASH_NAME"; then git stash pop --index || true; fi
    fi
  fi
fi

# nach Pull neu rechnen
if [ -n "$UPSTREAM" ]; then
  LR2="$(git rev-list --left-right --count "$UPSTREAM...HEAD" 2>/dev/null || true)"
  if [ -n "$LR2" ]; then
    BEHIND="$(echo "$LR2" | awk '{print $1}')"
    AHEAD="$(echo "$LR2" | awk '{print $2}')"
  fi
fi

# push (optional)
if [ "$DO_PUSH" = "yes" ] && [ "${AHEAD:-0}" -gt 0 ]; then
  if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "Abbruch: Arbeitsverzeichnis nicht clean. Push abgelehnt."; exit 3
  fi
  PUSH_CMD=(git push "$REMOTE" "$BRANCH"); [ "$WITH_TAGS" = "yes" ] && PUSH_CMD+=(--tags)
  if [ "$DRY_RUN" = "yes" ]; then
    printf "DRY-RUN: "; printf "%q " "${PUSH_CMD[@]}"; echo
  else
    set +e; "${PUSH_CMD[@]}"; rc=$?; set -e
    [ $rc -eq 0 ] || { echo "Fehler: git push rc=$rc"; exit 5; }
  fi
fi

# summary
if [ -n "$BOLD" ]; then
  printf "%sSYNC%s  %sBranch%s: %s%s%s  %sAhead%s:%s %s  %sBehind%s:%s %s  %sRemote%s: %s%s%s\n" \
    "$BOLD" "$RST" "$BOLD" "$RST" "$YEL" "$BRANCH" "$RST" \
    "$BOLD" "$RST" "$GRN" "${AHEAD:-0}" \
    "$BOLD" "$RST" "$RED"  "${BEHIND:-0}" \
    "$BOLD" "$RST" "$BLU" "$REMOTE/$BRANCH" "$RST"
else
  echo "SYNC  Branch: $BRANCH  Ahead: ${AHEAD:-0}  Behind: ${BEHIND:-0}  Remote: $REMOTE/$BRANCH"
fi
exit 0
