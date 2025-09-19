#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# git-init — universelles Initialisieren/Verdrahten von Repositories (bin|project)
#   - Plan + Rückfragen (Y/N), --yes, --no-input
#   - .gitignore-Vorschläge (bin/laravel), Artefakt-Ausgabe
#   - Remote erkennen (leer/nicht leer), Push/Pull-Plan
#   - Keine destruktiven Defaults (mirror nur mit Option)
# Version: v0.1.0
# -----------------------------------------------------------------------------
set -euo pipefail
IFS=$'\n\t'

SCRIPT_ID="git-init"
SCRIPT_VERSION="v0.1.0"
DEBUG_DIR="${HOME}/code/bin/shellscripts/debugs/${SCRIPT_ID}"

# Defaults
LOG_LEVEL="trace"   # überschreibbar via --debug
DRY_RUN="no"
NO_COLOR_FORCE="no"
ASSUME_YES="no"
NO_INPUT="no"

REMOTE_URL=""
BRANCH="main"
TEMPLATE="auto"     # auto|bin|laravel|none
# Konflikt-Optionen (werden nur angewandt, wenn explizit gesetzt)
DO_REBASE="no"
DO_MERGE="no"
DO_MIRROR_LOCAL="no"

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
ts(){ date -u +"%Y-%m-%dT%H:%M:%SZ"; }
dbg_path(){ printf '%s/%s.%s.%s.jsonl\n' "$DEBUG_DIR" "$SCRIPT_ID" "$LOG_LEVEL" "$(date +%Y%m%d-%H%M%S)"; }

LOG_PATH=""
log_init(){
  mkdir -p "$DEBUG_DIR"
  LOG_PATH="$(dbg_path)"
  : > "$LOG_PATH"
  printf '{"ts":"%s","script":"%s","level":"%s","event":"boot","msg":"start"}\n' "$(ts)" "$SCRIPT_ID" "$LOG_LEVEL" >> "$LOG_PATH"
  if [ -n "$BOLD" ]; then printf "%sDEBUG%s: %s%s%s\n" "$YEL$BOLD" "$RST" "$RED" "$LOG_PATH" "$RST"; else echo "DEBUG: $LOG_PATH"; fi
}
log_evt(){ printf '{"ts":"%s","event":"%s","detail":"%s"}\n' "$(ts)" "$1" "$(echo "$2" | sed 's/"/\\"/g')" >> "$LOG_PATH"; }

# Args
for arg in "$@"; do
  case "$arg" in
    --help)    echo "$SCRIPT_ID $SCRIPT_VERSION"; exit 0 ;;
    --version) echo "$SCRIPT_ID $SCRIPT_VERSION"; exit 0 ;;
    --dry-run) DRY_RUN="yes" ;;
    --debug=*) LOG_LEVEL="${arg#*=}" ;;
    --no-color) NO_COLOR_FORCE="yes" ;;
    --yes|-y) ASSUME_YES="yes" ;;
    --no-input) NO_INPUT="yes" ;;
    --remote=*) REMOTE_URL="${arg#*=}" ;;
    --branch=*) BRANCH="${arg#*=}" ;;
    --template=*) TEMPLATE="${arg#*=}" ;;   # auto|bin|laravel|none
    --rebase) DO_REBASE="yes" ;;
    --merge) DO_MERGE="yes" ;;
    --mirror-local) DO_MIRROR_LOCAL="yes" ;;
    --project=*) : ;; # No-Op (Altlast)
    *) echo "Unbekannte Option: $arg"; echo "Nutze --help"; exit 3 ;;
  esac
done

ask_yn(){
  # $1=Frage-Text
  local q="$1"
  if [ "$ASSUME_YES" = "yes" ]; then echo "y"; return 0; fi
  if [ "$NO_INPUT" = "yes" ]; then echo "n"; return 0; fi
  printf "%s [y/N]: " "$q" >&2
  read -r ans || true
  case "${ans,,}" in y|yes) echo "y";; *) echo "n";; esac
}

# Gatekeeper / Kontext
BIN_PATH="$HOME/code/bin"
PWD_P="$(pwd -P)"
MODE="unknown"
REPO_ROOT="$PWD_P"
ENV_FILE=""
PROJ_NAME=""  # Anzeigename (Project)
APP_NAME=""   # technischer Name (Project)

