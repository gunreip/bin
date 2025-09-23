#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# git-branch-rm — Branches gezielt/listen/alle löschen (lokal/remote) mit Plan,
# Backups (tag,bundle) und Audit-Log (append; period=month|day)
# Version: v0.4.1
# -----------------------------------------------------------------------------
set -euo pipefail
IFS=$'\n\t'

# >>> LOGFX INIT (deferred) >>>
: "${LOG_LEVEL:=trace}"      # off|dbg|trace|xtrace
: "${DRY_RUN:=}"             # ""|yes
# shellcheck source=/dev/null
. "$HOME/code/bin/shellscripts/lib/logfx.sh"
# <<< LOGFX INIT <<<

SCRIPT_ID="git-branch-rm"
SCRIPT_VERSION="v0.4.1"

# --- Defaults & Dirs ----------------------------------------------------------
NO_COLOR_FORCE="no"
ASSUME_YES="no"; NO_INPUT="no"
REMOTE_NAME="origin"
DO_LIST="no"; DO_SELECT="no"
ALL_LOCAL="no"; ALL_REMOTE="no"; ALL_BOTH="no"
ALLOW_REMOTE_DELETE="no"; FORCE_LOCAL="no"
MATCH_RE=""; EXCEPT_CSV=""; BRANCHES_CSV=""; PROTECT_ADD_CSV=""
NO_PROTECT="no"; REFRESH_REMOTE="yes"
BACKUP_SPEC="tag,bundle"; AUDIT_MODE="on"; REASON=""
ONLY_MERGED_TO="main"; MERGED_CHECK="yes"; MIN_AGE_DAYS=7
AUDIT_PERIOD="month"   # month|day

BACKUP_ROOT="${HOME}/code/bin/shellscripts/backups/branches"
AUDIT_ROOT="${HOME}/code/bin/shellscripts/audits/${SCRIPT_ID}"

# --- Farben -------------------------------------------------------------------
BOLD=""; YEL=""; GRN=""; RED=""; BLU=""; RST=""
color_init(){
  if [ "$NO_COLOR_FORCE" = "yes" ] || [ -n "${NO_COLOR:-}" ] || [ ! -t 1 ]; then
    BOLD=""; YEL=""; GRN=""; RED=""; BLU=""; RST=""
  else
    BOLD=$'\033[1m'; YEL=$'\033[33m'; GRN=$'\033[32m'; RED=$'\033[31m'; BLU=$'\033[34m'; RST=$'\033[0m'
  fi
}

# --- Usage --------------------------------------------------------------------
usage(){ cat <<HLP
$SCRIPT_ID $SCRIPT_VERSION

Usage:
  git-branch-rm [--list] [--select] [--branches=a,b] [--all-local|--all-remote|--all]
                [--match=<regex>] [--except=a,b] [--protect-add=a,b] [--no-protect]
                [--remote-name=origin] [--allow-remote-delete]
                [--force] [--yes|-y] [--no-input]
                [--dry-run] [--no-color] [--debug=dbg|trace|xtrace] [--no-refresh]
                [--backup=none|tag|bundle|tag,bundle] [--audit=on|off] [--audit-period=day|month]
                [--reason="Text"] [--only-merged-to=<branch>|--no-merged-check]
                [--min-age-days=N]
HLP
}

