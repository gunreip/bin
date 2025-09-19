#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# git-check — Repository-Konsistenz-Prüfer (read-only)
#   • Mode: bin|project
#   • OK/WARN/FAIL + konkrete Fix-Hinweise
#   • Exit: 0 (ok), 3 (fail/strict), 2 (gatekeeper), 4 (dependency)
# Version: v0.1.0
# -----------------------------------------------------------------------------
set -euo pipefail
IFS=$'\n\t'

SCRIPT_ID="git-check"
SCRIPT_VERSION="v0.1.0"
DEBUG_DIR="${HOME}/code/bin/shellscripts/debugs/${SCRIPT_ID}"

# Defaults
LOG_LEVEL="trace"     # überschreibbar via --debug=dbg|trace
DRY_RUN="no"
NO_COLOR_FORCE="no"
MODE_OUT="long"       # long|summary|porcelain
STRICT="no"           # WARN -> FAIL, wenn yes

# Farben
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

# Logging
ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
dbg_path() { printf '%s/%s.%s.%s.jsonl\n' "$DEBUG_DIR" "$SCRIPT_ID" "$LOG_LEVEL" "$(date +%Y%m%d-%H%M%S)"; }

LOG_PATH=""
log_init() {
  mkdir -p "$DEBUG_DIR"
  LOG_PATH="$(dbg_path)"
  : > "$LOG_PATH"
  printf '{"ts":"%s","script":"%s","level":"%s","event":"boot","msg":"start"}\n' "$(ts)" "$SCRIPT_ID" "$LOG_LEVEL" >> "$LOG_PATH"
  if [ -n "$BOLD" ]; then printf "%sDEBUG%s%s: %s%s%s\n" "$YEL$BOLD" "$RST" "${DRY_RUN:+ (dry-run)}" "$RED" "$LOG_PATH" "$RST"; else echo "DEBUG${DRY_RUN:+ (dry-run)}: $LOG_PATH"; fi
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
    --strict) STRICT="yes" ;;
    --project=*) : ;;  # No-Op (Altlast)
    *) echo "Unbekannte Option: $arg"; echo "Nutze --help"; exit 3 ;;
  esac
done

color_init; log_init

# Kontext-Erkennung (Gatekeeper-LOGIK für git-check: weich im BIN ohne .git)
BIN_PATH="$HOME/code/bin"
PWD_P="$(pwd -P)"
MODE="unknown"
REPO_ROOT=""
HAS_GIT="no"   # .git vorhanden?
IN_GIT="no"    # git rev-parse erfolgreich?

# Repo-Root via git (falls vorhanden)
if GIT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"; then
  if [ -n "$GIT_ROOT" ]; then
    IN_GIT="yes"
    REPO_ROOT="$GIT_ROOT"
  fi
fi

if [ "$PWD_P" = "$BIN_PATH" ]; then
  MODE="bin"
  if [ -d "$BIN_PATH/.git" ]; then HAS_GIT="yes"; IN_GIT="yes"; REPO_ROOT="$BIN_PATH"; fi
elif [ "$IN_GIT" = "yes" ]; then
  MODE="project"
else
  # Weder bin, noch Git-Repo → echter Gatekeeper-Fall
  msg="Gatekeeper: Kein Git-Repo."
  [ -n "$BOLD" ] && printf "%s%s%s\n" "$YEL$BOLD" "$msg" "$RST" || echo "$msg"
  exit 2
fi

# Wenn in Git-Repo, aber nicht in der Wurzel, abbrechen (bleibt Gatekeeper)
if [ "$IN_GIT" = "yes" ] && [ "$PWD_P" != "$REPO_ROOT" ]; then
  msg="Gatekeeper: Bitte aus Repo-Wurzel starten: $REPO_ROOT"
  [ -n "$BOLD" ] && printf "%s%s%s\n" "$YEL$BOLD" "$msg" "$RST" || echo "$msg"
  exit 2
fi

