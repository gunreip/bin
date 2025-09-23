#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# git-pull — Änderungen vom Remote in den aktuellen Branch holen (ff-only|rebase)
# Version: v0.2.1
# -----------------------------------------------------------------------------
set -euo pipefail
IFS=$'\n\t'

# >>> LOGFX INIT (deferred) >>>
: "${LOG_LEVEL:=trace}"      # off|dbg|trace|xtrace
: "${DRY_RUN:=}"             # ""|yes  – kann auch per --dry-run gesetzt werden
# shellcheck source=/dev/null
. "$HOME/code/bin/shellscripts/lib/logfx.sh"
# <<< LOGFX INIT <<<

SCRIPT_ID="git-pull"
SCRIPT_VERSION="v0.2.1"

# Defaults
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

usage(){
  cat <<H
$SCRIPT_ID $SCRIPT_VERSION

Usage:
  git-pull [--remote=origin] [--branch=<name>] [--rebase|--ff-only] [--tags]
           [--dry-run] [--no-color] [--debug=dbg|trace|xtrace]
           [--help] [--version]

Hinweise:
- Standard ist --ff-only; mit --rebase wird rebaset.
- Abbruch bei uncommitted Changes; bitte commit/stash.
H
}

# Args
for arg in "$@"; do
  case "$arg" in
    --help)    usage; exit 0 ;;
    --version) echo "$SCRIPT_ID $SCRIPT_VERSION"; exit 0 ;;
    --dry-run) DRY_RUN="yes" ;;
    --debug=dbg)    LOG_LEVEL="dbg" ;;
    --debug=trace)  LOG_LEVEL="trace" ;;
    --debug=xtrace) LOG_LEVEL="xtrace" ;;
    --no-color) NO_COLOR_FORCE="yes" ;;
    --remote=*)  REMOTE="${arg#*=}" ;;
    --branch=*)  BRANCH="${arg#*=}" ;;
    --rebase)    USE_REBASE="yes" ;;
    --ff-only)   USE_REBASE="no" ;;
    --tags)      WITH_TAGS="yes" ;;
    --project=*) : ;;  # Altlast, ignoriert
    *) echo "Unbekannte Option: $arg"; echo "Nutze --help"; exit 3 ;;
  esac
done

color_init
logfx_init "$SCRIPT_ID" "$LOG_LEVEL"
[ "$LOG_LEVEL" = "xtrace" ] && logfx_xtrace_on || true

# ---------- parse-args ----------
S_args="$(logfx_scope_begin "parse-args")"
logfx_var "remote" "$REMOTE" "branch_arg" "$BRANCH" "rebase" "$USE_REBASE" "with_tags" "$WITH_TAGS" "no_color" "$NO_COLOR_FORCE" "dry_run" "${DRY_RUN:-}"
logfx_scope_end "$S_args" "ok"

# ---------- Gatekeeper / Kontext ----------
S_ctx="$(logfx_scope_begin "context-detect")"
BIN_PATH="$HOME/code/bin"
PWD_P="$(pwd -P)"
MODE="unknown"
REPO_ROOT=""

command -v git >/dev/null 2>&1 || { echo "Fehler: git fehlt"; logfx_event "dependency" "missing" "git"; exit 4; }
if command -v git-ctx >/dev/null 2>&1; then git-ctx ${NO_COLOR_FORCE:+--no-color} || true; fi

# Reihenfolge FIX: zuerst /bin prüfen, dann allgemeines Git-Repo
if [ "$PWD_P" = "$BIN_PATH" ]; then
  MODE="bin"
  if [ ! -d "$BIN_PATH/.git" ]; then
    msg="${BIN_PATH} – Ist noch kein Git-Repo (git-init fehlt, oder in <project> ausführen)"
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

# Aus Repo-Wurzel ausführen
if [ "$PWD_P" != "$REPO_ROOT" ]; then
  msg="Bitte aus Repo-Wurzel starten: $REPO_ROOT"
  [ -n "$BOLD" ] && printf "%sGatekeeper:%s %s\n" "$YEL$BOLD" "$RST" "$msg" || echo "Gatekeeper: $msg"
  logfx_event "gatekeeper" "reason" "not-root" "repo_root" "$REPO_ROOT" "pwd" "$PWD_P"
  exit 2
fi

logfx_var "mode" "$MODE" "repo_root" "$REPO_ROOT"
logfx_scope_end "$S_ctx" "ok"