# --- Args ---------------------------------------------------------------------
for arg in "$@"; do
  case "$arg" in
    --help) usage; exit 0 ;;
    --version) echo "$SCRIPT_ID $SCRIPT_VERSION"; exit 0 ;;
    --dry-run) DRY_RUN="yes" ;;
    --debug=dbg)    LOG_LEVEL="dbg" ;;
    --debug=trace)  LOG_LEVEL="trace" ;;
    --debug=xtrace) LOG_LEVEL="xtrace" ;;
    --no-color) NO_COLOR_FORCE="yes" ;;
    --yes|-y) ASSUME_YES="yes" ;;
    --no-input) NO_INPUT="no" ;; # Eingabe wird dennoch für --select benötigt; "no" = interaktiv erlaubt
    --list) DO_LIST="yes" ;;
    --select) DO_SELECT="yes" ;;
    --all-local) ALL_LOCAL="yes" ;;
    --all-remote) ALL_REMOTE="yes" ;;
    --all) ALL_BOTH="yes" ;;
    --allow-remote-delete) ALLOW_REMOTE_DELETE="yes" ;;
    --force) FORCE_LOCAL="yes" ;;
    --remote-name=*) REMOTE_NAME="${arg#*=}" ;;
    --branches=*) BRANCHES_CSV="${arg#*=}" ;;
    --match=*) MATCH_RE="${arg#*=}" ;;
    --except=*) EXCEPT_CSV="${arg#*=}" ;;
    --protect-add=*) PROTECT_ADD_CSV="${arg#*=}" ;;
    --no-protect) NO_PROTECT="yes" ;;
    --no-refresh) REFRESH_REMOTE="no" ;;
    --backup=*) BACKUP_SPEC="${arg#*=}" ;;
    --audit=*) AUDIT_MODE="${arg#*=}" ;;
    --audit-period=*) AUDIT_PERIOD="${arg#*=}" ;;
    --reason=*) REASON="${arg#*=}" ;;
    --only-merged-to=*) ONLY_MERGED_TO="${arg#*=}"; MERGED_CHECK="yes" ;;
    --no-merged-check) MERGED_CHECK="no" ;;
    --min-age-days=*) MIN_AGE_DAYS="${arg#*=}" ;;
    --project=*) : ;;
    *) echo "Unbekannte Option: $arg"; echo "Nutze --help"; exit 3 ;;
  esac
done

color_init
logfx_init "$SCRIPT_ID" "$LOG_LEVEL"
[ "$LOG_LEVEL" = "xtrace" ] && logfx_xtrace_on || true

S_args="$(logfx_scope_begin "parse-args")"
logfx_var "dry_run" "${DRY_RUN:-}" "remote" "$REMOTE_NAME" "list" "$DO_LIST" "select" "$DO_SELECT" \
         "all_local" "$ALL_LOCAL" "all_remote" "$ALL_REMOTE" "all" "$ALL_BOTH" \
         "match" "$MATCH_RE" "except" "$EXCEPT_CSV" "protect_add" "$PROTECT_ADD_CSV" "no_protect" "$NO_PROTECT" \
         "refresh_remote" "$REFRESH_REMOTE" "backup" "$BACKUP_SPEC" "audit" "$AUDIT_MODE" "audit_period" "$AUDIT_PERIOD" \
         "reason" "$REASON" "only_merged_to" "$ONLY_MERGED_TO" "merged_check" "$MERGED_CHECK" "min_age_days" "$MIN_AGE_DAYS"
logfx_scope_end "$S_args" "ok"

# --- Gatekeeper / Kontext -----------------------------------------------------
S_ctx="$(logfx_scope_begin "context-detect")"
BIN_PATH="$HOME/code/bin"
PWD_P="$(pwd -P)"
MODE="unknown"; REPO_ROOT=""

command -v git >/dev/null 2>&1 || { echo "Fehler: git fehlt"; logfx_event "dependency" "missing" "git"; exit 4; }

# /bin hat Vorrang, dann allgemeines Repo
if [ "$PWD_P" = "$BIN_PATH" ]; then
  MODE="bin"
  if [ ! -d "$BIN_PATH/.git" ]; then
    msg="${BIN_PATH} - Ist noch kein Git-Repo (git-init fehlt, oder in <project> ausführen)"
    [ -n "$BOLD" ] && printf "%sGatekeeper:%s %s%s%s\n" "$YEL$BOLD" "$RST" "$RED" "$msg" "$RST" || echo "Gatekeeper: $msg"
    logfx_event "gatekeeper" "reason" "bin-no-git" "pwd" "$PWD_P"
    [ -n "${DRY_RUN:-}" ] && exit 0 || exit 2
  fi
  REPO_ROOT="$BIN_PATH"
else
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    MODE="project"; REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  else
    [ -n "$BOLD" ] && printf "%sGatekeeper:%s Kein Git-Repo.\n" "$YEL$BOLD" "$RST" || echo "Gatekeeper: Kein Git-Repo."
    logfx_event "gatekeeper" "reason" "no-repo" "pwd" "$PWD_P"; exit 2
  fi
fi

# Aus Repo-Wurzel ausführen
if [ "$PWD_P" != "$REPO_ROOT" ]; then
  msg="Bitte aus Repo-Wurzel starten: $REPO_ROOT"
  [ -n "$BOLD" ] && printf "%sGatekeeper:%s %s\n" "$YEL$BOLD" "$RST" "$msg" || echo "Gatekeeper: $msg"
  logfx_event "gatekeeper" "reason" "not-root" "repo_root" "$REPO_ROOT" "pwd" "$PWD_P"
  exit 2