# Project-ENV-Daten (keine harte Gate weiter oben; hier als Checks)
ENV_FILE=""
PROJ_NAME=""   # Anzeige-Name
APP_NAME=""    # technischer Name
if [ "$MODE" = "project" ]; then
  ENV_FILE="$REPO_ROOT/.env"
  if [ -f "$ENV_FILE" ]; then
    PROJ_NAME="$(grep -E '^[[:space:]]*PROJ_NAME[[:space:]]*=' "$ENV_FILE" | tail -1 | cut -d'=' -f2- | sed 's/^["'\'']//; s/["'\'']$//' | tr -d '\r' || true)"
    [ -z "$PROJ_NAME" ] && PROJ_NAME="$(grep -E '^[[:space:]]*PROJ-NAME[[:space:]]*=' "$ENV_FILE" | tail -1 | cut -d'=' -f2- | sed 's/^["'\'']//; s/["'\'']$//' | tr -d '\r' || true)"
    APP_NAME="$(grep -E '^[[:space:]]*APP_NAME[[:space:]]*=' "$ENV_FILE" | tail -1 | cut -d'=' -f2- | sed 's/^["'\'']//; s/["'\'']$//' | tr -d '\r' || true)"
  fi
fi

# --- Checks sammeln -----------------------------------------------------------
fail=0; warn=0

emit() {  # $1=level(ok|warn|fail)  $2=title  $3=msg  [$4=fix]
  case "$1" in
    ok)   tag_ok;   ;;
    warn) tag_warn; ;;
    fail) tag_fail; ;;
  esac
  if [ "$MODE_OUT" = "porcelain" ]; then
    # key aus title ableiten
    key="$(echo "$2" | tr '[:upper:]' '[:lower:]' | tr ' /-' '_' | tr -cd 'a-z0-9_')"
    echo "check.$key=$1"
    [ -n "${3:-}" ] && echo "note.$key=$(echo "$3" | tr -d '\n')"
    [ -n "${4:-}" ] && echo "fix.$key=$(echo "$4" | tr -d '\n')"
  else
    printf " %s%s%s\n" "$BOLD" "$2" "$RST"
    [ -n "${3:-}" ] && printf "   %s\n" "$3"
    [ -n "${4:-}" ] && printf "   → %s\n" "$4"
  fi
  case "$1" in fail) fail=$((fail+1));; warn) warn=$((warn+1));; esac
}

# 0) Kontext-Header (nur long)
if [ "$MODE_OUT" != "porcelain" ] && [ "$MODE_OUT" != "summary" ]; then
  if [ -n "$BOLD" ]; then
    printf "%sMode%s: %s%s%s   %sRepo%s: %s%s%s\n" "$BOLD" "$RST" "$BLU" "$MODE" "$RST" "$BOLD" "$RST" "$BLU" "${REPO_ROOT:-$PWD_P}" "$RST"
    [ "$MODE" = "project" ] && printf "%sAPP_NAME%s: %s%s%s   %sPROJ_NAME%s: %s%s%s\n" "$BOLD" "$RST" "$YEL" "${APP_NAME:-}" "$RST" "$BOLD" "$RST" "$YEL" "${PROJ_NAME:-}" "$RST"
  else
    echo "Mode: $MODE   Repo: ${REPO_ROOT:-$PWD_P}"
    [ "$MODE" = "project" ] && echo "APP_NAME: ${APP_NAME:-}   PROJ_NAME: ${PROJ_NAME:-}"
  fi
fi

# A) Git-Initialisierung / .git
if [ "$MODE" = "bin" ] && [ "$HAS_GIT" = "no" ]; then
  emit fail "Git init (bin)" \
    "Im Bin-Verzeichnis fehlt .git." \
    "Im Bin-Repo: 'cd $HOME/code/bin && git init -b main' ausführen (oder 'git-init' Skript nutzen)."
else
  if [ "$IN_GIT" = "yes" ]; then
    emit ok "Git init" ".git gefunden (Repo-Wurzel: ${REPO_ROOT})."
  fi
fi

# B) .env / PROJ_NAME (nur project)
if [ "$MODE" = "project" ]; then
  if [ ! -f "$REPO_ROOT/.env" ]; then
    emit fail ".env vorhanden" \
      ".env fehlt." \
      "cp .env.example .env && APP_NAME, PROJ_NAME etc. setzen."
  else
    emit ok ".env vorhanden" ".env existiert."
    if [ -z "${PROJ_NAME:-}" ]; then
      emit fail "PROJ_NAME gesetzt" "PROJ_NAME ist leer/fehlt in .env." 'In .env: PROJ_NAME="Sprechender Projektname" setzen.'
    else
      emit ok "PROJ_NAME gesetzt" "PROJ_NAME: ${PROJ_NAME}"
    fi
    if [ -n "${APP_NAME:-}" ]; then
      emit ok "APP_NAME (optional)" "APP_NAME: ${APP_NAME}"
    else
      emit warn "APP_NAME (optional)" "APP_NAME nicht gesetzt." "In .env: APP_NAME=tafel_wesseling (technischer Name) setzen."
    fi
  fi
