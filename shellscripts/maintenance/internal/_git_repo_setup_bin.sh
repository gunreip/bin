#!/usr/bin/env bash
# =====================================================================
#  _git_repo_setup_bin.sh — Git-Setup für ~/bin (Repo, Ignore, CI, Hooks)
#  SCRIPT_VERSION="v0.1.3"
# =====================================================================
# CHANGELOG
# v0.1.3 (2025-09-14) ✅
# - Default: 'temp/' zu .gitignore ergänzt
# - Pre-Check: Blockiert Commit/Push bei Dateien >95 MiB (Schwelle konfigurierbar)
# - Option: --auto-untrack-big entfernt große, bereits getrackte Dateien aus dem Index (Dateien bleiben lokal)
#
# v0.1.2 (2025-09-14) ✅
# - Error-Trap (LINE/CMD) · Vorab-Checks · robustere Dry-Run-Ausgaben
#
# v0.1.1 (2025-09-14) ✅
# - Remote-URL-Validierung (SSH/HTTPS) · --validate-only
#
# v0.1.0 (2025-09-14) ✅
# - Initiale Version
#
# shellcheck disable=
#
# =====================================================================

set -euo pipefail
IFS=$'\n\t'

# ---- Error Trap ------------------------------------------------------
on_err() {
  local ec=$?; local ln=${BASH_LINENO[0]:-?}; local cmd=${BASH_COMMAND:-?}
  echo "ERROR (exit=$ec) at line $ln: $cmd" >&2
  echo "Tipp: erneut mit --steps=3 laufen lassen, um mehr Details zu sehen." >&2
  exit $ec
}
trap on_err ERR

PROG_ID="git_repo_setup_bin"
PROG_NAME="git_repo_setup_bin"

# Standard-Icons
ICON_OK="✅"; ICON_WARN="⚡"; ICON_FAIL="❌"; ICON_UNKNOWN="⁉️"

# Defaults
DRYRUN="yes"             # sicher zuerst
STEPS=0                  # 0 still, 1 grob, 2 details, 3 debug
INIT="auto"              # auto|yes|no
CREATE_CI="no"
PRE_COMMIT="no"
REMOTE_URL=""
DO_FIRST_COMMIT="no"
COMMIT_MSG="feat(repo): init bin scripts"
DO_PUSH="no"
PUSH_TAGS="no"
USER_NAME=""
USER_EMAIL=""
VALIDATE_ONLY="no"

# Big-file-Check
BIG_THRESHOLD_MIB=95     # konfigurierbar via --big-threshold=MiB
AUTO_UNTRACK_BIG="no"    # --auto-untrack-big aktiviert automatisches git rm --cached