fi
# .env nur im Projektmodus relevant (hier kein harter Check)
logfx_var "mode" "$MODE" "repo_root" "$REPO_ROOT"
if command -v git-ctx >/dev/null 2>&1; then git-ctx ${NO_COLOR_FORCE:+--no-color} || true; fi
logfx_scope_end "$S_ctx" "ok"

# --- Repo-Slug & Audit/Backup-Ziele ------------------------------------------
repo_slug(){
  if git remote get-url "$REMOTE_NAME" >/dev/null 2>&1; then
    u="$(git remote get-url "$REMOTE_NAME" 2>/dev/null || true)"
    base="${u##*/}"; base="${base##*:}"; base="${base%.git}"
    printf "%s\n" "$base"
  else
    basename "$REPO_ROOT"
  fi
}
REPO_SLUG="$(repo_slug)"
AUD_DIR="${AUDIT_ROOT}/${REPO_SLUG}"
mkdir -p "$AUD_DIR"

case "$AUDIT_PERIOD" in
  day)   AUD_FILE="${AUD_DIR}/deletions.$(date +%Y%m%d).jsonl" ;;
  month) AUD_FILE="${AUD_DIR}/deletions.$(date +%Y-%m).jsonl" ;;
  *)     AUD_FILE="${AUD_DIR}/deletions.$(date +%Y-%m).jsonl" ;;
esac

# --- Optionales Refresh der Remote-Refs --------------------------------------
if [ "$REFRESH_REMOTE" = "yes" ]; then
  logfx_run "fetch-prune" -- git fetch "$REMOTE_NAME" --prune --quiet || true
fi

# --- Helpers ------------------------------------------------------------------
ask_yn(){ local q="$1"
  if [ "$ASSUME_YES" = "yes" ] || [ "$NO_INPUT" = "yes" ]; then echo "y"; return 0; fi
  printf "%s [y/N]: " "$q" >&2; read -r ans || true
  case "${ans,,}" in y|yes) echo "y";; *) echo "n";; esac; }
csv_to_lines(){ tr ',' '\n' <<<"$1" | sed '/^$/d'; }
count_file(){ [ -s "$1" ] && wc -l < "$1" | tr -d ' ' || echo 0; }
now_ts(){ date +%Y%m%d-%H%M%S; }

# --- Branch-Listen sammeln ----------------------------------------------------
TMPDIR="$(mktemp -d)"; trap 'rm -rf "$TMPDIR"' EXIT
LOCAL_ALL="$TMPDIR/local_all.txt"
REMOTE_ALL="$TMPDIR/remote_all.txt"

logfx_run "list-local-heads" -- git for-each-ref --format='%(refname:short)' refs/heads/ \
  | sort > "$LOCAL_ALL"
logfx_run "list-remote-heads" -- bash -c "git for-each-ref --format='%(refname:short)' 'refs/remotes/$REMOTE_NAME/' 2>/dev/null \
  | sed -e 's#^$REMOTE_NAME/##' | grep -v '^HEAD$' | sort" > "$REMOTE_ALL" || true

# --- Filter anwenden ----------------------------------------------------------
apply_match_except(){ local IN="$1"; local OUT="$2"; local T="$TMPDIR/_t.$$"
  cp "$IN" "$T"
  if [ -n "$MATCH_RE" ]; then grep -E "$MATCH_RE" "$T" > "$OUT" || true; else cp "$T" "$OUT"; fi
  if [ -n "$EXCEPT_CSV" ]; then local EX="$TMPDIR/except.txt"; csv_to_lines "$EXCEPT_CSV" > "$EX"
    grep -x -v -f "$EX" "$OUT" > "$T" || true; mv "$T" "$OUT"; fi; }

LOCAL_CAND="$TMPDIR/local_cand.txt"; REMOTE_CAND="$TMPDIR/remote_cand.txt"
apply_match_except "$LOCAL_ALL" "$LOCAL_CAND"
apply_match_except "$REMOTE_ALL" "$REMOTE_CAND"

