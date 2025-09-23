#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# git-init — universelles Initialisieren/Verdrahten von Repositories (bin|project)
# Version: v0.3.0
# -----------------------------------------------------------------------------
set -euo pipefail
IFS=$'\n\t'

# >>> LOGFX INIT (deferred) >>>
: "${LOG_LEVEL:=trace}"      # off|dbg|trace|xtrace
: "${DRY_RUN:=}"             # ""|yes
# shellcheck source=/dev/null
. "$HOME/code/bin/shellscripts/lib/logfx.sh"
# <<< LOGFX INIT <<<

SCRIPT_ID="git-init"
SCRIPT_VERSION="v0.3.0"

# Flags/Optionen
NO_COLOR_FORCE="no"
ASSUME_YES="no"
NO_INPUT="no"

REMOTE_URL=""
BRANCH="main"
TEMPLATE="auto"     # auto|bin|laravel|none
DO_MIRROR_LOCAL="no"  # Achtung: evtl. force push
DO_REBASE="no"        # reserved
DO_MERGE="no"         # reserved

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
  git-init [--remote=<url>] [--branch=main]
           [--template=auto|bin|laravel|none]
           [--mirror-local] [--dry-run] [--yes|-y] [--no-input]
           [--no-color] [--debug=dbg|trace|xtrace]
           [--help] [--version]

Beschreibung:
- Initialisiert/verdrahtet ein Repo im Bin- oder Projekt-Modus.
- Zeigt immer zuerst einen PLAN; destruktives ist NIE Default.
- Im Projektmodus wird .env **gelesen** (APP_NAME/PROJ_NAME), aber nicht erzwungen.

Beispiele:
  git-init --branch=main
  git-init --remote=https://github.com/gunreip/bin --yes
  git-init --template=laravel --yes
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
    --yes|-y) ASSUME_YES="yes" ;;
    --no-input) NO_INPUT="yes" ;;
    --remote=*) REMOTE_URL="${arg#*=}" ;;
    --branch=*) BRANCH="${arg#*=}" ;;
    --template=*) TEMPLATE="${arg#*=}" ;;
    --mirror-local) DO_MIRROR_LOCAL="yes" ;;
    --rebase) DO_REBASE="yes" ;;   # reserved
    --merge)  DO_MERGE="yes"  ;;   # reserved
    --project=*) : ;;              # Altlast, ignoriert
    *) echo "Unbekannte Option: $arg"; echo "Nutze --help"; exit 3 ;;
  esac
done

# Utils
ask_yn(){ local q="$1"
  if [ "$ASSUME_YES" = "yes" ]; then echo "y"; return 0; fi
  if [ "$NO_INPUT" = "yes" ]; then echo "n"; return 0; fi
  printf "%s [y/N]: " "$q" >&2; read -r ans || true
  case "${ans,,}" in y|yes) echo "y";; *) echo "n";; esac; }

# Kontext/Gatekeeper
color_init
logfx_init "$SCRIPT_ID" "$LOG_LEVEL"
[ "$LOG_LEVEL" = "xtrace" ] && logfx_xtrace_on || true

S_ctx="$(logfx_scope_begin "context-detect")"
BIN_PATH="$HOME/code/bin"
PWD_P="$(pwd -P)"
MODE="unknown"
REPO_ROOT="$PWD_P"
ENV_FILE=""
PROJ_NAME=""
APP_NAME=""

if [ "$PWD_P" = "$BIN_PATH" ]; then
  MODE="bin"
