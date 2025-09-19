#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# git-pull — Pull vom Remote-Branch in den aktuellen Branch (ff-only|rebase)
# Version: v0.1.9
# -----------------------------------------------------------------------------
set -euo pipefail
IFS=$'\n\t'

SCRIPT_ID="git-pull"
SCRIPT_VERSION="v0.1.9"
DEBUG_DIR="${HOME}/code/bin/shellscripts/debugs/${SCRIPT_ID}"

# Defaults (Testphase)
LOG_LEVEL="trace"       # überschreibbar via --debug=dbg|trace
DRY_RUN="no"
NO_COLOR_FORCE="no"
REMOTE="origin"
BRANCH=""
USE_REBASE="no"
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

# Args
for arg in "$@"; do
  case "$arg" in
    --help)    echo "$SCRIPT_ID $SCRIPT_VERSION"; exit 0 ;;
    --version) echo "$SCRIPT_ID $SCRIPT_VERSION"; exit 0 ;;
    --dry-run) DRY_RUN="yes" ;;
    --debug=*) LOG_LEVEL="${arg#*=}" ;;       # dbg|trace
    --no-color) NO_COLOR_FORCE="yes" ;;
    --remote=*)  REMOTE="${arg#*=}" ;;
    --branch=*)  BRANCH="${arg#*=}" ;;
    --rebase)    USE_REBASE="yes" ;;
    --tags)      WITH_TAGS="yes" ;;
    --project=*) : ;;                         # No-Op (Altlast)
    *) echo "Unbekannte Option: $arg"; echo "Nutze --help"; exit 3 ;;
  esac
done

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

  if [ "$GIT_ROOT" = "$bin_path" ]; then
    MODE="bin"; PROJ_NAME="bin"
  else
    MODE="project"
    local ENV_FILE="$GIT_ROOT/.env"
    if [ ! -f "$ENV_FILE" ]; then
      local msg="Gatekeeper: .env fehlt"
      [ -n "$BOLD" ] && printf "%s%s%s\n" "$YEL$BOLD" "$msg" "$RST" || echo "$msg"
      exit 2
    fi
    PROJ_NAME="$(grep -E '^[[:space:]]*PROJ_NAME[[:space:]]*=' "$ENV_FILE" | tail -1 | cut -d'=' -f2- | tr -d '[:space:]' || true)"
    [ -n "$PROJ_NAME" ] || PROJ_NAME="$(grep -E '^[[:space:]]*PROJ-NAME[[:space:]]*=' "$ENV_FILE" | tail -1 | cut -d'=' -f2- | tr -d '[:space:]' || true)"
    [ -n "$PROJ_NAME" ] || { [ -n "$BOLD" ] && printf "%sGatekeeper:%s PROJ_NAME fehlt/leer\n" "$YEL$BOLD" "$RST" || echo "Gatekeeper: PROJ_NAME fehlt/leer"; exit 2; }
  fi
}
color_init; log_init; gatekeeper

# Vorbedingungen
[ -n "$BRANCH" ] || BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
[ -n "$BRANCH" ] || { echo "Fehler: Branch unbekannt"; exit 5; }

if ! git remote get-url "$REMOTE" >/dev/null 2>&1; then
  if [ "$DRY_RUN" = "yes" ]; then
    echo "WARN: Remote '$REMOTE' fehlt (dry-run: keine Ausführung)."
    exit 0
  else
    echo "Fehler: Remote '$REMOTE' existiert nicht"; exit 5
  fi
fi

if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "Abbruch: Arbeitsverzeichnis hat uncommitted Änderungen. Bitte committen/stashen."
  exit 3
fi

UPSTREAM_SET=yes; git rev-parse --abbrev-ref --symbolic-full-name "@{u}" >/dev/null 2>&1 || UPSTREAM_SET=no
if [ "$UPSTREAM_SET" = no ] && ! git ls-remote --heads "$REMOTE" "$BRANCH" | grep -q .; then
  if [ "$DRY_RUN" = "yes" ]; then
    echo "WARN: Kein Upstream und Branch existiert nicht (dry-run)."
    exit 0
  else
    echo "Fehler: kein Upstream und Branch existiert nicht"; exit 5
  fi
fi

# Ausführung
PULL_CMD=(git pull "$REMOTE" "$BRANCH")
[ "$USE_REBASE" = "yes" ] && PULL_CMD+=(--rebase) || PULL_CMD+=(--ff-only)
[ "$WITH_TAGS" = "yes" ] && PULL_CMD+=(--tags)

if [ "$DRY_RUN" = "yes" ]; then
  printf "DRY-RUN: "; printf "%q " "${PULL_CMD[@]}"; echo; exit 0
fi

set +e; "${PULL_CMD[@]}"; rc=$?; set -e
[ $rc -eq 0 ] || { echo "Fehler: git pull rc=$rc"; exit 5; }
echo "OK: Änderungen von '$REMOTE/$BRANCH' geholt."
exit 0