# --- Protected-Set ------------------------------------------------------------
current_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
PROT="$TMPDIR/protected.txt"; : > "$PROT"
if [ "$NO_PROTECT" = "no" ]; then
  printf "%s\n" "main" "master" >> "$PROT"
  [ -n "$current_branch" ] && printf "%s\n" "$current_branch" >> "$PROT"
  [ -n "$PROTECT_ADD_CSV" ] && csv_to_lines "$PROTECT_ADD_CSV" >> "$PROT"
  sort -u "$PROT" -o "$PROT"
fi

# --- Nur Liste? --------------------------------------------------------------
if [ "$DO_LIST" = "yes" ]; then
  LCNT="$(count_file "$LOCAL_CAND")"; RCNT="$(count_file "$REMOTE_CAND")"
  echo "Lokale Branches ($LCNT):"
  if [ "$LCNT" -gt 0 ]; then
    while IFS= read -r b; do
      mark=""; if [ "$NO_PROTECT" = "no" ] && grep -x -q "$b" "$PROT"; then mark=" (PROTECTED)"; fi
      printf "  - %s%s\n" "$b" "$mark"
    done < "$LOCAL_CAND"
  fi
  echo "Remote Branches ($REMOTE_NAME) ($RCNT):"
  if [ "$RCNT" -gt 0 ]; then
    while IFS= read -r b; do printf "  - %s/%s\n" "$REMOTE_NAME" "$b"; done < "$REMOTE_CAND"
  fi
  exit 0
fi

# --- Auswahl zusammenstellen --------------------------------------------------
SEL_LOCAL="$TMPDIR/sel_local.txt"; SEL_REMOTE="$TMPDIR/sel_remote.txt"; : > "$SEL_LOCAL"; : > "$SEL_REMOTE"

# --branches
if [ -n "$BRANCHES_CSV" ]; then
  csv_to_lines "$BRANCHES_CSV" | while IFS= read -r b; do
    [ -z "$b" ] && continue
    case "$b" in "$REMOTE_NAME"/*|origin/*) printf "%s\n" "${b#*/}" >> "$SEL_REMOTE" ;; *) printf "%s\n" "$b" >> "$SEL_LOCAL" ;; esac
  done
fi

# --all flags
[ "$ALL_BOTH" = "yes" ] || [ "$ALL_LOCAL" = "yes" ] && cat "$LOCAL_CAND" >> "$SEL_LOCAL"
[ "$ALL_BOTH" = "yes" ] || [ "$ALL_REMOTE" = "yes" ] && cat "$REMOTE_CAND" >> "$SEL_REMOTE"

# --select interaktiv
if [ "$DO_SELECT" = "yes" ] && [ ! -s "$SEL_LOCAL" ] && [ ! -s "$SEL_REMOTE" ]; then
  echo "Lokale Branches:"; awk '{print "  - "$0}' "$LOCAL_CAND"
  echo "Remote Branches ($REMOTE_NAME):"; awk -v r="$REMOTE_NAME" '{print "  - " r "/" $0}' "$REMOTE_CAND"
  if [ "$NO_INPUT" = "yes" ]; then echo "Abbruch: --no-input aktiv, aber --select erfordert Eingabe."; exit 0; fi
  printf "Welche LOKALEN Branches löschen? (Namen, Leerzeichen-getrennt, * = alle, leer = keine): "; read -r inloc || true
  [ "${inloc:-}" = "*" ] && cat "$LOCAL_CAND" >> "$SEL_LOCAL" || { [ -n "${inloc:-}" ] && for w in $inloc; do echo "$w"; done >> "$SEL_LOCAL"; }
  printf "Welche REMOTE Branches löschen? (Namen OHNE '%s/'-Prefix, * = alle, leer = keine): " "$REMOTE_NAME"; read -r inrem || true
  [ "${inrem:-}" = "*" ] && cat "$REMOTE_CAND" >> "$SEL_REMOTE" || { [ -n "${inrem:-}" ] && for w in $inrem; do echo "$w"; done >> "$SEL_REMOTE"; }
fi

# Dedupe + Existenzprüfung
dedupe_exist(){ local S="$1"; local C="$2"; local O="$TMPDIR/out.$$"; sort -u "$S" | sed '/^$/d' > "$S.u"
  grep -x -F -f "$S.u" "$C" > "$O" || true; mv "$O" "$S"; }
[ -s "$SEL_LOCAL" ]  && dedupe_exist "$SEL_LOCAL" "$LOCAL_CAND"
[ -s "$SEL_REMOTE" ] && dedupe_exist "$SEL_REMOTE" "$REMOTE_CAND"