else
  if [ -f "$PWD_P/.env" ]; then
    MODE="project"
    ENV_FILE="$PWD_P/.env"
    # Aus .env lesen (optional)
    PROJ_NAME="$(grep -E '^[[:space:]]*PROJ_NAME[[:space:]]*=' "$ENV_FILE" | tail -1 | cut -d'=' -f2- | sed 's/^["'\'']//; s/["'\'']$//' | tr -d '\r' || true)"
    [ -z "$PROJ_NAME" ] && PROJ_NAME="$(grep -E '^[[:space:]]*PROJ-NAME[[:space:]]*=' "$ENV_FILE" | tail -1 | cut -d'=' -f2- | sed 's/^["'\'']//; s/["'\'']$//' | tr -d '\r' || true)"
    APP_NAME="$(grep -E '^[[:space:]]*APP_NAME[[:space:]]*=' "$ENV_FILE" | tail -1 | cut -d'=' -f2- | sed 's/^["'\'']//; s/["'\'']$//' | tr -d '\r' || true)"
  else
    # kein bin, keine .env → hier nicht ausführen (deine Policy)
    msg="Gatekeeper: Weder ~/code/bin noch Projekt (.env) — hier nicht ausführen."
    [ -n "$BOLD" ] && printf "%s%s%s\n" "$YEL$BOLD" "$msg" "$RST" || echo "$msg"
    logfx_scope_end "$S_ctx" "fail"
    exit 2
  fi
fi

# Git-Status
HAS_GIT="no"; HAS_COMMITS="no"; ROOT="$PWD_P"
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD_P")"
  if [ "$ROOT" != "$PWD_P" ]; then
    msg="Gatekeeper: Bitte in der Repo-Wurzel arbeiten: $ROOT"
    [ -n "$BOLD" ] && printf "%s%s%s\n" "$YEL$BOLD" "$msg" "$RST" || echo "$msg"
    logfx_scope_end "$S_ctx" "fail"
    exit 2
  fi
  HAS_GIT="yes"
  git rev-parse HEAD >/dev/null 2>&1 && HAS_COMMITS="yes" || true
fi

# Optional Kontextzeile
if command -v git-ctx >/dev/null 2>&1; then git-ctx ${NO_COLOR_FORCE:+--no-color} || true; fi

# Remote prüfen
ORIGIN_SET="no"; ORIGIN_URL=""
if git remote get-url origin >/dev/null 2>&1; then
  ORIGIN_SET="yes"; ORIGIN_URL="$(git remote get-url origin 2>/dev/null || true)"
fi

remote_empty="unknown"
detect_remote_empty(){
  local url="$1"
  if [ -z "$url" ]; then echo "unknown"; return 0; fi
  if git ls-remote --heads --tags "$url" | grep -q .; then echo "no"; else echo "yes"; fi
}
if [ -n "$REMOTE_URL" ]; then
  remote_empty="$(detect_remote_empty "$REMOTE_URL")"
elif [ "$ORIGIN_SET" = "yes" ]; then
  remote_empty="$(detect_remote_empty "$ORIGIN_URL")"
fi

logfx_var "mode" "$MODE" "repo_root" "$ROOT" "has_git" "$HAS_GIT" "has_commits" "$HAS_COMMITS" \
          "remote_arg" "$REMOTE_URL" "origin_set" "$ORIGIN_SET" "origin_url" "$ORIGIN_URL" "remote_empty" "$remote_empty"
logfx_scope_end "$S_ctx" "ok"

# Templates (.gitignore)
TEMPLATE_DIR="$HOME/code/bin/templates/gitignore"
decide_template(){
  local t="$1"
  if [ "$t" = "auto" ]; then
    [ "$MODE" = "bin" ] && echo "bin" || echo "laravel"
  else
    echo "$t"
  fi
}
load_template(){
  local kind="$1" f=""
  case "$kind" in
    bin)     f="$TEMPLATE_DIR/bin.gitignore" ;;
    laravel) f="$TEMPLATE_DIR/laravel.gitignore" ;;
    none)    return 1 ;;
    *)       return 1 ;;
  esac
  if [ -f "$f" ]; then cat "$f"; return 0; fi
  # Fallback-Inhalte
  case "$kind" in
    bin)
      cat <<'G'
# bin repo ignore
shellscripts/debugs/
shellscripts/backups/
shellscripts/audits/
*.bak
*.jsonl
.DS_Store
G
      ;;
    laravel)
      cat <<'G'