color_init; log_init

if [ "$PWD_P" = "$BIN_PATH" ]; then
  MODE="bin"
else
  # Projektmodus nur, wenn .env existiert
  if [ -f "$PWD_P/.env" ]; then
    MODE="project"
    ENV_FILE="$PWD_P/.env"
    PROJ_NAME="$(grep -E '^[[:space:]]*PROJ_NAME[[:space:]]*=' "$ENV_FILE" | tail -1 | cut -d'=' -f2- | sed 's/^["'\'']//; s/["'\'']$//' | tr -d '\r' || true)"
    [ -z "$PROJ_NAME" ] && PROJ_NAME="$(grep -E '^[[:space:]]*PROJ-NAME[[:space:]]*=' "$ENV_FILE" | tail -1 | cut -d'=' -f2- | sed 's/^["'\'']//; s/["'\'']$//' | tr -d '\r' || true)"
    APP_NAME="$(grep -E '^[[:space:]]*APP_NAME[[:space:]]*=' "$ENV_FILE" | tail -1 | cut -d'=' -f2- | sed 's/^["'\'']//; s/["'\'']$//' | tr -d '\r' || true)"
  else
    # Weder bin noch project → echter Gatekeeper-Fall
    msg="Gatekeeper: Weder ~/code/bin noch Projekt (.env) — hier nicht ausführen."
    [ -n "$BOLD" ] && printf "%s%s%s\n" "$YEL$BOLD" "$msg" "$RST" || echo "$msg"
    exit 2
  fi
fi

# Ist bereits ein Git-Repo?
HAS_GIT="no"; HAS_COMMITS="no"
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  # Nur in Wurzel weiterarbeiten
  ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD_P")"
  if [ "$ROOT" != "$PWD_P" ]; then
    msg="Gatekeeper: Bitte in der Repo-Wurzel arbeiten: $ROOT"
    [ -n "$BOLD" ] && printf "%s%s%s\n" "$YEL$BOLD" "$msg" "$RST" || echo "$msg"
    exit 2
  fi
  HAS_GIT="yes"
  if git rev-parse HEAD >/dev/null 2>&1; then HAS_COMMITS="yes"; fi
fi

# Remote-Infos
ORIGIN_SET="no"; ORIGIN_URL=""
if git remote get-url origin >/dev/null 2>&1; then
  ORIGIN_SET="yes"
  ORIGIN_URL="$(git remote get-url origin 2>/dev/null || true)"
fi

remote_empty="unknown"
if [ -n "$REMOTE_URL" ]; then
  # Prüfe Remote-Leerheit
  if git ls-remote --heads --tags "$REMOTE_URL" | grep -q .; then
    remote_empty="no"
  else
    remote_empty="yes"
  fi
elif [ "$ORIGIN_SET" = "yes" ]; then
  if git ls-remote --heads --tags "$ORIGIN_URL" | grep -q .; then
    remote_empty="no"
  else
    remote_empty="yes"
  fi
fi

# .gitignore Handling
decide_template(){
  local t="$1"
  if [ "$t" = "auto" ]; then
    if [ "$MODE" = "bin" ]; then echo "bin"; else echo "laravel"; fi
  else
    echo "$t"
  fi
}
template_content(){
  case "$1" in
    bin)
      cat <<'G'
# bin repo ignore
shellscripts/debugs/
shellscripts/backups/
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
    none) ;;
  esac
}
GITIGNORE_PLAN="skip"
GITIGNORE_TEMP="$(mktemp -t gitignore.tpl.XXXXXX)"
trap 'rm -f "$GITIGNORE_TEMP"' EXIT

if [ ! -f "$PWD_P/.gitignore" ]; then
  TSEL="$(decide_template "$TEMPLATE")"
  if [ "$TSEL" != "none" ]; then
    template_content "$TSEL" > "$GITIGNORE_TEMP"
    GITIGNORE_PLAN="create:$TSEL"
  fi
else
  # .gitignore existiert → optional Hinweis/Artefakt
  GITIGNORE_PLAN="exists"
fi