# Protected lokal rausfiltern
if [ "$NO_PROTECT" = "no" ] && [ -s "$SEL_LOCAL" ]; then
  grep -x -v -f "$PROT" "$SEL_LOCAL" > "$SEL_LOCAL.tmp" || true; mv "$SEL_LOCAL.tmp" "$SEL_LOCAL"
fi

# --- Constraints (merge + age) -----------------------------------------------
TARGET_LOCAL_REF="refs/heads/${ONLY_MERGED_TO}"
TARGET_REMOTE_REF="refs/remotes/${REMOTE_NAME}/${ONLY_MERGED_TO}"

is_merged(){ git merge-base --is-ancestor "$1" "$2" >/dev/null 2>&1; } # $1 from, $2 to
age_days_of_ref(){ local ct; ct="$(git log -1 --format=%ct "$1" 2>/dev/null || echo 0)"
  [ "$ct" -eq 0 ] && { echo 999999; return 0; }
  local now; now="$(date +%s)"; echo $(( (now - ct) / 86400 )); }

OK_LOCAL="$TMPDIR/ok_local.txt"; SKIP_LOCAL="$TMPDIR/skip_local.txt"; : > "$OK_LOCAL"; : > "$SKIP_LOCAL"
if [ -s "$SEL_LOCAL" ]; then
  while IFS= read -r b; do
    [ -z "$b" ] && continue
    ref="refs/heads/$b"; target=""
    if [ "$MERGED_CHECK" = "yes" ]; then
      if   git show-ref --quiet "$TARGET_LOCAL_REF"; then target="$TARGET_LOCAL_REF"
      elif git show-ref --quiet "$TARGET_REMOTE_REF"; then target="$TARGET_REMOTE_REF"
      else target=""; fi
      if [ -z "$target" ]; then echo "$b  SKIP (kein Ziel für Merge-Check: ${ONLY_MERGED_TO})" >> "$SKIP_LOCAL"; continue; fi
      is_merged "$ref" "$target" || { echo "$b  SKIP (nicht in ${ONLY_MERGED_TO} gemerged)" >> "$SKIP_LOCAL"; continue; }
    fi
    ad="$(age_days_of_ref "$ref")"
    [ "$ad" -lt "$MIN_AGE_DAYS" ] && { echo "$b  SKIP (zu jung: ${ad}d < ${MIN_AGE_DAYS}d)" >> "$SKIP_LOCAL"; continue; }
    echo "$b" >> "$OK_LOCAL"
  done < "$SEL_LOCAL"
fi

OK_REMOTE="$TMPDIR/ok_remote.txt"; SKIP_REMOTE="$TMPDIR/skip_remote.txt"; : > "$OK_REMOTE"; : > "$SKIP_REMOTE"
if [ -s "$SEL_REMOTE" ]; then
  while IFS= read -r b; do
    [ -z "$b" ] && continue
    ref="refs/remotes/${REMOTE_NAME}/$b"; target=""
    if [ "$MERGED_CHECK" = "yes" ]; then
      if   git show-ref --quiet "$TARGET_REMOTE_REF"; then target="$TARGET_REMOTE_REF"
      elif git show-ref --quiet "$TARGET_LOCAL_REF"; then target="$TARGET_LOCAL_REF"
      else target=""; fi
      if [ -z "$target" ]; then echo "$b  SKIP (kein Ziel für Merge-Check: ${ONLY_MERGED_TO})" >> "$SKIP_REMOTE"; continue; fi
      is_merged "$ref" "$target" || { echo "$b  SKIP (nicht in ${ONLY_MERGED_TO} gemerged)" >> "$SKIP_REMOTE"; continue; }
    fi
    ad="$(age_days_of_ref "$ref")"
    [ "$ad" -lt "$MIN_AGE_DAYS" ] && { echo "$b  SKIP (zu jung: ${ad}d < ${MIN_AGE_DAYS}d)" >> "$SKIP_REMOTE"; continue; }
    echo "$b" >> "$OK_REMOTE"
  done < "$SEL_REMOTE"
fi

# --- Plan ---------------------------------------------------------------------
LCNT="$(count_file "$OK_LOCAL")"; RCNT="$(count_file "$OK_REMOTE")"
echo "PLAN:"
printf "  Lokal  zu löschen: %s\n" "$LCNT"; [ "$LCNT" -gt 0 ] && awk '{print "    · "$0}' "$OK_LOCAL"
printf "  Remote zu löschen (remote=%s): %s\n" "$REMOTE_NAME" "$RCNT"; [ "$RCNT" -gt 0 ] && awk -v r="$REMOTE_NAME" '{print "    · " r "/" $0}' "$OK_REMOTE"

