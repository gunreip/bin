#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# git-sync — fetch → ggf. pull → ggf. push (smart)
#   - ff-only (Default) oder rebase
#   - optional Tags
#   - optional autostash bei schmutzigem WT
#   - Upstream beim ersten Push automatisch setzen (abschaltbar)
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

SCRIPT_ID="git-sync"
SCRIPT_VERSION="v0.2.1"

# Defaults / Optionen
NO_COLOR_FORCE="no"
REMOTE="origin"
BRANCH=""
STRATEGY="ff-only"     # ff-only|rebase
WITH_TAGS="no"
AUTOSTASH="no"
SET_UPSTREAM="auto"    # auto|yes|no

usage(){
  cat <<H
$SCRIPT_ID $SCRIPT_VERSION

Usage:
  git-sync [--remote=origin] [--branch=<name>]
           [--ff-only | --rebase]
           [--with-tags] [--autostash]
           [--set-upstream|-u | --no-set-upstream]
           [--dry-run] [--no-color] [--debug=dbg|trace|xtrace]
           [--help] [--version]

Ablauf:
  1) fetch <remote> <branch>
  2) wenn behind>0 → pull (ff-only|rebase)
  3) wenn ahead>0  → push (Upstream auto bei erstem Push)
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
    --ff-only)   STRATEGY="ff-only" ;;
    --rebase)    STRATEGY="rebase" ;;
    --with-tags) WITH_TAGS="yes" ;;
    --autostash) AUTOSTASH="yes" ;;
    --set-upstream|-u) SET_UPSTREAM="yes" ;;
    --no-set-upstream) SET_UPSTREAM="no" ;;
    --project=*) : ;;  # Altlast
    *) echo "Unbekannte Option: $arg"; echo "Nutze --help"; exit 3 ;;
  esac
done

color_init
logfx_init "$SCRIPT_ID" "$LOG_LEVEL"
[ "$LOG_LEVEL" = "xtrace" ] && logfx_xtrace_on || true

# ---------- parse-args ----------
S_args="$(logfx_scope_begin "parse-args")"
logfx_var "remote" "$REMOTE" "branch_arg" "$BRANCH" "strategy" "$STRATEGY" \
         "with_tags" "$WITH_TAGS" "autostash" "$AUTOSTASH" \
         "set_upstream" "$SET_UPSTREAM" "dry_run" "${DRY_RUN:-}" "no_color" "$NO_COLOR_FORCE"
logfx_scope_end "$S_args" "ok"

# ---------- Gatekeeper / Kontext ----------
S_ctx="$(logfx_scope_begin "context-detect")"
BIN_PATH="$HOME/code/bin"
PWD_P="$(pwd -P)"
MODE="unknown"
REPO_ROOT=""

command -v git >/dev/null 2>&1 || { echo "Fehler: git fehlt"; logfx_event "dependency" "missing" "git"; exit 4; }
if command -v git-ctx >/dev/null 2>&1; then git-ctx ${NO_COLOR_FORCE:+--no-color} || true; fi

# Priorität: /bin → dann allgemeines Git-Repo
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

# Projekt .env nur im project-Modus verlangen
if [ "$MODE" = "project" ]; then
  ENV_FILE="$REPO_ROOT/.env"
  if [ ! -f "$ENV_FILE" ]; then
    [ -n "$BOLD" ] && printf "%sGatekeeper:%s .env fehlt\n" "$YEL$BOLD" "$RST" || echo "Gatekeeper: .env fehlt"
    logfx_event "gatekeeper" "reason" "env-missing" "repo_root" "$REPO_ROOT"
    exit 2
  fi
fi

logfx_var "mode" "$MODE" "repo_root" "$REPO_ROOT"
logfx_scope_end "$S_ctx" "ok"

# ---------- Prechecks ----------
S_pre="$(logfx_scope_begin "prechecks")"

# Branch bestimmen
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
    # Plan ohne fetch/pull/push
    echo "PLAN  fetch:skip  pull:skip  push:skip  (remote fehlt)"
    exit 0
  else
    echo "Fehler: Remote '$REMOTE' existiert nicht"
    logfx_scope_end "$S_pre" "fail"
    exit 5
  fi
fi

# WT sauber?
rc1=0 rc2=0
if [ "$AUTOSTASH" = "no" ]; then
  logfx_run "diff-unstaged" -- git diff --quiet || rc1=$?
  logfx_run "diff-staged" -- git diff --cached --quiet || rc2=$?
  if [ $rc1 -ne 0 ] || [ $rc2 -ne 0 ]; then
    echo "Abbruch: Arbeitsverzeichnis hat uncommitted Änderungen. Nutze --autostash oder commit/stash."
    logfx_event "precheck-fail" "reason" "dirty-wt" "rc_unstaged" "$rc1" "rc_staged" "$rc2"
    logfx_scope_end "$S_pre" "fail"
    exit 3
  fi
fi
logfx_var "autostash" "$AUTOSTASH"
logfx_scope_end "$S_pre" "ok"

# ---------- Fetch ----------
S_fetch="$(logfx_scope_begin "fetch")"
FETCH_ARGS=(git fetch "$REMOTE" "$BRANCH")
[ "$WITH_TAGS" = "yes" ] && FETCH_ARGS+=(--tags)