# --------- Plan ausgeben ------------------------------------------------------
if [ -n "$BOLD" ]; then
  printf "%sPLAN%s  Mode:%s %s %s Branch:%s %s %s\n" \
    "$BOLD" "$RST" "$BLU" "$MODE" "$RST" "$YEL" "$BRANCH" "$RST"
  if [ "$MODE" = "project" ]; then
    printf "      APP_NAME:%s %s%s   PROJ_NAME:%s %s%s\n" "$RST" "$YEL" "${APP_NAME:-}" "$RST" "$YEL" "${PROJ_NAME:-}"
  fi
else
  echo "PLAN  Mode:$MODE  Branch:$BRANCH"
  [ "$MODE" = "project" ] && echo "      APP_NAME:${APP_NAME:-}  PROJ_NAME:${PROJ_NAME:-}"
fi

if [ "$HAS_GIT" = "no" ]; then
  echo " - lokal: kein .git → git init -b $BRANCH"
else
  echo " - lokal: bereits Git-Repo (Commits: $HAS_COMMITS)"
fi

if [ -n "$REMOTE_URL" ]; then
  echo " - remote (arg): $REMOTE_URL (leer: $remote_empty)"
elif [ "$ORIGIN_SET" = "yes" ]; then
  echo " - remote (origin): $ORIGIN_URL (leer: $remote_empty)"
else
  echo " - remote: (kein origin gesetzt)"
fi

case "$GITIGNORE_PLAN" in
  create:*) echo " - .gitignore: wird vorgeschlagen aus Template '${GITIGNORE_PLAN#create:}'";;
  exists)   echo " - .gitignore: vorhanden (keine Änderung)";;
  *)        echo " - .gitignore: keine Aktion";;
esac

# Divergenz-/Strategiehinweis, nur wenn remote bekannt & nicht leer
if [ "$HAS_GIT" = "no" ] && [ "$remote_empty" = "no" ]; then
  echo " - remote befüllt, lokal leer → Vorschlag: 'adopt-remote' (git pull --ff-only)"
fi

# Bestätigen (falls nötig)
proceed="y"
if [ "$DRY_RUN" = "yes" ]; then
  proceed="n"
else
  proceed="$(ask_yn "Fortfahren?")"
fi
[ "$proceed" = "y" ] || { echo "Abbruch durch Benutzer/Modus."; exit 0; }

# --------- Ausführung ---------------------------------------------------------

# 1) git init (falls nötig)
if [ "$HAS_GIT" = "no" ]; then
  log_evt "step" "git init -b $BRANCH"
  if [ "$DRY_RUN" = "yes" ]; then
    echo "DRY-RUN: git init -b $BRANCH"
  else
    git init -b "$BRANCH"
    HAS_GIT="yes"
  fi
fi

# 2) .gitignore (falls geplant)
if [[ "$GITIGNORE_PLAN" == create:* ]]; then
  ART="$DEBUG_DIR/gitignore.$(date +%Y%m%d-%H%M%S).jsonl"
  printf '{"ts":"%s","event":"gitignore.plan","template":"%s"}\n' "$(ts)" "${GITIGNORE_PLAN#create:}" >> "$ART"
  echo "Artefakt: $ART"

  yn="$(ask_yn "'.gitignore' aus Template '${GITIGNORE_PLAN#create:}' anlegen?")"
  if [ "$yn" = "y" ]; then
    log_evt "step" "create .gitignore from ${GITIGNORE_PLAN#create:}"
    if [ "$DRY_RUN" = "yes" ]; then
      echo "DRY-RUN: installiere .gitignore (${GITIGNORE_PLAN#create:})"
    else
      cat "$GITIGNORE_TEMP" > .gitignore
      echo "OK: .gitignore erstellt."
    fi
  else
    echo "Hinweis: .gitignore nicht angelegt."
  fi
fi

# 3) Remote setzen/prüfen
desired_remote=""
[ -n "$REMOTE_URL" ] && desired_remote="$REMOTE_URL"
if [ -n "$desired_remote" ]; then
  if git remote get-url origin >/dev/null 2>&1; then
    cur="$(git remote get-url origin 2>/dev/null || true)"
    if [ "$cur" != "$desired_remote" ]; then
      yn="$(ask_yn "origin zeigt auf '$cur'. Auf '$desired_remote' ändern?")"
      if [ "$yn" = "y" ]; then
        log_evt "step" "git remote set-url origin $desired_remote"
        [ "$DRY_RUN" = "yes" ] && echo "DRY-RUN: git remote set-url origin $desired_remote" || git remote set-url origin "$desired_remote"
      else
        echo "origin unverändert."
      fi
    fi
  else
    log_evt "step" "git remote add origin $desired_remote"
    [ "$DRY_RUN" = "yes" ] && echo "DRY-RUN: git remote add origin $desired_remote" || git remote add origin "$desired_remote"
  fi
