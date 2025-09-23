#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# git-push — Commits zum Remote hochladen (smart: setzt Upstream automatisch)
# Version: v0.2.1
# -----------------------------------------------------------------------------
set -euo pipefail
IFS=$'\n\t'

# >>> LOGFX INIT (deferred) >>>
: "${LOG_LEVEL:=trace}"      # off|dbg|trace|xtrace
: "${DRY_RUN:=}"             # ""|yes – kann auch per --dry-run gesetzt werden
# shellcheck source=/dev/null
. "$HOME/code/bin/shellscripts/lib/logfx.sh"
# <<< LOGFX INIT <<<

SCRIPT_ID="git-push"
SCRIPT_VERSION="v0.2.1"

# Defaults / Optionen
NO_COLOR_FORCE="no"
REMOTE="origin"
BRANCH=""
WITH_TAGS="no"
FORCE_WITH_LEASE="no"
SET_UPSTREAM="auto"   # auto|yes|no

usage(){
  cat <<H
$SCRIPT_ID $SCRIPT_VERSION

Usage:
  git-push [--remote=origin] [--branch=<name>]
           [--tags] [--force-with-lease]
           [--set-upstream|-u | --no-set-upstream]
           [--dry-run] [--no-color] [--debug=dbg|trace|xtrace]
           [--help] [--version]

Hinweise:
- Standard: aktueller Branch zu 'origin'. Falls kein Upstream gesetzt ist,
  wird automatisch mit '-u' gepusht (abschaltbar via --no-set-upstream).
- --tags pusht zusätzlich Tags.
- --force-with-lease ist sicherer als --force.
H
}

# Farben
BOLD=""; YEL=""; GRN=""; RED=""; BLU=""; RST=""
color_init() {
  if [ "$NO_COLOR_FORCE" = "yes" ] || [ -n "${NO_COLOR:-}" ] || [ ! -t 1 ]; then
    BOLD=""; YEL=""; GRN=""; RED=""; BLU=""; RST=""
  else
    BOLD=$'\033[1m'; YEL=$'\033[33m'; GRN=$'\033[32m'; RED=$'\033[31m'; BLU=$'\033[34m'; RST=$'\033[0m'
  fi
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
    --tags)      WITH_TAGS="yes" ;;
    --force-with-lease) FORCE_WITH_LEASE="yes" ;;
    --set-upstream| -u) SET_UPSTREAM="yes" ;;
    --no-set-upstream)  SET_UPSTREAM="no" ;;
    --project=*) : ;;  # Altlast, ignoriert
    *) echo "Unbekannte Option: $arg"; echo "Nutze --help"; exit 3 ;;
  esac
done

color_init
logfx_init "$SCRIPT_ID" "$LOG_LEVEL"
[ "$LOG_LEVEL" = "xtrace" ] && logfx_xtrace_on || true

# ---------- parse-args ----------
S_args="$(logfx_scope_begin "parse-args")"
logfx_var "remote" "$REMOTE" "branch_arg" "$BRANCH" "with_tags" "$WITH_TAGS" "force_with_lease" "$FORCE_WITH_LEASE" "set_upstream" "$SET_UPSTREAM" "no_color" "$NO_COLOR_FORCE" "dry_run" "${DRY_RUN:-}"
logfx_scope_end "$S_args" "ok"

# ---------- Gatekeeper / Kontext ----------
S_ctx="$(logfx_scope_begin "context-detect")"
BIN_PATH="$HOME/code/bin"
PWD_P="$(pwd -P)"
MODE="unknown"
REPO_ROOT=""

command -v git >/dev/null 2>&1 || { echo "Fehler: git fehlt"; logfx_event "dependency" "missing" "git"; exit 4; }
if command -v git-ctx >/dev/null 2>&1; then git-ctx ${NO_COLOR_FORCE:+--no-color} || true; fi

# Reihenfolge: zuerst /bin, dann Git-Repo allgemein
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

# Aus Repo-Wurzel ausführen
if [ "$PWD_P" != "$REPO_ROOT" ]; then
  msg="Bitte aus Repo-Wurzel starten: $REPO_ROOT"
  [ -n "$BOLD" ] && printf "%sGatekeeper:%s %s\n" "$YEL$BOLD" "$RST" "$msg" || echo "Gatekeeper: $msg"
  logfx_event "gatekeeper" "reason" "not-root" "repo_root" "$REPO_ROOT" "pwd" "$PWD_P"
  exit 2
fi
logfx_var "mode" "$MODE" "repo_root" "$REPO_ROOT"
logfx_scope_end "$S_ctx" "ok"

# Projekt .env nur im project-Modus verlangen
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

# Branch ermitteln (falls nicht angegeben)
if [ -z "$BRANCH" ]; then
  logfx_run "branch-name" -- git rev-parse --abbrev-ref HEAD
  BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
fi
[ -n "$BRANCH" ] && [ "$BRANCH" != "HEAD" ] || { echo "Fehler: Branch unbekannt/detached HEAD"; logfx_event "precheck-fail" "reason" "no-branch"; logfx_scope_end "$S_pre" "fail"; exit 5; }
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

# Upstream ermitteln
UPSTREAM_REF="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"
if [ -z "$UPSTREAM_REF" ]; then
  UPSTREAM_SET="no"
else
  UPSTREAM_SET="yes"
fi
logfx_var "upstream_set" "$UPSTREAM_SET" "upstream_ref" "${UPSTREAM_REF:-}"

# ---------- Ausführung ----------
S_run="$(logfx_scope_begin "push")"

PUSH_ARGS=(git push)
[ "$FORCE_WITH_LEASE" = "yes" ] && PUSH_ARGS+=(--force-with-lease)
[ "$WITH_TAGS" = "yes" ] && PUSH_ARGS+=(--tags)

if [ "$UPSTREAM_SET" = "no" ]; then
  case "$SET_UPSTREAM" in
    yes)   PUSH_ARGS+=(-u "$REMOTE" "$BRANCH") ;;
    no)    PUSH_ARGS+=("$REMOTE" "$BRANCH") ;;
    auto)  PUSH_ARGS+=(-u "$REMOTE" "$BRANCH") ;; # Default: Upstream beim ersten Push setzen
  esac
else
  # Upstream existiert → explizit remote/branch ist ok, aber nicht nötig
  PUSH_ARGS+=("$REMOTE" "$BRANCH")
fi

logfx_var "with_tags" "$WITH_TAGS" "force_with_lease" "$FORCE_WITH_LEASE" "set_upstream_effective" "$SET_UPSTREAM"

if [ "${DRY_RUN:-}" = "yes" ]; then
  echo "PLAN  remote:${REMOTE}  branch:${BRANCH}  upstream_set:${UPSTREAM_SET}  set_upstream:${SET_UPSTREAM}  tags:${WITH_TAGS}  lease:${FORCE_WITH_LEASE}"
  printf "DRY-RUN: "; printf "%q " "${PUSH_ARGS[@]}"; echo
  logfx_event "dry-plan" "cmd" "${PUSH_ARGS[*]}"
  logfx_scope_end "$S_run" "ok"
  exit 0
fi

if logfx_run "git-push" -- "${PUSH_ARGS[@]}"; then
  echo "OK: Push nach '$REMOTE/$BRANCH' erfolgreich."
  logfx_scope_end "$S_run" "ok"
  exit 0
else
  rc=$?
  echo "Fehler: git push rc=$rc"
  logfx_scope_end "$S_run" "fail" "rc" "$rc"
  exit 5
fi
