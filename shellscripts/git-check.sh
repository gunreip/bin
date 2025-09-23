#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# git-check — Repository-Konsistenz-Prüfer (read-only)
# Version: v0.2.1
# -----------------------------------------------------------------------------
set -euo pipefail
IFS=$'\n\t'

: "${LOG_LEVEL:=trace}"
# shellcheck source=/dev/null
. "$HOME/code/bin/shellscripts/lib/logfx.sh"

SCRIPT_ID="git-check"
SCRIPT_VERSION="v0.2.1"

DRY_RUN="no"
NO_COLOR_FORCE="no"
MODE_OUT="long"   # long|summary|porcelain
STRICT="no"

BOLD=""; YEL=""; GRN=""; RED=""; BLU=""; RST=""
color_init() {
  if [ "$NO_COLOR_FORCE" = "yes" ] || [ -n "${NO_COLOR:-}" ] || [ ! -t 1 ]; then
    BOLD=""; YEL=""; GRN=""; RED=""; BLU=""; RST=""
  else
    BOLD=$'\033[1m'; YEL=$'\033[33m'; GRN=$'\033[32m'; RED=$'\033[31m'; BLU=$'\033[34m'; RST=$'\033[0m'
  fi
}
tag_ok(){ [ -n "$BOLD" ] && printf "%s[OK]%s" "$GRN$BOLD" "$RST" || printf "[OK]"; }
tag_warn(){ [ -n "$BOLD" ] && printf "%s[WARN]%s" "$YEL$BOLD" "$RST" || printf "[WARN]"; }
tag_fail(){ [ -n "$BOLD" ] && printf "%s[FAIL]%s" "$RED$BOLD" "$RST" || printf "[FAIL]"; }

for arg in "$@"; do
  case "$arg" in
    --help)    echo "$SCRIPT_ID $SCRIPT_VERSION"; exit 0 ;;
    --version) echo "$SCRIPT_ID $SCRIPT_VERSION"; exit 0 ;;
    --dry-run) DRY_RUN="yes" ;;
    --debug=dbg)    LOG_LEVEL="dbg" ;;
    --debug=trace)  LOG_LEVEL="trace" ;;
    --debug=xtrace) LOG_LEVEL="xtrace" ;;
    --no-color) NO_COLOR_FORCE="yes" ;;
    --summary-only) MODE_OUT="summary" ;;
    --long) MODE_OUT="long" ;;
    --porcelain) MODE_OUT="porcelain" ;;
    --strict) STRICT="yes" ;;
    *) echo "Unbekannte Option: $arg"; echo "Nutze --help"; exit 3 ;;
  esac
done

color_init
logfx_init "$SCRIPT_ID" "$LOG_LEVEL"
[ "$LOG_LEVEL" = "xtrace" ] && logfx_xtrace_on || true

# ---------- parse-args scope ----------
S_parse="$(logfx_scope_begin "parse-args" "mode_out" "$MODE_OUT" "strict" "$STRICT" "no_color" "$NO_COLOR_FORCE" "dry_run" "$DRY_RUN" "log_level" "$LOG_LEVEL")"
logfx_scope_end "$S_parse" "ok"

# ---------- context-detect scope ----------
S_ctx="$(logfx_scope_begin "context-detect")"
BIN_PATH="$HOME/code/bin"
PWD_P="$(pwd -P)"
MODE="unknown"; REPO_ROOT=""; HAS_GIT="no"; IN_GIT="no"

logfx_run "rev-parse-toplevel" -- git rev-parse --show-toplevel
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  IN_GIT="yes"
  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
fi

if [ "$PWD_P" = "$BIN_PATH" ]; then
  MODE="bin"
  if [ -d "$BIN_PATH/.git" ]; then HAS_GIT="yes"; IN_GIT="yes"; REPO_ROOT="$BIN_PATH"; fi
elif [ "$IN_GIT" = "yes" ]; then
  MODE="project"
fi
logfx_var "pwd" "$PWD_P" "mode" "$MODE" "repo_root" "${REPO_ROOT:-}" "in_git" "$IN_GIT" "has_git" "$HAS_GIT"
logfx_scope_end "$S_ctx" "ok"

# Gatekeeper
if [ "$MODE" = "unknown" ]; then
  echo "Gatekeeper: Kein Git-Repo."
  logfx_event "gatekeeper" "reason" "no-repo" "pwd" "$PWD_P"
  exit 2
fi
if [ "$IN_GIT" = "yes" ] && [ "$PWD_P" != "$REPO_ROOT" ]; then
  echo "Gatekeeper: Bitte aus Repo-Wurzel starten: $REPO_ROOT"
  logfx_event "gatekeeper" "reason" "not-root" "repo_root" "$REPO_ROOT" "pwd" "$PWD_P"
  exit 2