/vendor/
/node_modules/
/public/storage
/storage/*.key
.env
.env.*
/storage/logs/*.log
/storage/framework/cache/data
/storage/framework/sessions
/storage/framework/views
/.phpunit.result.cache
Homestead.json
Homestead.yaml
npm-debug.log
yarn-error.log
G
      ;;
  esac
}
GITIGNORE_PLAN="skip"
GITIGNORE_TEMP="$(mktemp -t gitignore.tpl.XXXXXX)"; trap 'rm -f "$GITIGNORE_TEMP"' EXIT
if [ ! -f "$ROOT/.gitignore" ]; then
  TSEL="$(decide_template "$TEMPLATE")"
  if [ "$TSEL" != "none" ]; then
    load_template "$TSEL" > "$GITIGNORE_TEMP"
    GITIGNORE_PLAN="create:$TSEL"
  fi
else
  GITIGNORE_PLAN="exists"
fi

# -------- PLAN --------
if [ -n "$BOLD" ]; then
  printf "%sPLAN%s  Mode:%s %s %s Branch:%s %s %s\n" "$BOLD" "$RST" "$BLU" "$MODE" "$RST" "$YEL" "$BRANCH" "$RST"
  if [ "$MODE" = "project" ]; then
    printf "      APP_NAME:%s %s%s   PROJ_NAME:%s %s%s\n" "$RST" "$YEL" "${APP_NAME:-}" "$RST" "$YEL" "${PROJ_NAME:-}" "$RST"
  fi
else
  echo "PLAN  Mode: $MODE  Branch: $BRANCH"
  [ "$MODE" = "project" ] && echo "      APP_NAME: ${APP_NAME:-}   PROJ_NAME: ${PROJ_NAME:-}"
fi

if [ "$HAS_GIT" = "no" ]; then
  echo " - lokal: kein .git → git init -b $BRANCH"
else
  echo " - lokal: bereits Git-Repo (Commits: $([ "$HAS_COMMITS" = "yes" ] && echo yes || echo no))"
fi

if [ -n "$REMOTE_URL" ]; then
  echo " - remote (arg): $REMOTE_URL (leer: $remote_empty)"
elif [ "$ORIGIN_SET" = "yes" ]; then
  echo " - remote (origin): $ORIGIN_URL (leer: $remote_empty)"
else
  echo " - remote: (kein origin gesetzt)"
fi

case "$GITIGNORE_PLAN" in
  create:*)
    echo " - .gitignore: wird vorgeschlagen aus Template '${GITIGNORE_PLAN#create:}'"
    [ -d "$TEMPLATE_DIR" ] || echo "   (Hinweis: $TEMPLATE_DIR existiert nicht – Fallback wird genutzt)"
    ;;
  exists) echo " - .gitignore: vorhanden (keine Änderung)";;
  *) echo " - .gitignore: keine Aktion";;
esac

if [ "$HAS_GIT" = "no" ] && [ "$remote_empty" = "no" ]; then
  echo " - remote befüllt, lokal leer → Vorschlag: 'adopt-remote' (git pull --ff-only)"
fi

# Nichts-zu-tun-Check
DO_ANY="no"
[ "$HAS_GIT" = "no" ] && DO_ANY="yes"
[[ "$GITIGNORE_PLAN" == create:* ]] && DO_ANY="yes"
if [ -n "$REMOTE_URL" ]; then
  if git remote get-url origin >/dev/null 2>&1; then
    cur="$(git remote get-url origin 2>/dev/null || true)"; [ "$cur" != "$REMOTE_URL" ] && DO_ANY="yes"
  else
    DO_ANY="yes"
  fi
fi
if [ "$DO_ANY" = "no" ]; then
  echo "Keine Initialisierung nötig!"
  [ "${DRY_RUN:-}" = "yes" ] && echo "Abbruch: Modus (dry-run)."
  exit 0
fi

# Dry-run?
if [ "${DRY_RUN:-}" = "yes" ]; then
  echo "Abbruch: Modus (dry-run)."
  exit 0
fi

# Bestätigung
if [ "$(ask_yn "Fortfahren?")" != "y" ]; then
  echo "Abbruch: Benutzer."
  exit 0
fi

# -------- ACTIONS --------
# 1) git init
if [ "$HAS_GIT" = "no" ]; then
  logfx_run "git-init" -- git init -b "$BRANCH"
  HAS_GIT="yes"
fi

# 2) .gitignore
if [[ "$GITIGNORE_PLAN" == create:* ]]; then
  ART_DIR="$HOME/code/bin/shellscripts/debugs/${SCRIPT_ID}"
  mkdir -p "$ART_DIR"
  ART="$ART_DIR/gitignore.$(date +%Y%m%d-%H%M%S).jsonl"
  printf '{"ts":"%s","event":"gitignore.plan","template":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${GITIGNORE_PLAN#create:}" >> "$ART"
  echo "Artefakt: $ART"
  if [ "$(ask_yn "'.gitignore' aus Template '${GITIGNORE_PLAN#create:}' anlegen?")" = "y" ]; then
    logfx_event "gitignore" "action" "create" "template" "${GITIGNORE_PLAN#create:}"
    cat "$GITIGNORE_TEMP" > .gitignore
    echo "OK: .gitignore erstellt."
  else
    echo "Hinweis: .gitignore nicht angelegt."
  fi
fi

# 3) Remote setzen/prüfen
if [ -n "$REMOTE_URL" ]; then
  if git remote get-url origin >/dev/null 2>&1; then
    cur="$(git remote get-url origin 2>/dev/null || true)"
    if [ "$cur" != "$REMOTE_URL" ]; then
      if [ "$(ask_yn "origin zeigt auf '$cur'. Auf '$REMOTE_URL' ändern?")" = "y" ]; then
        logfx_run "remote-set-url" -- git remote set-url origin "$REMOTE_URL"
      else
        echo "origin unverändert."
      fi
    fi
  else
    logfx_run "remote-add-origin" -- git remote add origin "$REMOTE_URL"
  fi
fi

# Remote-Status neu feststellen
ORIGIN_SET="no"; ORIGIN_URL=""
if git remote get-url origin >/dev/null 2>&1; then
  ORIGIN_SET="yes"; ORIGIN_URL="$(git remote get-url origin 2>/dev/null || true)"
  if git ls-remote --heads --tags "$ORIGIN_URL" | grep -q .; then remote_empty="no"; else remote_empty="yes"; fi
fi

# 4) Erst-Sync
if [ "$ORIGIN_SET" = "yes" ]; then
  if [ "$remote_empty" = "yes" ]; then
    if git rev-parse HEAD >/dev/null 2>&1; then
      if [ "$(ask_yn "Remote ist leer. Lokalen '$BRANCH' nach origin pushen und Upstream setzen?")" = "y" ]; then
        logfx_run "first-push" -- git push -u origin "$BRANCH"
      fi
    else
      echo "Hinweis: Noch kein Commit lokal. Ersten Commit erstellen und dann pushen."
    fi
  else
    # Remote befüllt
    if [ "$DO_MIRROR_LOCAL" = "yes" ]; then
      if git rev-parse HEAD >/dev/null 2>&1; then
        if [ "$(ask_yn "Achtung: Remote mit lokalem '$BRANCH' **überschreiben** (force push)?")" = "y" ]; then
          logfx_run "force-push" -- git push --force origin "$BRANCH"
        fi
      else
        echo "Abbruch: Kein lokaler Commit vorhanden. Bitte zuerst lokalen Initial-Commit erstellen (git add -A && git commit -m ...)."
      fi
    else
      # adopt-remote (nur wenn lokal leer)
      if ! git rev-parse HEAD >/dev/null 2>&1; then
        if [ "$(ask_yn "Remote befüllt, lokal leer. 'git pull --ff-only origin $BRANCH' ausführen?")" = "y" ]; then
          logfx_run "adopt-remote" -- git pull --ff-only origin "$BRANCH"
        fi
      else
        echo "Warnung: Lokale und Remote-Historie vorhanden. Keine Aktion per Default."
        echo "         Nutze --mirror-local (destruktiv) oder führe rebase/merge manuell aus."
      fi
    fi
  fi
else
  echo "Hinweis: Kein Remote 'origin' gesetzt. Nutze --remote=<url> oder 'git remote add origin <url>'."
fi

echo "Fertig."
exit 0