fi

# C) Branch / Upstream / Remote
if [ "$IN_GIT" = "yes" ]; then
  BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  if [ -z "$BRANCH" ] || [ "$BRANCH" = "HEAD" ]; then
    emit warn "Branch" "Detached HEAD oder unbekannter Branch." "In einen Branch wechseln oder neuen Branch anlegen (z. B. main)."
  else
    emit ok "Branch" "Aktueller Branch: ${BRANCH}"
  fi

  if git remote get-url origin >/dev/null 2>&1; then
    RURL="$(git remote get-url origin 2>/dev/null || true)"
    emit ok "Remote origin" "origin: ${RURL}"
  else
    emit warn "Remote origin" "Kein 'origin' konfiguriert." "git remote add origin <url>"
  fi

  UPSTREAM="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"
  if [ -n "$UPSTREAM" ]; then
    emit ok "Upstream" "Upstream: ${UPSTREAM}"
  else
    emit warn "Upstream" "Kein Upstream gesetzt." "git push -u origin ${BRANCH}  # oder passenden Remote/Branch wählen"
  fi
fi

# D) Working Tree Zustand
if [ "$IN_GIT" = "yes" ]; then
  staged=0; unstaged=0; untracked=0; conflicts=0
  while IFS= read -r line; do
    code="${line:0:2}"
    x="${code:0:1}"; y="${code:1:1}"
    if [ "$code" = "??" ]; then
      untracked=$((untracked+1))
    else
      [ "$x" != " " ] && staged=$((staged+1))
      [ "$y" != " " ] && unstaged=$((unstaged+1))
      case "$code" in UU|DD|AA|U?|?U) conflicts=$((conflicts+1));; esac
    fi
  done < <(git status --porcelain 2>/dev/null || true)

  if [ "$conflicts" -gt 0 ]; then
    emit fail "Merge-Konflikte" "Konfliktdateien: ${conflicts}" "Konflikte lösen → committen."
  fi
  if [ "$staged" -gt 0 ] || [ "$unstaged" -gt 0 ]; then
    emit warn "Uncommitted Changes" "Staged: ${staged}, Unstaged: ${unstaged}" "Änderungen committen oder stashen."
  else
    emit ok "Clean Working Tree" "Keine uncommitted Änderungen."
  fi
  if [ "$untracked" -gt 0 ]; then
    emit warn "Untracked Files" "Untracked: ${untracked}" "Ggf. .gitignore ergänzen oder Dateien adden."
  else
    emit ok "Untracked Files" "Keine."
  fi
fi

# E) .gitignore
if [ "$MODE" = "project" ]; then
  if [ -f "$REPO_ROOT/.gitignore" ]; then
    emit ok ".gitignore" ".gitignore vorhanden (Projekt)."
  else
    emit warn ".gitignore" ".gitignore fehlt (Projekt)." "Laravel-Preset anlegen (später via git-init automatisiert)."
  fi
elif [ "$MODE" = "bin" ]; then
  if [ -f "$BIN_PATH/.gitignore" ]; then
    emit ok ".gitignore" ".gitignore vorhanden (Bin)."
  else
    emit warn ".gitignore" ".gitignore fehlt (Bin)." "Empfehlung: einfache .gitignore für Backups/Debugs hinzufügen."
  fi
fi

# --- Summary / Exit -----------------------------------------------------------
effective_fail=$fail
if [ "$STRICT" = "yes" ] && [ "$warn" -gt 0 ]; then
  effective_fail=$((effective_fail+1))
fi

if [ "$MODE_OUT" = "summary" ]; then
  if [ -n "$BOLD" ]; then
    printf "%sSUMMARY%s  %sOK%s:%s ? %s  %sWARN%s:%s %d  %sFAIL%s:%s %d  %sSTRICT%s:%s %s\n" \
      "$BOLD" "$RST" "$BOLD" "$RST" "$GRN" "n/a" \
      "$BOLD" "$RST" "$YEL" "$warn" \
      "$BOLD" "$RST" "$RED" "$fail" \
      "$BOLD" "$RST" "$YEL" "$STRICT"
  else
    echo "SUMMARY OK:n/a WARN:$warn FAIL:$fail STRICT:$STRICT"
  fi
fi

if [ "$effective_fail" -gt 0 ]; then
  exit 3
fi
exit 0