fi

# ---------- env-read scope (project) ----------
ENV_FILE=""; PROJ_NAME=""; APP_NAME=""
if [ "$MODE" = "project" ]; then
  S_env="$(logfx_scope_begin "env-read")"
  ENV_FILE="$REPO_ROOT/.env"
  if [ -f "$ENV_FILE" ]; then
    PROJ_NAME="$(grep -E '^[[:space:]]*PROJ_NAME[[:space:]]*=' "$ENV_FILE" | tail -1 | cut -d'=' -f2- | sed 's/^["'\'']//; s/["'\'']$//' | tr -d '\r' || true)"
    [ -z "$PROJ_NAME" ] && PROJ_NAME="$(grep -E '^[[:space:]]*PROJ-NAME[[:space:]]*=' "$ENV_FILE" | tail -1 | cut -d'=' -f2- | sed 's/^["'\'']//; s/["'\'']$//' | tr -d '\r' || true)"
    APP_NAME="$(grep -E '^[[:space:]]*APP_NAME[[:space:]]*=' "$ENV_FILE" | tail -1 | cut -d'=' -f2- | sed 's/^["'\'']//; s/["'\'']$//' | tr -d '\r' || true)"
  fi
  logfx_var "env_file" "$ENV_FILE" "proj_name" "${PROJ_NAME:-}" "app_name" "${APP_NAME:-}"
  logfx_scope_end "$S_env" "ok"
fi

# ---------- Ausgabe-Header ----------
if [ "$MODE_OUT" != "porcelain" ] && [ "$MODE_OUT" != "summary" ]; then
  if [ -n "$BOLD" ]; then
    printf "%sMode%s: %s%s%s   %sRepo%s: %s%s%s\n" "$BOLD" "$RST" "$BLU" "$MODE" "$RST" "$BOLD" "$RST" "$BLU" "${REPO_ROOT:-$PWD_P}" "$RST"
    [ "$MODE" = "project" ] && printf "%sAPP_NAME%s: %s%s%s   %sPROJ_NAME%s: %s%s%s\n" "$BOLD" "$RST" "$YEL" "${APP_NAME:-}" "$RST" "$BOLD" "$RST" "$YEL" "${PROJ_NAME:-}" "$RST"
  else
    echo "Mode: $MODE   Repo: ${REPO_ROOT:-$PWD_P}"
    [ "$MODE" = "project" ] && echo "APP_NAME: ${APP_NAME:-}   PROJ_NAME: ${PROJ_NAME:-}"
  fi
fi

emit(){ # $1=level $2=title $3=msg [$4=fix]
  local lvl="$1" title="$2" msg="${3:-}" fix="${4:-}"
  logfx_trace "check" "level" "$lvl" "title" "$title" "msg" "$msg" "fix" "$fix"
  case "$lvl" in ok) tag_ok;; warn) tag_warn;; fail) tag_fail;; esac
  if [ "$MODE_OUT" = "porcelain" ]; then
    key="$(echo "$title" | tr '[:upper:]' '[:lower:]' | tr ' /-' '_' | tr -cd 'a-z0-9_')"
    echo "check.$key=$lvl"
    [ -n "$msg" ] && echo "note.$key=$(echo "$msg" | tr -d '\n')"
    [ -n "$fix" ] && echo "fix.$key=$(echo "$fix" | tr -d '\n')"
  else
    printf " %s%s%s\n" "$BOLD" "$title" "$RST"
    [ -n "$msg" ] && printf "   %s\n" "$msg"
    [ -n "$fix" ] && printf "   → %s\n" "$fix"
  fi
  case "$lvl" in fail) FAILS=$((FAILS+1));; warn) WARNS=$((WARNS+1));; esac
}

FAILS=0; WARNS=0

# A) Git init
if [ "$MODE" = "bin" ] && [ ! -d "$HOME/code/bin/.git" ]; then
  emit fail "Git init (bin)" "Im Bin-Verzeichnis fehlt .git." "cd \$HOME/code/bin && git init -b main"
else
  if [ -n "$REPO_ROOT" ]; then emit ok "Git init" ".git gefunden (Repo-Wurzel: ${REPO_ROOT})."; fi
fi

# B) .env (project)
if [ "$MODE" = "project" ]; then
  if [ ! -f "$REPO_ROOT/.env" ]; then
    emit fail ".env vorhanden" ".env fehlt." "cp .env.example .env && Variablen setzen"
  else
    emit ok ".env vorhanden" ".env existiert."
    [ -z "${PROJ_NAME:-}" ] && emit fail "PROJ_NAME gesetzt" "PROJ_NAME leer." 'In .env: PROJ_NAME="Sprechender Name"' || emit ok "PROJ_NAME gesetzt" "PROJ_NAME: ${PROJ_NAME}"
    [ -n "${APP_NAME:-}" ] && emit ok "APP_NAME (optional)" "APP_NAME: ${APP_NAME}" || emit warn "APP_NAME (optional)" "APP_NAME fehlt." "In .env setzen (technischer Name)."
  fi
