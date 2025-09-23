#!/usr/bin/env bash
# git-feature — Feature-Branch-Helfer
# SCRIPT_VERSION="v0.2.9"
# Änderungen ggü. v0.2.8:
# - Default-Loglevel wieder "trace" (Kompatibilität mit Bestand).
# - Audit-Append ohne Locking (flock entfernt). sync/touch zur Editor-Aktualisierung bleibt.

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_ID="git-feature"
SCRIPT_VERSION="v0.2.9"

# -------------------- Defaults / Flags --------------------
NO_COLOR=0; DRY=0; ASSUME_YES=0; ALLOW_DIRTY=0; REUSE=0; AUTO_PUSH=0; DO_JSON=0; SUMMARY_ONLY=0
DEBUG_MODE="trace"   # <- Standard wieder trace
FEATURE_NAME=""; TICKET_ID=""

# -------------------- Argparse --------------------
for arg in "$@"; do
  case "$arg" in
    --no-color) NO_COLOR=1 ;;
    --dry-run) DRY=1 ;;
    --yes) ASSUME_YES=1 ;;
    --allow-dirty) ALLOW_DIRTY=1 ;;
    --reuse) REUSE=1 ;;
    --push) AUTO_PUSH=1 ;;
    --json) DO_JSON=1 ;;
    --summary-only) SUMMARY_ONLY=1 ;;
    --debug=*) DEBUG_MODE="${arg#*=}" ;;
    --name=*) FEATURE_NAME="${arg#*=}" ;;
    --ticket=*) TICKET_ID="${arg#*=}" ;;
    --version) echo "$SCRIPT_VERSION"; exit 0 ;;
    --help)
      cat <<'EOF'
git-feature v0.2.9
Kurzbeschreibung:
  Erstellt/öffnet Feature-Branches: feat/<ticket>-<name>

Beispiele:
  git-feature --name="gunreip" --ticket=TW-42
  git-feature --name="gunreip" --ticket=TW-42 --reuse
  git-feature --name=alice --ticket=ABC-7 --push --yes
  git-feature --name=alice --ticket=ABC-7 --dry-run --debug=trace
  git-feature --name=alice --ticket=ABC-7 --yes --json --summary-only

Optionen:
  --name=STR, --ticket=STR, --reuse, --push, --allow-dirty, --dry-run, --yes,
  --json, --summary-only, --debug=dbg|trace|xtrace, --no-color, --version, --help

Audits (append, monatlich):
  ~/code/bin/shellscripts/audits/git-feature/<repo>/<YYYY>/<YYYY-MM>.jsonl

Exit-Codes: 0 ok, 1 Fehler, 2 Usage/Gatekeeper
EOF
      exit 0 ;;
    *) echo "Unbekannte Option: $arg" >&2; exit 2 ;;
  esac
done

# -------------------- Farben (ANSI) --------------------
FX_BLU=$'\033[34m'; FX_GRN=$'\033[32m'; FX_YEL=$'\033[33m'; FX_RED=$'\033[31m'; FX_BOLD=$'\033[1m'; FX_RST=$'\033[0m'
COLOR_ON=1
if [ "$NO_COLOR" -eq 1 ] || [ ! -t 1 ]; then FX_BLU=""; FX_GRN=""; FX_YEL=""; FX_RED=""; FX_BOLD=""; FX_RST=""; COLOR_ON=0; fi
trap 'printf "\033[0m" 2>/dev/null || true; printf "\033[0m" >/dev/tty 2>/dev/null || true' EXIT INT TERM HUP ERR
_print_c(){ if [ "$SUMMARY_ONLY" -eq 0 ]; then [ "$COLOR_ON" -eq 1 ] && printf "%s%s\033[0m\n" "$1" "${*:2}" || printf "%s\n" "${*:2}"; fi; }
say(){ printf "%s\n" "$*"; }
info(){ _print_c "$FX_BLU" "$*"; }
ok(){   _print_c "$FX_GRN" "$*"; }
warn(){ _print_c "$FX_YEL" "$*"; }
err(){  [ "$COLOR_ON" -eq 1 ] && printf "\033[31m%s\033[0m\n" "$*" >&2 || printf "%s\n" "$*" >&2; }
reset_line(){ [ "$COLOR_ON" -eq 1 ] && printf "\033[0m" || true; }