# ---------- Projekt .env prüfen (nur project) ----------
if [ "$MODE" = "project" ]; then
  ENV_FILE="$REPO_ROOT/.env"
  if [ ! -f "$ENV_FILE" ]; then
    [ -n "$BOLD" ] && printf "%sGatekeeper:%s .env fehlt\n" "$YEL$BOLD" "$RST" || echo "Gatekeeper: .env fehlt"
    logfx_event "gatekeeper" "reason" "env-missing" "repo_root" "$REPO_ROOT"
    exit 2
  fi
fi

# ---------- Vorbedingungen ----------
S_pre="$(logfx_scope_begin "prechecks")"

# Branch bestimmen
if [ -z "$BRANCH" ]; then
  logfx_run "branch-name" -- git rev-parse --abbrev-ref HEAD
  BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
fi
[ -n "$BRANCH" ] || { echo "Fehler: Branch unbekannt"; logfx_event "precheck-fail" "reason" "no-branch"; logfx_scope_end "$S_pre" "fail"; exit 5; }
logfx_var "branch" "$BRANCH"

# Remote prüfen
if ! git remote get-url "$REMOTE" >/dev/null 2>&1; then
  if [ "${DRY_RUN:-}" = "yes" ]; then
    echo "WARN: Remote '$REMOTE' fehlt (dry-run)."
    logfx_event "precheck-warn" "remote" "$REMOTE" "reason" "missing"
    logfx_scope_end "$S_pre" "warn"
    exit 0
  else
    echo "Fehler: Remote '$REMOTE' existiert nicht"
    logfx_scope_end "$S_pre" "fail"
    exit 5
  fi
fi
RURL="$(git remote get-url "$REMOTE" 2>/dev/null || true)"
logfx_var "remote_url" "$RURL"

# Clean Working Tree?
logfx_run "diff-unstaged" -- git diff --quiet
rc1=$?
logfx_run "diff-staged" -- git diff --cached --quiet
rc2=$?
if [ $rc1 -ne 0 ] || [ $rc2 -ne 0 ]; then
  echo "Abbruch: Arbeitsverzeichnis hat uncommitted Änderungen. Bitte committen/stashen."
  logfx_event "precheck-fail" "reason" "dirty-wt" "rc_unstaged" "$rc1" "rc_staged" "$rc2"
  logfx_scope_end "$S_pre" "fail"
  exit 3
fi

# Upstream vorhanden oder Branch existiert remote?
UPSTREAM_SET=yes; git rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1 || UPSTREAM_SET=no
if [ "$UPSTREAM_SET" = no ] && ! git ls-remote --heads "$REMOTE" "$BRANCH" | grep -q .; then
  if [ "${DRY_RUN:-}" = "yes" ]; then
    echo "WARN: Kein Upstream und Branch existiert nicht (dry-run)."
    logfx_event "precheck-warn" "reason" "no-upstream-no-remote-branch"
    logfx_scope_end "$S_pre" "warn"
    exit 0
  else
    echo "Fehler: kein Upstream und Branch existiert nicht"
    logfx_scope_end "$S_pre" "fail"
    exit 5
  fi
fi
logfx_var "upstream_set" "$UPSTREAM_SET"
logfx_scope_end "$S_pre" "ok"

# ---------- Ausführung ----------
S_run="$(logfx_scope_begin "pull")"
PULL_CMD=(git pull "$REMOTE" "$BRANCH")
if [ "$USE_REBASE" = "yes" ]; then
  PULL_CMD+=(--rebase)
  STRATEGY="rebase"
else
  PULL_CMD+=(--ff-only)
  STRATEGY="ff-only"
fi
[ "$WITH_TAGS" = "yes" ] && PULL_CMD+=(--tags)

logfx_var "strategy" "$STRATEGY" "with_tags" "$WITH_TAGS"
if [ "${DRY_RUN:-}" = "yes" ]; then
  echo "PLAN  remote:${REMOTE}  branch:${BRANCH}  strategy:${STRATEGY}  tags:${WITH_TAGS}"
  printf "DRY-RUN: "; printf "%q " "${PULL_CMD[@]}"; echo
  logfx_event "dry-plan" "cmd" "${PULL_CMD[*]}"
  logfx_scope_end "$S_run" "ok"
  exit 0
fi

# echter Lauf
if logfx_run "git-pull" -- "${PULL_CMD[@]}"; then
  echo "OK: Änderungen von '$REMOTE/$BRANCH' geholt."
  logfx_scope_end "$S_run" "ok"
  exit 0
else
  rc=$?
  echo "Fehler: git pull rc=$rc"
  logfx_scope_end "$S_run" "fail" "rc" "$rc"
  exit 5
fi