if [ -s "$SKIP_LOCAL" ] || [ -s "$SKIP_REMOTE" ]; then
  echo "  Übersprungen (Schutzregeln):"
  [ -s "$SKIP_LOCAL" ]  && awk '{print "    · local  "$0}' "$SKIP_LOCAL"
  [ -s "$SKIP_REMOTE" ] && awk '{print "    · remote "$0}' "$SKIP_REMOTE"
fi

# Audit/Backup-Ziele anzeigen
[ "$AUDIT_MODE" = "on" ] && echo "AUDIT: ${AUD_FILE}"
if [ "$BACKUP_SPEC" != "none" ]; then
  echo "BACKUP: Bundle-Ziel=${BACKUP_ROOT}/${REPO_SLUG}/  Tag-Prefix=backup/<branch>/<ts>"
fi
[ "$RCNT" -gt 0 ] && [ "$ALLOW_REMOTE_DELETE" != "yes" ] && echo "  Hinweis: Remote-Löschen erfordert --allow-remote-delete"

# Dry-run?
if [ -n "${DRY_RUN:-}" ]; then
  echo "Abbruch: Modus (dry-run)."
  exit 0
fi

# Nichts zu tun?
[ "$LCNT" -eq 0 ] && [ "$RCNT" -eq 0 ] && { echo "Nichts zu löschen."; exit 0; }

# Reason prüfen + Confirm
[ -z "$REASON" ] && { echo "Abbruch: --reason ist erforderlich für destruktive Läufe."; exit 2; }
if [ "$(ask_yn "Fortfahren?")" != "y" ]; then echo "Abbruch: Benutzer."; exit 0; fi

# --- Backup-Auswahl -----------------------------------------------------------
DO_BKP_TAG="no"; DO_BKP_BUNDLE="no"
case "$BACKUP_SPEC" in
  none|"") : ;;
  tag) DO_BKP_TAG="yes" ;;
  bundle) DO_BKP_BUNDLE="yes" ;;
  tag,bundle|bundle,tag) DO_BKP_TAG="yes"; DO_BKP_BUNDLE="yes" ;;
  *) echo "Unbekannter --backup-Wert: $BACKUP_SPEC"; exit 3 ;;
esac

# --- Audit Writer -------------------------------------------------------------
G_USER="$(git config --get user.name 2>/dev/null || echo "")"
G_MAIL="$(git config --get user.email 2>/dev/null || echo "")"
HOSTN="$(hostname 2>/dev/null || echo "")"
touch "$AUD_FILE" 2>/dev/null || true

tsu(){ date -u +"%Y-%m-%dT%H:%M:%SZ"; }

audit_write(){
  # args: side local|remote, branch, sha, tag, bundle, rc, extra_json
  local side="$1" b="$2" sha="$3" tag="$4" bun="$5" rc="$6" extra="$7"
  [ "$AUDIT_MODE" = "on" ] || return 0
  if command -v jq >/dev/null 2>&1; then
    printf '{"ts":"%s","repo":"%s","side":"%s","branch":"%s","sha":"%s","reason":%s,"backup_tag":%s,"backup_bundle":%s,"user":"%s","email":"%s","host":"%s","rc":%s%s}\n' \
      "$(tsu)" "$REPO_SLUG" "$side" "$b" "$sha" \
      "$(printf '%s' "$REASON" | jq -Rs '.')" \
      "$( [ -n "$tag" ] && printf '%s' "$tag" | jq -Rs '.' || echo null )" \
      "$( [ -n "$bun" ] && printf '%s' "$bun" | jq -Rs '.' || echo null )" \
      "$(printf '%s' "$G_USER" | sed 's/"/\\"/g')" \
      "$(printf '%s' "$G_MAIL" | sed 's/"/\\"/g')" \
      "$(printf '%s' "$HOSTN" | sed 's/"/\\"/g')" \
      "$rc" \
      "$( [ -n "$extra" ] && printf ',%s' "$extra" || echo '' )" \
    >> "$AUD_FILE" || true
  else
    printf '{"ts":"%s","repo":"%s","side":"%s","branch":"%s","sha":"%s","reason":"%s","backup_tag":"%s","backup_bundle":"%s","user":"%s","email":"%s","host":"%s","rc":%s%s}\n' \
      "$(tsu)" "$REPO_SLUG" "$side" "$b" "$sha" "$REASON" "$tag" "$bun" "$G_USER" "$G_MAIL" "$HOSTN" "$rc" \
      "$( [ -n "$extra" ] && printf ',%s' "$extra" || echo '' )" \
    >> "$AUD_FILE" || true
  fi
}