if [ "${DRY_RUN:-}" = "yes" ]; then
  echo "DRY-RUN: ${FETCH_ARGS[*]}"
  logfx_event "dry-plan" "fetch_cmd" "${FETCH_ARGS[*]}"
else
  logfx_run "git-fetch" -- "${FETCH_ARGS[@]}" || true
fi
logfx_scope_end "$S_fetch" "ok"

# ---------- Analyse ahead/behind ----------
S_an="$(logfx_scope_begin "analyze")"
REMOTE_REF="refs/remotes/$REMOTE/$BRANCH"
ahead="n/a"; behind="n/a"
if git rev-parse --verify --quiet "$REMOTE_REF" >/dev/null 2>&1; then
  # X (behind) Y (ahead)
  set +e
  cts="$(git rev-list --left-right --count "${REMOTE}/${BRANCH}...HEAD" 2>/dev/null)"
  rc=$?
  set -e
  if [ $rc -eq 0 ]; then
    behind="${cts%%	*}"; behind="${behind%% *}"
    ahead="${cts##*	}"; ahead="${ahead##* }"
  fi
fi
logfx_var "ahead" "$ahead" "behind" "$behind" "remote_ref" "$REMOTE/$BRANCH"
logfx_scope_end "$S_an" "ok"

# ---------- Pull (falls nötig) ----------
S_pull="$(logfx_scope_begin "pull")"
DID_STASH="no"; STASH_MSG=""
if [ "$AUTOSTASH" = "yes" ] && [ "${DRY_RUN:-}" != "yes" ]; then
  # nur wenn wirklich dirty:
  set +e; git diff --quiet; rcA=$?; git diff --cached --quiet; rcB=$?; set -e
  if [ $rcA -ne 0 ] || [ $rcB -ne 0 ]; then
    STASH_MSG="git-sync autostash $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    logfx_run "stash-push" -- git stash push --include-untracked --message "$STASH_MSG"
    DID_STASH="yes"
  fi
fi

if [ "$behind" != "n/a" ] && [ "$behind" -gt 0 ]; then
  PULL_CMD=(git pull "$REMOTE" "$BRANCH")
  if [ "$STRATEGY" = "rebase" ]; then PULL_CMD+=(--rebase); else PULL_CMD+=(--ff-only); fi
  if [ "${DRY_RUN:-}" = "yes" ]; then
    echo "DRY-RUN: ${PULL_CMD[*]}"
    logfx_event "dry-plan" "pull_cmd" "${PULL_CMD[*]}"
  else
    if logfx_run "git-pull" -- "${PULL_CMD[@]}"; then
      echo "OK: Pull ($STRATEGY) durchgeführt."
    else
      rc=$?
      echo "Fehler: git pull rc=$rc"
      logfx_scope_end "$S_pull" "fail" "rc" "$rc"
      exit 5
    fi
  fi
else
  echo "INFO: Kein Pull nötig (behind=$behind)."
fi
logfx_scope_end "$S_pull" "ok"

# ---------- Push (falls nötig) ----------
S_push="$(logfx_scope_begin "push")"
# Upstream prüfen
UPSTREAM_REF="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"
UPSTREAM_SET="no"; [ -n "$UPSTREAM_REF" ] && UPSTREAM_SET="yes"
logfx_var "upstream_set" "$UPSTREAM_SET" "upstream_ref" "${UPSTREAM_REF:-}"

if [ "$ahead" != "n/a" ] && [ "$ahead" -gt 0 ]; then
  PUSH_ARGS=(git push)
  [ "$WITH_TAGS" = "yes" ] && PUSH_ARGS+=(--tags)
  if [ "$UPSTREAM_SET" = "no" ]; then
    case "$SET_UPSTREAM" in
      yes)   PUSH_ARGS+=(-u "$REMOTE" "$BRANCH") ;;
      no)    PUSH_ARGS+=("$REMOTE" "$BRANCH") ;;
      auto)  PUSH_ARGS+=(-u "$REMOTE" "$BRANCH") ;;
    esac
  else
    PUSH_ARGS+=("$REMOTE" "$BRANCH")
  fi

  if [ "${DRY_RUN:-}" = "yes" ]; then
    echo "DRY-RUN: ${PUSH_ARGS[*]}"
    logfx_event "dry-plan" "push_cmd" "${PUSH_ARGS[*]}"
  else
    if logfx_run "git-push" -- "${PUSH_ARGS[@]}"; then
      echo "OK: Push durchgeführt."
    else
      rc=$?
      echo "Fehler: git push rc=$rc"
      logfx_scope_end "$S_push" "fail" "rc" "$rc"
      # ggf. Autostash zurückholen bevor wir beenden
      if [ "$DID_STASH" = "yes" ]; then logfx_run "stash-pop" -- git stash pop --index || true; fi
      exit 5
    fi
  fi
else
  echo "INFO: Kein Push nötig (ahead=$ahead)."
fi

# Autostash zurückholen (best effort)
if [ "$DID_STASH" = "yes" ] && [ "${DRY_RUN:-}" != "yes" ]; then
  logfx_run "stash-pop" -- git stash pop --index || true
fi

logfx_scope_end "$S_push" "ok"

# ---------- Summary ----------
echo "SYNC  Branch: $BRANCH  Ahead: $ahead  Behind: $behind  Remote: $REMOTE/$BRANCH"
exit 0