# Farben (TTY)
if [ -t 1 ]; then
  C_R=$'\033[0m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_B=$'\033[34m'; C_Rd=$'\033[31m'
else
  C_R=""; C_G=""; C_Y=""; C_B=""; C_Rd=""
fi

die(){ echo -e "${C_Rd}ERROR:${C_R} $*" >&2; exit 1; }
note(){ [ "$STEPS" -ge 2 ] && echo "  - $*"; }
step(){ [ "$STEPS" -ge 1 ] && echo -e "${C_B}▶${C_R} $*"; }
dbg(){  [ "$STEPS" -ge 3 ] && echo "    · $*"; }
ok(){   echo -e "${C_G}${ICON_OK}${C_R} $*"; }
warn(){ echo -e "${C_Y}${ICON_WARN}${C_R} $*"; }

gatekeeper(){
  local cwd; cwd="$(pwd -P)"
  if [ "${cwd%/}" != "${HOME}/bin" ]; then
    echo -e "${C_Rd}Gatekeeper:${C_R} Bitte aus \`~/bin\` ausführen. Aktuell: \`$cwd\`" >&2
    exit 2
  fi
  [ -w "$cwd" ] || die "Keine Schreibrechte in \`$cwd\`."
}

usage(){
  cat <<USAGE
$PROG_NAME — Git-Setup für \`~/bin\`

Nutzung:
  $PROG_NAME [--no-dry-run] [--steps=0|1|2|3] [--init=yes|no|auto]
              [--create-ci] [--pre-commit]
              [--remote=URL] [--first-commit] [--commit-msg="..."]
              [--push] [--push-tags]
              [--user-name="..."] [--user-email="..."]
              [--validate-only]
              [--big-threshold=MiB] [--auto-untrack-big]

Hinweise:
  Remote (SSH):   git@github.com:<USER>/<REPO>.git
  Remote (HTTPS): https://github.com/<USER>/<REPO>.git
  Big-File-Schwelle Default: 95 MiB (GitHub hartes Limit: 100 MiB)
USAGE
}

is_valid_remote(){
  local url="$1"
  [[ "$url" =~ ^git@github\.com:[A-Za-z0-9._-]+/[A-Za-z0-9._-]+\.git$ ]] && return 0
  [[ "$url" =~ ^https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+(\.git)?$ ]] && return 0
  return 1
}

write_file(){
  local path="$1" content="$2"
  if [ "$DRYRUN" = "yes" ]; then
    step "write (dry): \`$path\`"
    dbg  "content preview:"; dbg  "$(printf '%s\n' "$content" | head -n 5)"
    return 0
  fi
  local dir; dir="$(dirname "$path")"
  mkdir -p "$dir"
  if [ -f "$path" ]; then
    local bdir="$HOME/bin/backups/${PROG_ID}"
    mkdir -p "$bdir"
    cp -a "$path" "$bdir/$(basename "$path").$(date +%Y%m%d-%H%M%S).bak"
  fi
  printf '%s\n' "$content" > "$path"
}

write_exec(){
  local path="$1" content="$2"
  write_file "$path" "$content"
  if [ "$DRYRUN" = "no" ]; then chmod +x "$path"; fi
}

report_paths(){ local dir="$HOME/bin/reports/${PROG_ID}"; mkdir -p "$dir"; echo "$dir"; }
report_write(){
  local dir; dir="$(report_paths)"
  local md="$dir/latest.md"; local json="$dir/latest.json"
  printf '%s\n' "# $PROG_NAME — Report ($(date +%F' '%T%z))" > "$md"
  printf '%s\n' "$1" >> "$md"
  printf '%s\n' "$2" > "$json"
}

pre_checks(){
  command -v git >/dev/null 2>&1 || die "'git' nicht gefunden (installiere git)."
}

# ---- Big File Scanner -------------------------------------------------
# Gibt Zeilen "size_bytes<TAB>path" für getrackte Dateien >= threshold aus.
list_tracked_bigfiles(){
  local threshold="$1"
  [ -d .git ] || return 0
  while IFS= read -r -d '' f; do
    [ -f "$f" ] || continue
    local sz
    sz=$(stat -c%s "$f" 2>/dev/null || wc -c < "$f")
    [ "${sz:-0}" -ge "$threshold" ] && printf '%s\t%s\n' "$sz" "$f"
  done < <(git ls-files -z)
}

# Fügt 'temp/' zu .gitignore hinzu, wenn nicht vorhanden.
ensure_temp_ignored(){
  if ! grep -qxF 'temp/' .gitignore 2>/dev/null; then
    write_file ".gitignore" "$( ( [ -f .gitignore ] && cat .gitignore; printf '\n# temp (ignored)\ntemp/\n' ) )"
  fi
}

main(){
  pre_checks
  gatekeeper

  for arg in "$@"; do
    case "$arg" in
      --no-dry-run) DRYRUN="no" ;;
      --dry-run)    DRYRUN="yes" ;;
      --steps=*)    STEPS="${arg#*=}" ;;
      --init=*)     INIT="${arg#*=}" ;;
      --create-ci)  CREATE_CI="yes" ;;
      --pre-commit) PRE_COMMIT="yes" ;;
      --remote=*)   REMOTE_URL="${arg#*=}" ;;
      --first-commit) DO_FIRST_COMMIT="yes" ;;
      --commit-msg=*) COMMIT_MSG="${arg#*=}" ;;
      --push)       DO_PUSH="yes" ;;
      --push-tags)  PUSH_TAGS="yes" ;;
      --user-name=*) USER_NAME="${arg#*=}" ;;
      --user-email=*) USER_EMAIL="${arg#*=}" ;;
      --validate-only) VALIDATE_ONLY="yes" ;;
      --big-threshold=*) BIG_THRESHOLD_MIB="${arg#*=}" ;;
      --auto-untrack-big) AUTO_UNTRACK_BIG="yes" ;;
      -h|--help)    usage; exit 0 ;;
      *) ;;
    esac
  done

  # Remote validieren (falls gesetzt)
  if [ -n "$REMOTE_URL" ] && ! is_valid_remote "$REMOTE_URL"; then
    die "Ungültige Remote-URL: \`$REMOTE_URL\`
Erwartete Formate:
  SSH:   git@github.com:<USER>/<REPO>.git
  HTTPS: https://github.com/<USER>/<REPO>.git"
  fi

  # validate-only: nur Umgebung/Parameter prüfen
  if [ "$VALIDATE_ONLY" = "yes" ]; then
    ok "Validate-only: OK"
    echo "- cwd: $(pwd -P)"
    echo "- .git: $([ -d .git ] && echo vorhanden || echo fehlt)"
    echo "- remote: ${REMOTE_URL:-<nicht übergeben>}"
    echo "- big-threshold: ${BIG_THRESHOLD_MIB} MiB"
    exit 0
  fi

  step "Starte Setup (dry-run=$DRYRUN, steps=$STEPS)"

  # 1) git init
  if [ -d ".git" ]; then
    note ".git bereits vorhanden"
    if [ "$INIT" = "yes" ]; then warn ".git existiert; \`git init -b main\` wird übersprungen"; fi
  else
    if [ "$INIT" = "yes" ] || [ "$INIT" = "auto" ]; then
      step "Initialisiere Repository (main)"
      if [ "$DRYRUN" = "yes" ]; then
        warn "dry-run: init nur simuliert"
      else
        git init -b main
      fi
      ok "Repo initialisiert (oder vorhanden)"
    else
      warn "INIT=no: git init übersprungen"
    fi
  fi

  # 2) .gitignore (inkl. temp/)
  step "Schreibe/aktualisiere .gitignore"
  write_file ".gitignore" "$(cat <<'GI'
# --- GENERATED/volatile ---
reports/
debug/
backups/
.wiki/
temp/

# changelogs: Hauptdatei versionieren, Snapshots ignorieren
!changelogs/
changelogs/**/CHANGELOG-*.md.*.md

# System/Editor
.DS_Store
Thumbs.db

# Node/npm caches (falls vorhanden)
node_modules/
GI
)"
  # Falls vorhandene .gitignore überschrieben wurde, ist temp/ ohnehin enthalten.
  # Falls nicht (dry-run), dann separat sicherstellen:
  [ "$DRYRUN" = "yes" ] && ensure_temp_ignored || :

  # 3) .gitattributes
  step "Schreibe .gitattributes"
  write_file ".gitattributes" "$(cat <<'GA'
*.sh          text eol=lf
*.bash        text eol=lf
*.md          text eol=lf
*.yml         text eol=lf
*.yaml        text eol=lf
*.json        text eol=lf
*.css         text eol=lf
GA
)"

  # 4) .editorconfig
  step "Schreibe .editorconfig"
  write_file ".editorconfig" "$(cat <<'EC'
root = true

[*.{sh,bash}]
indent_style = space
indent_size  = 2
end_of_line  = lf
charset      = utf-8
trim_trailing_whitespace = true
insert_final_newline = true

[*.md]
trim_trailing_whitespace = false
EC
)"

  # 5) git config lokal (optional)
  if [ -n "$USER_NAME" ] || [ -n "$USER_EMAIL" ]; then
    step "Setze lokale Git-Identität"
    if [ "$DRYRUN" = "yes" ]; then
      warn "dry-run: git config nur simuliert"
    else
      [ -n "$USER_NAME" ]  && git config user.name  "$USER_NAME"
      [ -n "$USER_EMAIL" ] && git config user.email "$USER_EMAIL"
    fi
  fi

  # 6) CI (optional)
  if [ "$CREATE_CI" = "yes" ]; then
    step "Erzeuge GitHub Actions Workflow"
    write_file ".github/workflows/shell.yml" "$(cat <<'YAML'
name: shell-quality
on:
  push:
    paths:
      - 'shellscripts/**/*.sh'
      - '.github/workflows/shell.yml'
  pull_request:
    paths:
      - 'shellscripts/**/*.sh'
jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4
      - name: Install shellcheck & shfmt
        run: |
          sudo apt-get update
          sudo apt-get install -y shellcheck
          curl -sSLo /usr/local/bin/shfmt https://github.com/mvdan/sh/releases/latest/download/shfmt_linux_amd64
          chmod +x /usr/local/bin/shfmt
      - name: shellcheck
        run: shellcheck -S style -x $(git ls-files 'shellscripts/**/*.sh')
      - name: shfmt (diff)
        run: shfmt -d -i 2 -ci -sr $(git ls-files 'shellscripts/**/*.sh')
YAML
)"
  fi

  # 7) Pre-Commit Hook (optional)
  if [ "$PRE_COMMIT" = "yes" ]; then
    step "Installiere pre-commit Hook"
    write_exec ".git/hooks/pre-commit" "$(cat <<'HOOK'
#!/usr/bin/env bash
set -euo pipefail
files=$(git diff --cached --name-only --diff-filter=ACM | grep -E '^shellscripts/.+\.sh$' || true)
[ -z "$files" ] && exit 0
echo "pre-commit: shellcheck..."
shellcheck -S style -x $files
echo "pre-commit: shfmt check..."
shfmt -d -i 2 -ci -sr $files
HOOK
)"
  fi

  # ---- Big Files Check (vor Commit/Push) ------------------------------
  local threshold_bytes=$((BIG_THRESHOLD_MIB * 1024 * 1024))
  step "Prüfe auf große getrackte Dateien (>= ${BIG_THRESHOLD_MIB} MiB)"
  local big_list
  big_list="$(list_tracked_bigfiles "$threshold_bytes" || true)"
  if [ -n "$big_list" ]; then
    echo "Gefunden (Größe[B]\tPfad):"
    echo "$big_list" | sort -nr
    if [ "$AUTO_UNTRACK_BIG" = "yes" ] && [ "$DRYRUN" = "no" ] && [ -d ".git" ]; then
      warn "auto-untrack-big aktiv → entferne große Dateien aus dem Index (bleiben lokal erhalten)"
      # Nur Pfadspalte an git rm --cached übergeben
      echo "$big_list" | awk -F'\t' '{print $2}' | xargs -r git rm --cached --ignore-unmatch
      ok "Große Dateien aus dem Index entfernt"
    else
      die "Große getrackte Dateien erkannt. Bitte entweder:
- Dateien in .gitignore aufnehmen und per \`git rm --cached <pfad>\` enttracken, ODER
- Skript mit \`--auto-untrack-big\` erneut ausführen (entfernt nur aus Index).
Hinweis: Dateien bleiben lokal erhalten."
    fi
  else
    note "Keine großen getrackten Dateien gefunden."
  fi

  # 8) Remote (optional)
  if [ -n "$REMOTE_URL" ]; then
    step "Setze Remote origin"
    if [ "$DRYRUN" = "yes" ] || [ ! -d ".git" ]; then
      warn "dry-run/kein .git: remote nur simuliert → $REMOTE_URL"
    else
      if git remote get-url origin >/dev/null 2>&1; then
        git remote set-url origin "$REMOTE_URL"
      else
        git remote add origin "$REMOTE_URL"
      fi
    fi
  fi

  # 9) Erster Commit (optional)
  if [ "$DO_FIRST_COMMIT" = "yes" ]; then
    step "Erster Commit"
    if [ "$DRYRUN" = "yes" ] || [ ! -d ".git" ]; then
      warn "dry-run/kein .git: add/commit nur simuliert"
    else
      git add -A
      git commit -m "$COMMIT_MSG" || warn "Nichts zu committen?"
    fi
  fi

  # 10) Push (optional)
  if [ "$DO_PUSH" = "yes" ]; then
    step "Push main"
    if [ "$DRYRUN" = "yes" ] || [ ! -d ".git" ]; then
      warn "dry-run/kein .git: push nur simuliert"
    else
      if git rev-parse --abbrev-ref --symbolic-full-name @{u} >/dev/null 2>&1; then
        git push
      else
        git push -u origin main
      fi
      [ "$PUSH_TAGS" = "yes" ] && git push --tags || :
    fi
  fi

  ok "Fertig."
  report_write \
"- Status: ${ICON_OK} abgeschlossen  
- DRYRUN: ${DRYRUN} · INIT: ${INIT} · CI: ${CREATE_CI} · PRE_COMMIT: ${PRE_COMMIT}  
- REMOTE: ${REMOTE_URL:-<none>} · FIRST_COMMIT: ${DO_FIRST_COMMIT} · PUSH: ${DO_PUSH}  
- BIG_THRESHOLD_MIB: ${BIG_THRESHOLD_MIB} · AUTO_UNTRACK_BIG: ${AUTO_UNTRACK_BIG}
" \
"{\"status\":\"ok\",\"dryrun\":\"$DRYRUN\",\"init\":\"$INIT\",\"ci\":\"$CREATE_CI\",\"pre_commit\":\"$PRE_COMMIT\",\"remote\":\"${REMOTE_URL}\",\"first_commit\":\"$DO_FIRST_COMMIT\",\"push\":\"$DO_PUSH\",\"big_threshold_mib\":\"$BIG_THRESHOLD_MIB\",\"auto_untrack_big\":\"$AUTO_UNTRACK_BIG\"}"
}

main "$@"