fi

# C) Branch/Remote/Upstream
if [ -n "$REPO_ROOT" ]; then
  S_git="$(logfx_scope_begin "git-meta")"
  BRANCH=""; logfx_run "branch-name" -- git rev-parse --abbrev-ref HEAD && BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  if [ -z "$BRANCH" ] || [ "$BRANCH" = "HEAD" ]; then emit warn "Branch" "Detached HEAD oder unbekannt." "In Branch wechseln (z. B. main)."
  else emit ok "Branch" "Aktueller Branch: ${BRANCH}"; fi

  if git remote get-url origin >/dev/null 2>&1; then
    RURL="$(git remote get-url origin 2>/dev/null || true)"
    emit ok "Remote origin" "origin: ${RURL}"
  else
    emit warn "Remote origin" "Kein 'origin' konfiguriert." "git remote add origin <url>"
  fi

  UPSTREAM="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"
  [ -n "$UPSTREAM" ] && emit ok "Upstream" "Upstream: ${UPSTREAM}" || emit warn "Upstream" "Kein Upstream gesetzt." "git push -u origin ${BRANCH}"

  logfx_scope_end "$S_git" "ok"
fi

# D) Worktree
if [ -n "$REPO_ROOT" ]; then
  S_wt="$(logfx_scope_begin "worktree")"
  staged=0; unstaged=0; untracked=0; conflicts=0
  # protokolliere die Roh-Ausgabe gekürzt
  logfx_run "status-porcelain" -- bash -lc 'git status --porcelain | head -n 100'
  while IFS= read -r line; do
    code="${line:0:2}"; x="${code:0:1}"; y="${code:1:1}"
    if [ "$code" = "??" ]; then untracked=$((untracked+1))
    else
      [ "$x" != " " ] && staged=$((staged+1))
      [ "$y" != " " ] && unstaged=$((unstaged+1))
      case "$code" in UU|DD|AA|U?|?U) conflicts=$((conflicts+1));; esac
    fi
  done < <(git status --porcelain 2>/dev/null || true)
  logfx_var "wt_staged" "$staged" "wt_unstaged" "$unstaged" "wt_untracked" "$untracked" "wt_conflicts" "$conflicts"

  [ "$conflicts" -gt 0 ] && emit fail "Merge-Konflikte" "Konfliktdateien: ${conflicts}" "Konflikte lösen → committen."
  if [ "$staged" -gt 0 ] || [ "$unstaged" -gt 0 ]; then
    emit warn "Uncommitted Changes" "Staged: ${staged}, Unstaged: ${unstaged}" "Änderungen committen oder stashen."
  else
    emit ok "Clean Working Tree" "Keine uncommitted Änderungen."
  fi
  [ "$untracked" -gt 0 ] && emit warn "Untracked Files" "Untracked: ${untracked}" "Ggf. .gitignore ergänzen." || emit ok "Untracked Files" "Keine."
  logfx_scope_end "$S_wt" "ok"
fi

# E) .gitignore
if [ "$MODE" = "project" ]; then
  [ -f "$REPO_ROOT/.gitignore" ] && emit ok ".gitignore" ".gitignore vorhanden (Projekt)." \
                                   || emit warn ".gitignore" ".gitignore fehlt (Projekt)." "Laravel-Preset anlegen."
else
  [ -f "$HOME/code/bin/.gitignore" ] && emit ok ".gitignore" ".gitignore vorhanden (Bin)." \
                                      || emit warn ".gitignore" ".gitignore fehlt (Bin)." "Preset anlegen."
fi

# Summary
eff=$FAILS; [ "$STRICT" = "yes" ] && [ "$WARNS" -gt 0 ] && eff=$((eff+1))
logfx_event "summary" "warn" "$WARNS" "fail" "$FAILS" "strict" "$STRICT" "effective_fail" "$eff"

if [ "$MODE_OUT" = "summary" ]; then
  if [ -n "$BOLD" ]; then
    printf "%sSUMMARY%s  WARN:%d  FAIL:%d  STRICT:%s\n" "$BOLD" "$RST" "$WARNS" "$FAILS" "$STRICT"
  else
    echo "SUMMARY WARN:$WARNS FAIL:$FAILS STRICT:$STRICT"
  fi
fi

[ "$eff" -gt 0 ] && exit 3 || exit 0