fi

# Remote-Leerheit ggf. neu bestimmen
if git remote get-url origin >/dev/null 2>&1; then
  ORIGIN_SET="yes"; ORIGIN_URL="$(git remote get-url origin 2>/dev/null || true)"
  if git ls-remote --heads --tags "$ORIGIN_URL" | grep -q .; then remote_empty="no"; else remote_empty="yes"; fi
fi

# 4) Erste Synchronisation / Strategie
if [ "$ORIGIN_SET" = "yes" ]; then
  if [ "$remote_empty" = "yes" ]; then
    # Remote leer
    if git rev-parse HEAD >/dev/null 2>&1; then
      yn="$(ask_yn "Remote ist leer. Lokalen '$BRANCH' nach origin pushen und Upstream setzen?")"
      if [ "$yn" = "y" ]; then
        log_evt "step" "git push -u origin $BRANCH"
        [ "$DRY_RUN" = "yes" ] && echo "DRY-RUN: git push -u origin $BRANCH" || git push -u origin "$BRANCH"
      fi
    else
      echo "Hinweis: Noch kein Commit lokal. Ersten Commit erstellen und dann pushen."
    fi
  else
    # Remote befüllt
    if ! git rev-parse HEAD >/dev/null 2>&1; then
      # lokal leer → adopt remote
      yn="$(ask_yn "Remote befüllt, lokal leer. 'git pull --ff-only origin $BRANCH' ausführen?")"
      if [ "$yn" = "y" ]; then
        log_evt "step" "git pull --ff-only origin $BRANCH"
        [ "$DRY_RUN" = "yes" ] && echo "DRY-RUN: git pull --ff-only origin $BRANCH" || git pull --ff-only origin "$BRANCH"
      fi
    else
      # beide befüllt → sichere Abbruch-Policy standard
      echo "Warnung: Lokale und Remote-Historie vorhanden."
      if [ "$DO_REBASE" = "yes" ]; then
        yn="$(ask_yn "Rebase auf origin/$BRANCH durchführen?")"
        if [ "$yn" = "y" ]; then
          log_evt "step" "git fetch origin && git rebase origin/$BRANCH"
          if [ "$DRY_RUN" = "yes" ]; then
            echo "DRY-RUN: git fetch origin && git rebase origin/$BRANCH"
          else
            git fetch origin
            git rebase "origin/$BRANCH"
          fi
        fi
      elif [ "$DO_MERGE" = "yes" ]; then
        yn="$(ask_yn "Merge von origin/$BRANCH durchführen (no-ff)?")"
        if [ "$yn" = "y" ]; then
          log_evt "step" "git fetch origin && git merge --no-ff origin/$BRANCH"
          if [ "$DRY_RUN" = "yes" ]; then
            echo "DRY-RUN: git fetch origin && git merge --no-ff origin/$BRANCH"
          else
            git fetch origin
            git merge --no-ff "origin/$BRANCH" || true
          fi
        fi
      elif [ "$DO_MIRROR_LOCAL" = "yes" ]; then
        yn="$(ask_yn "Achtung: Lokale Historie nach origin **spiegeln** (destruktiv, --force)?")"
        if [ "$yn" = "y" ]; then
          log_evt "step" "git push --force origin $BRANCH"
          [ "$DRY_RUN" = "yes" ] && echo "DRY-RUN: git push --force origin $BRANCH" || git push --force origin "$BRANCH"
        fi
      else
        echo "Standard: kein automatischer Eingriff. Nutze --rebase | --merge | --mirror-local je nach gewünschter Strategie."
      fi
    fi
  fi
else
  echo "Hinweis: Kein Remote 'origin' gesetzt. Nutze --remote=<url> oder 'git remote add origin <url>'."
fi

echo "Fertig."
exit 0