# --- Backup-Helfer ------------------------------------------------------------
backup_tag(){ # $1 branch, $2 ref
  [ "$DO_BKP_TAG" = "yes" ] || { echo ""; return 0; }
  local b="$1" ref="$2" ts tag; ts="$(now_ts)"; tag="backup/${b}/${ts}"
  set +e
  git tag -a "$tag" "$ref" -m "Backup before deletion ($b @ $ts)" >/dev/null 2>&1
  rc=$?
  set -e
  if [ $rc -eq 0 ] && git remote get-url "$REMOTE_NAME" >/dev/null 2>&1; then
    git push "$REMOTE_NAME" "refs/tags/$tag" >/dev/null 2>&1 || true
  fi
  echo "$tag"
}
backup_bundle(){ # $1 branch, $2 ref
  [ "$DO_BKP_BUNDLE" = "yes" ] || { echo ""; return 0; }
  local b="$1" ref="$2" ts outdir out; ts="$(now_ts)"; outdir="${BACKUP_ROOT}/${REPO_SLUG}"
  mkdir -p "$outdir"; out="${outdir}/${b}.${ts}.bundle"
  set +e
  git bundle create "$out" "$ref" >/dev/null 2>&1
  rc=$?
  set -e
  [ $rc -eq 0 ] && echo "$out" || echo ""
}

# --- Ausführung ---------------------------------------------------------------
rc_total=0

# Lokal löschen
if [ "$LCNT" -gt 0 ]; then
  while IFS= read -r b; do
    [ -z "$b" ] && continue
    ref="refs/heads/$b"; sha="$(git rev-parse "$ref" 2>/dev/null || echo "")"
    t="$(backup_tag "$b" "$ref" || true)"; bun="$(backup_bundle "$b" "$ref" || true)"
    if [ "$FORCE_LOCAL" = "yes" ]; then
      logfx_run "branch-del-local" -- git branch -D "$b" || rc=$?
    else
      logfx_run "branch-del-local" -- git branch -d "$b" || rc=$?
    fi
    rc="${rc:-0}"; [ "$rc" -ne 0 ] && { echo "Fehler: local '$b' rc=$rc"; rc_total=$rc; }
    audit_write "local" "$b" "$sha" "$t" "$bun" "$rc" ""
    unset rc
  done < "$OK_LOCAL"
fi

# Remote löschen
if [ "$RCNT" -gt 0 ] && [ "$ALLOW_REMOTE_DELETE" = "yes" ]; then
  while IFS= read -r b; do
    [ -z "$b" ] && continue
    ref="refs/remotes/${REMOTE_NAME}/${b}"; sha="$(git rev-parse "$ref" 2>/dev/null || echo "")"
    t="$(backup_tag "$b" "$ref" || true)"; bun="$(backup_bundle "$b" "$ref" || true)"
    logfx_run "branch-del-remote" -- git push "$REMOTE_NAME" --delete "$b" || rc=$?
    rc="${rc:-0}"; [ "$rc" -ne 0 ] && { echo "Fehler: remote '$REMOTE_NAME/$b' rc=$rc"; rc_total=$rc; }
    audit_write "remote" "$b" "$sha" "$t" "$bun" "$rc" ""
    unset rc
  done < "$OK_REMOTE"
fi

# Aufräumen und Summary
logfx_run "prune-remote" -- git remote prune "$REMOTE_NAME" >/dev/null 2>&1 || true
[ $rc_total -eq 0 ] && echo "Fertig." || echo "Fertig mit Fehlern (rc=$rc_total)."
[ "$AUDIT_MODE" = "on" ] && echo "AUDIT: ${AUD_FILE}"
[ "$DO_BKP_BUNDLE" = "yes" ] && echo "Hinweis: Bundle-Backups unter ${BACKUP_ROOT}/${REPO_SLUG}/"
exit $rc_total
