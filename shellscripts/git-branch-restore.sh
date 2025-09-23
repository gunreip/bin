#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# git-branch-restore — stellt gelöschte Branches anhand der Audits von
#                      git-branch-rm wieder her (aus Tag, Bundle, oder Remote-Fallback).
# Version: v0.2.2
# -----------------------------------------------------------------------------
set -euo pipefail
IFS=$'\n\t'

: "${LOG_LEVEL:=trace}"      # off|dbg|trace|xtrace
: "${DRY_RUN:=}"             # ""|yes
# shellcheck source=/dev/null
. "$HOME/code/bin/shellscripts/lib/logfx.sh"

SCRIPT_ID="git-branch-restore"
SCRIPT_VERSION="v0.2.2"

NO_COLOR_FORCE="no"
REMOTE="origin"
BRANCHES_CSV=""
FROM="auto"          # auto|tag|bundle
WHEN="latest"        # latest|YYYY-MM
DO_LIST="no"
DO_PUSH="no"
SET_UPSTREAM="auto"  # auto|yes|no
FORCE="no"
LIMIT=200

usage(){
  cat <<H
$SCRIPT_ID $SCRIPT_VERSION

Usage:
  git-branch-restore [--branches=<name[,name2]>]
                     [--from=auto|tag|bundle]
                     [--when=latest|YYYY-MM]
                     [--push] [--set-upstream|-u | --no-set-upstream]
                     [--force]
                     [--list] [--limit=200]
                     [--remote=origin]
                     [--dry-run] [--no-color] [--debug=dbg|trace|xtrace]
                     [--help] [--version]
H
}

BOLD=""; YEL=""; GRN=""; RED=""; BLU=""; RST=""
color_init() {
  if [ "$NO_COLOR_FORCE" = "yes" ] || [ -n "${NO_COLOR:-}" ] || [ ! -t 1 ]; then
    BOLD=""; YEL=""; GRN=""; RED=""; BLU=""; RST=""
  else
    BOLD=$'\033[1m'; YEL=$'\033[33m'; GRN=$'\033[32m'; RED=$'\033[31m'; BLU=$'\033[34m'; RST=$'\033[0m'
  fi
}

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
    --branches=*) BRANCHES_CSV="${arg#*=}" ;;
    --from=*)     FROM="${arg#*=}" ;;
    --when=*)     WHEN="${arg#*=}" ;;
    --push)       DO_PUSH="yes" ;;
    --set-upstream|-u) SET_UPSTREAM="yes" ;;
    --no-set-upstream) SET_UPSTREAM="no" ;;
    --force)     FORCE="yes" ;;
    --list)      DO_LIST="yes" ;;
    --limit=*)   LIMIT="${arg#*=}" ;;
    --project=*) : ;;
    *) echo "Unbekannte Option: $arg"; echo "Nutze --help"; exit 3 ;;
  esac
done

color_init
logfx_init "$SCRIPT_ID" "$LOG_LEVEL"
[ "$LOG_LEVEL" = "xtrace" ] && logfx_xtrace_on || true

S_args="$(logfx_scope_begin "parse-args")"
logfx_var "remote" "$REMOTE" "branches_csv" "$BRANCHES_CSV" "from" "$FROM" "when" "$WHEN" \
          "push" "$DO_PUSH" "set_upstream" "$SET_UPSTREAM" "force" "$FORCE" "limit" "$LIMIT" \
          "no_color" "$NO_COLOR_FORCE" "dry_run" "${DRY_RUN:-}"
logfx_scope_end "$S_args" "ok"

S_ctx="$(logfx_scope_begin "context-detect")"
BIN_PATH="$HOME/code/bin"
PWD_P="$(pwd -P)"
MODE="unknown"
REPO_ROOT=""

command -v git >/dev/null 2>&1 || { echo "Fehler: git fehlt"; logfx_event "dependency" "missing" "git"; exit 4; }

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

if [ "$PWD_P" != "$REPO_ROOT" ]; then
  msg="Bitte aus Repo-Wurzel starten: $REPO_ROOT"
  [ -n "$BOLD" ] && printf "%sGatekeeper:%s %s\n" "$YEL$BOLD" "$RST" "$msg" || echo "Gatekeeper: $msg"
  logfx_event "gatekeeper" "reason" "not-root" "repo_root" "$REPO_ROOT" "pwd" "$PWD_P"
  exit 2
fi

logfx_var "mode" "$MODE" "repo_root" "$REPO_ROOT"
logfx_scope_end "$S_ctx" "ok"

AUD_BASE="$HOME/code/bin/shellscripts/audits/git-branch-rm"
REPO_LABEL="$MODE"   # "bin" oder "project"
AUD_DIR="$AUD_BASE/$REPO_LABEL"