# -------------------- lib/logfx.sh --------------------
LOGFX_LIB="$HOME/code/bin/shellscripts/lib/logfx.sh"
[ -r "$LOGFX_LIB" ] || { err "Fehlt: $LOGFX_LIB"; exit 2; }
# shellcheck source=/dev/null
. "$LOGFX_LIB"
[ "$DRY" -eq 1 ] && export DRY_RUN="yes" || export DRY_RUN=""
[ "$NO_COLOR" -eq 1 ] && export NO_COLOR="1" || export NO_COLOR=""
export LOG_LEVEL="$DEBUG_MODE"   # Standard wieder trace
logfx_init "$SCRIPT_ID" "$LOG_LEVEL"

# -------------------- Gatekeeper --------------------
gatekeeper(){
  local pwd; pwd="$(pwd -P)"
  if [ "$pwd" = "$HOME/code/bin" ]; then
    [ -d .git ] || { err "Gatekeeper: ~/code/bin ohne .git"; exit 2; }
    printf '%s' "bin"; return 0
  fi
  if [ -f ".env" ] && grep -qE '^\s*PROJ_NAME=' ".env"; then printf '%s' "project"; return 0; fi
  err "Gatekeeper: In ~/code/bin (mit .git) ODER Projekt-Root (.env mit PROJ_NAME) starten."; exit 2
}
MODE="$(gatekeeper)"

# -------------------- Git-Kontext --------------------
need(){ command -v "$1" >/dev/null 2>&1 || { err "Benötigt: $1"; exit 1; }; }
need git
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"; [ -n "$REPO_ROOT" ] || { err "Kein Git-Repo"; exit 1; }
cd "$REPO_ROOT"
ORIGIN_URL="$(git config --get remote.origin.url || true)"; [ -n "$ORIGIN_URL" ] || { err "Kein origin"; exit 1; }
STATUS_PORC="$(git status --porcelain)"; WT_DIRTY=0; [ -n "$STATUS_PORC" ] && WT_DIRTY=1
DEFAULT_BRANCH="$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||' || true)"; [ -n "$DEFAULT_BRANCH" ] || DEFAULT_BRANCH="main"

# -------------------- Eingaben prüfen --------------------
[ -n "$FEATURE_NAME" ] && [ -n "$TICKET_ID" ] || { err "Fehlt: --name und --ticket"; exit 2; }
norm(){ echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g; s/-+/-/g'; }
NAME_N="$(norm "$FEATURE_NAME")"; TICK_N="$(norm "$TICKET_ID")"
NEW_BRANCH="feat/${TICK_N}-${NAME_N}"
BR_EXISTS_LOCAL=0; git show-ref --verify --quiet "refs/heads/${NEW_BRANCH}" && BR_EXISTS_LOCAL=1 || true
BR_EXISTS_REMOTE=0; git ls-remote --heads origin "${NEW_BRANCH}" | grep -qE "refs/heads/${NEW_BRANCH}$" && BR_EXISTS_REMOTE=1 || true

# -------------------- PLAN --------------------
info "PLAN  Mode: ${MODE}  Base: ${DEFAULT_BRANCH}  → New: ${NEW_BRANCH}"; reset_line
[ "$WT_DIRTY" -eq 1 ] && { say " - WT: nicht sauber (use --allow-dirty, falls ok)"; reset_line; }
say " - Remote: origin ${ORIGIN_URL}"; reset_line
say " - Ticket: ${TICK_N}"; reset_line
[ "$BR_EXISTS_LOCAL" -eq 1 ] || [ "$BR_EXISTS_REMOTE" -eq 1 ] && { say " - Branch existiert bereits (local:${BR_EXISTS_LOCAL} remote:${BR_EXISTS_REMOTE})"; reset_line; }
[ "$AUTO_PUSH" -eq 1 ] && say " - Aktion: create + push -u origin ${NEW_BRANCH}" || say " - Aktion: create (kein Push)"; reset_line
[ -n "${DRY_RUN:-}" ] && { say "DRY-RUN: es wird nichts geändert."; reset_line; [ "$BR_EXISTS_LOCAL" -eq 1 ] || [ "$BR_EXISTS_REMOTE" -eq 1 ] && { warn "Abbruch: Branch existiert bereits (nutze --reuse)"; reset_line; }; }

# -------------------- Execute / Dry-Run --------------------
if [ -n "${DRY_RUN:-}" ]; then
  SUMMARY_STATUS="plan"
else
  if [ "$ASSUME_YES" -ne 1 ]; then
    [ "$COLOR_ON" -eq 1 ] && printf "\033[1mFortfahren?\033[0m [y/N] " || printf "Fortfahren? [y/N] "
    read -r yn || true; case "${yn:-N}" in y|Y|yes|YES) ;; *) say "Abgebrochen."; exit 0 ;; esac
  fi
  [ "$WT_DIRTY" -eq 1 ] && [ "$ALLOW_DIRTY" -ne 1 ] && { warn "Working Tree nicht sauber. Nutze --allow-dirty."; reset_line; exit 1; }
  if [ "$BR_EXISTS_LOCAL" -eq 1 ] || [ "$BR_EXISTS_REMOTE" -eq 1 ]; then
    if [ "$REUSE" -eq 1 ]; then
      logfx_run "fetch-prune" -- git fetch --all --prune
      logfx_run "switch-existing" -- git switch "${NEW_BRANCH}" || logfx_run "checkout-existing" -- git checkout "${NEW_BRANCH}"
      ok "Checked out ${NEW_BRANCH}."; reset_line
      SUMMARY_STATUS="reused"
    else
      warn "Abbruch: Branch existiert bereits (nutze --reuse)."; reset_line; exit 1
    fi
  else
    logfx_run "fetch-base" -- git fetch origin "${DEFAULT_BRANCH}":"refs/remotes/origin/${DEFAULT_BRANCH}"
    logfx_run "switch-create" -- git switch -c "${NEW_BRANCH}" "origin/${DEFAULT_BRANCH}" || logfx_run "checkout-create" -- git checkout -b "${NEW_BRANCH}" "origin/${DEFAULT_BRANCH}"
    ok "Branch ${NEW_BRANCH} erstellt."; reset_line
    SUMMARY_STATUS="created"
    [ "$AUTO_PUSH" -eq 1 ] && logfx_run "push-upstream" -- git push -u origin "${NEW_BRANCH}"
  fi
fi

# -------------------- Audit-Logging (append, ohne Lock) -----------------------
REPO_NAME="$(basename "$REPO_ROOT")"
YEAR="$(date +%Y)"; MONTH="$(date +%Y-%m)"
AUDIT_DIR="$HOME/code/bin/shellscripts/audits/${SCRIPT_ID}/${REPO_NAME}/${YEAR}"
mkdir -p "$AUDIT_DIR"
AUDIT_FILE="$AUDIT_DIR/${MONTH}.jsonl"

json_esc(){ local s="${1//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"; printf '%s' "$s"; }
TS_ISO="$(date +"%Y-%m-%dT%H:%M:%S%z")"
: "${SUMMARY_STATUS:=plan}"

AUDIT_JSON=$(cat <<EOF
{"ts":"$(json_esc "$TS_ISO")","script":"$SCRIPT_ID","version":"$SCRIPT_VERSION","repo":"$(json_esc "$REPO_NAME")","repo_path":"$(json_esc "$REPO_ROOT")","origin":"$(json_esc "$ORIGIN_URL")","base":"$(json_esc "$DEFAULT_BRANCH")","new_branch":"$(json_esc "$NEW_BRANCH")","mode":"$(json_esc "$MODE")","name":"$(json_esc "$FEATURE_NAME")","ticket":"$(json_esc "$TICK_N")","status":"$(json_esc "$SUMMARY_STATUS")","wt_dirty":$WT_DIRTY,"auto_push":$AUTO_PUSH,"reuse":$REUSE,"dry_run":"$( [ -n "${DRY_RUN:-}" ] && echo yes || echo no )","debug_level":"$(json_esc "$DEBUG_MODE")"}
EOF
)

# Anhängen; danach sync/touch für sofortige Editor-Aktualisierung
: >>"$AUDIT_FILE"
printf "%s\n" "$AUDIT_JSON" >>"$AUDIT_FILE"
if sync -f "$AUDIT_FILE" 2>/dev/null; then :; else sync >/dev/null 2>&1 || true; fi
touch -c -m "$AUDIT_FILE" || true

# -------------------- Ausgabe --------------------
if [ "$SUMMARY_ONLY" -eq 0 ]; then
  ok "Fertig: ${SUMMARY_STATUS} → ${NEW_BRANCH}"; reset_line
  say "Audit: \`$AUDIT_FILE\` (append)"
fi
[ "$DO_JSON" -eq 1 ] && printf "%s\n" "$AUDIT_JSON"

exit 0