find_audit_file(){
  local w="$1"
  if [ "$w" = "latest" ]; then
    ls -1t "$AUD_DIR"/deletions.*.jsonl 2>/dev/null | head -n1 || true
  else
    echo "$AUD_DIR/deletions.$w.jsonl"
  fi
}

audit_file="$(find_audit_file "$WHEN")"
if [ -z "${audit_file:-}" ] || [ ! -f "$audit_file" ]; then
  echo "Keine Audit-Datei gefunden für when=$WHEN in $AUD_DIR"
  logfx_event "audit-missing" "when" "$WHEN" "aud_dir" "$AUD_DIR"
  [ "$DO_LIST" = "yes" ] && exit 0 || exit 2
fi
[ -n "$BOLD" ] && printf "%sAUDIT-Datei%s: %s\n" "$BOLD" "$RST" "$audit_file" || echo "AUDIT-Datei: $audit_file"
logfx_var "audit_file" "$audit_file"

split_csv(){
  local s="$1"; s="${s#,}"; s="${s%,}"
  IFS=',' read -r -a arr <<<"$s"
  local out=()
  for x in "${arr[@]}"; do
    x="${x##origin/}"
    x="$(printf '%s' "$x" | tr -d '[:space:]')"
    [ -n "$x" ] && out+=("$x")
  done
  printf '%s\n' "${out[@]}"
}

json_get(){
  printf '%s\n' "$1" | sed -n "s/.*\"$2\":\"\\([^\"]*\\)\".*/\\1/p"
}

if [ "$DO_LIST" = "yes" ]; then
  echo "Verfügbare Restore-Kandidaten (max $LIMIT) — Quelle: $audit_file"
  nl=0
  while IFS= read -r line; do
    ts="$(printf '%s\n' "$line" | sed -n 's/.*"ts":"\([^"]*\)".*/\1/p')"
    br="$(printf '%s\n' "$line" | sed -n 's/.*"branch":"\([^"]*\)".*/\1/p' | sed 's#^origin/##')"
    tag="$(printf '%s\n' "$line" | sed -n 's/.*"tag":"\([^"]*\)".*/\1/p')"
    bun="$(printf '%s\n' "$line" | sed -n 's/.*"bundle":"\([^"]*\)".*/\1/p')"
    [ -z "$br" ] && continue
    suffix=""
    if [ -z "$tag" ] && [ -z "$bun" ]; then suffix="  [NO-BACKUP]"; fi
    printf "  · %s  branch:%s  tag:%s  bundle:%s%s\n" "${ts:-?}" "$br" "${tag:--}" "${bun:--}" "$suffix"
    nl=$((nl+1)); [ $nl -ge $LIMIT ] && break
  done < <(tac "$audit_file")
  exit 0
fi

mapfile -t BRANCHES < <(split_csv "$BRANCHES_CSV")
if [ "${#BRANCHES[@]}" -eq 0 ]; then
  echo "Fehler: Keine --branches angegeben. Nutze --list zur Übersicht."
  exit 3
fi

branch_exists_local(){ git show-ref --verify --quiet "refs/heads/$1"; }

S_run="$(logfx_scope_begin "restore-run")"
for BR in "${BRANCHES[@]}"; do
  S_b="$(logfx_scope_begin "branch" "name" "$BR")"
  entry="$(tac "$audit_file" | grep -F "\"branch\":\"$BR\"" | head -n1 || true)"
  if [ -z "$entry" ]; then
    echo "SKIP: Kein Audit-Eintrag für branch '$BR' in: $audit_file"
    logfx_event "restore-skip" "branch" "$BR" "reason" "no-audit"
    logfx_scope_end "$S_b" "warn"
    continue
  fi

  TAG_NAME="$(json_get "$entry" tag)"
  BUNDLE_PATH="$(json_get "$entry" bundle)"
  TS_REC="$(json_get "$entry" ts)"
  logfx_var "branch" "$BR" "audit_ts" "$TS_REC" "tag" "${TAG_NAME:-}" "bundle" "${BUNDLE_PATH:-}"

  if branch_exists_local "$BR"; then
    if [ "$FORCE" = "yes" ]; then
      if [ "${DRY_RUN:-}" = "yes" ]; then
        echo "DRY-RUN: würde lokalen Branch löschen: $BR"
        logfx_event "dry-plan" "drop_branch" "$BR"
      else
        logfx_run "branch-delete-local" -- git branch -D "$BR"
      fi
    else
      echo "WARN: Branch existiert lokal bereits: $BR  (nutze --force zum Überschreiben)"
      logfx_scope_end "$S_b" "warn"
      continue
    fi
  fi

  # Quelle wählen
  SRC_KIND=""
  if [ "$FROM" = "tag" ]; then
    [ -n "${TAG_NAME:-}" ] && SRC_KIND="tag"
  elif [ "$FROM" = "bundle" ]; then
    [ -n "${BUNDLE_PATH:-}" ] && SRC_KIND="bundle"
  else
    if [ -n "${TAG_NAME:-}" ]; then SRC_KIND="tag"
    elif [ -n "${BUNDLE_PATH:-}" ]; then SRC_KIND="bundle"
    else SRC_KIND=""; fi
  fi

  # Fallback: kein Backup im Audit → versuche Remote-Head
  if [ -z "$SRC_KIND" ]; then
    SHA_REMOTE="$(git ls-remote --heads "$REMOTE" "$BR" 2>/dev/null | awk '{print $1}' | head -n1 || true)"
    if [ -n "$SHA_REMOTE" ]; then
      if [ "${DRY_RUN:-}" = "yes" ]; then
        echo "DRY-RUN: (Fallback) git fetch \"$REMOTE\" \"$BR:$BR\""
        logfx_event "dry-plan" "restore_from" "remote" "branch" "$BR" "sha" "$SHA_REMOTE"
      else
        logfx_run "fetch-remote-fallback" -- git fetch "$REMOTE" "$BR:refs/heads/$BR"
      fi
      SRC_KIND="remote"
    else
      echo "FAIL: Weder Tag noch Bundle im Audit und kein Remote-Head für '$BR' gefunden."
      logfx_scope_end "$S_b" "fail"
      continue
    fi
  fi

  if [ "$SRC_KIND" = "tag" ]; then
    if [ "${DRY_RUN:-}" = "yes" ]; then
      echo "DRY-RUN: git branch $BR $TAG_NAME"
      logfx_event "dry-plan" "restore_from" "tag" "tag" "$TAG_NAME" "branch" "$BR"
    else
      if git show-ref --tags --verify --quiet "refs/tags/$TAG_NAME"; then
        logfx_run "branch-create-from-tag" -- git branch "$BR" "$TAG_NAME"
      else
        echo "WARN: Tag '$TAG_NAME' lokal nicht vorhanden → hole Tags…"
        logfx_run "fetch-tags" -- git fetch --tags || true
        if git show-ref --tags --verify --quiet "refs/tags/$TAG_NAME"; then
          logfx_run "branch-create-from-tag" -- git branch "$BR" "$TAG_NAME"
        else
          echo "FAIL: Tag '$TAG_NAME' nicht auffindbar."
          logfx_scope_end "$S_b" "fail"
          continue
        fi
      fi
    fi
  elif [ "$SRC_KIND" = "bundle" ]; then
    if [ -z "${BUNDLE_PATH:-}" ] || [ ! -f "$BUNDLE_PATH" ]; then
      echo "FAIL: Bundle fehlt: $BUNDLE_PATH"
      logfx_scope_end "$S_b" "fail"
      continue
    fi
    if [ "${DRY_RUN:-}" = "yes" ]; then
      echo "DRY-RUN: git fetch \"$BUNDLE_PATH\" \"$BR:$BR\"  (oder via SHA)"
      logfx_event "dry-plan" "restore_from" "bundle" "bundle" "$BUNDLE_PATH" "branch" "$BR"
    else
      SHA="$(git bundle list-heads "$BUNDLE_PATH" 2>/dev/null | awk '{print $1}' | head -n1 || true)"
      if [ -n "$SHA" ]; then
        logfx_run "fetch-bundle" -- git fetch "$BUNDLE_PATH" "$SHA:refs/heads/$BR"
      else
        logfx_run "fetch-bundle" -- git fetch "$BUNDLE_PATH" "refs/heads/$BR:refs/heads/$BR"
      fi
    fi
  else
    : # remote-Fallback erledigt schon das Fetch
  fi

  if [ "$DO_PUSH" = "yes" ]; then
    if [ "${DRY_RUN:-}" = "yes" ]; then
      case "$SET_UPSTREAM" in
        yes|auto) echo "DRY-RUN: git push -u $REMOTE $BR" ;;
        no)       echo "DRY-RUN: git push $REMOTE $BR" ;;
      esac
      logfx_event "dry-plan" "push_branch" "$BR" "remote" "$REMOTE" "set_upstream" "$SET_UPSTREAM"
    else
      PUSH_ARGS=(git push)
      case "$SET_UPSTREAM" in
        yes|auto) PUSH_ARGS+=(-u "$REMOTE" "$BR") ;;
        no)       PUSH_ARGS+=("$REMOTE" "$BR") ;;
      esac
      if logfx_run "git-push" -- "${PUSH_ARGS[@]}"; then
        echo "OK: Branch '$BR' nach $REMOTE gepusht."
      else
        rc=$?; echo "Fehler: git push rc=$rc"
        logfx_scope_end "$S_b" "fail" "rc" "$rc"
        continue
      fi
    fi
  fi

  echo "RESTORED: $BR  (Quelle: $SRC_KIND)  | Audit: $audit_file"
  logfx_scope_end "$S_b" "ok"
done
logfx_scope_end "$S_run" "ok"
exit 0
