#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# runs-prune — Aufräumen von Runs (Summaries), Audits, Debug-Logs & Bundle-Backups
# Version: v0.3.0
# -----------------------------------------------------------------------------
set -euo pipefail
IFS=$'\n\t'

# >>> LOGFX INIT >>>
: "${LOG_LEVEL:=trace}"      # off|dbg|trace|xtrace
: "${DRY_RUN:=}"             # ""|yes
# shellcheck source=/dev/null
. "$HOME/code/bin/shellscripts/lib/logfx.sh"
# <<< LOGFX INIT <<<

SCRIPT_ID="runs-prune"
SCRIPT_VERSION="v0.3.0"

# Wurzeln
RUNS_ROOT="${HOME}/code/bin/shellscripts/runs"
AUDITS_ROOT="${HOME}/code/bin/shellscripts/audits"
DEBUGS_ROOT="${HOME}/code/bin/shellscripts/debugs"
BUNDLES_ROOT="${HOME}/code/bin/shellscripts/backups/branches"

# Defaults (global)
KEEP_DAYS=90
KEEP_FILES=200
TOOL="all"          # all | <tool-name>
REPO="all"          # all | <repo-slug>
NO_COLOR_FORCE="no"

# Optionale Bereiche
ALSO_AUDITS="no"
ALSO_DEBUGS="no"
ALSO_BUNDLES="no"

# Optional eigene Limits je Bereich (fallback auf global)
KEEP_DAYS_AUDITS=""
KEEP_FILES_AUDITS=""
KEEP_DAYS_DEBUGS=""
KEEP_FILES_DEBUGS=""
KEEP_DAYS_BUNDLES=""
KEEP_FILES_BUNDLES=""

usage(){ cat <<H
$SCRIPT_ID $SCRIPT_VERSION
Usage:
  runs-prune [--keep-days=N] [--keep-files=N]
             [--tool=all|<tool>] [--repo=all|<repo-slug>]
             [--also-audits] [--also-debug] [--also-bundles]
             [--keep-days-audits=N]  [--keep-files-audits=N]
             [--keep-days-debug=N]   [--keep-files-debug=N]
             [--keep-days-bundles=N] [--keep-files-bundles=N]
             [--dry-run] [--no-color]
             [--debug=dbg|trace|xtrace] [--help] [--version]

Defaults:
  runs:    keep-days=90  keep-files=200
  audits:  (nutzt runs-Defaults, außer Overrides gesetzt)
  debug:   (nutzt runs-Defaults, außer Overrides gesetzt)
  bundles: (nutzt runs-Defaults, außer Overrides gesetzt)

Beispiele:
  runs-prune --dry-run
  runs-prune --tool=git-branch-rm --repo=bin --keep-days=60 --keep-files=120
  runs-prune --also-audits --also-debug --keep-days-debug=30 --keep-files-debug=100
  runs-prune --also-bundles --keep-days-bundles=180 --keep-files-bundles=100
H
}

# Farben
BOLD=""; YEL=""; GRN=""; RED=""; BLU=""; RST=""
color_init(){
  if [ "$NO_COLOR_FORCE" = "yes" ] || [ -n "${NO_COLOR:-}" ] || [ ! -t 1 ]; then
    BOLD=""; YEL=""; GRN=""; RED=""; BLU=""; RST=""
  else
    BOLD=$'\033[1m'; YEL=$'\033[33m'; GRN=$'\033[32m'; RED=$'\033[31m'; BLU=$'\033[34m'; RST=$'\033[0m'
  fi
}

# Args
for arg in "$@"; do
  case "$arg" in
    --help) usage; exit 0 ;;
    --version) echo "$SCRIPT_ID $SCRIPT_VERSION"; exit 0 ;;
    --dry-run) DRY_RUN="yes" ;;
    --no-color) NO_COLOR_FORCE="yes" ;;
    --debug=dbg)    LOG_LEVEL="dbg" ;;
    --debug=trace)  LOG_LEVEL="trace" ;;
    --debug=xtrace) LOG_LEVEL="xtrace" ;;
    --keep-days=*) KEEP_DAYS="${arg#*=}" ;;
    --keep-files=*) KEEP_FILES="${arg#*=}" ;;
    --tool=*) TOOL="${arg#*=}" ;;
    --repo=*) REPO="${arg#*=}" ;;
    --also-audits) ALSO_AUDITS="yes" ;;
    --also-debug|--also-debugs) ALSO_DEBUGS="yes" ;;
    --also-bundles) ALSO_BUNDLES="yes" ;;
    --keep-days-audits=*) KEEP_DAYS_AUDITS="${arg#*=}" ;;
    --keep-files-audits=*) KEEP_FILES_AUDITS="${arg#*=}" ;;
    --keep-days-debug=*) KEEP_DAYS_DEBUGS="${arg#*=}" ;;
    --keep-files-debug=*) KEEP_FILES_DEBUGS="${arg#*=}" ;;
    --keep-days-bundles=*) KEEP_DAYS_BUNDLES="${arg#*=}" ;;
    --keep-files-bundles=*) KEEP_FILES_BUNDLES="${arg#*=}" ;;
    *) echo "Unbekannte Option: $arg"; echo "Nutze --help"; exit 2 ;;
  esac
done

color_init
logfx_init "$SCRIPT_ID" "$LOG_LEVEL"
[ "$LOG_LEVEL" = "xtrace" ] && logfx_xtrace_on || true

# --- Gatekeeper: nur aus ~/code/bin starten -----------------------------------
S_gate="$(logfx_scope_begin "gatekeeper")"
BIN_PATH="$HOME/code/bin"
PWD_P="$(pwd -P)"
if [ "$PWD_P" != "$BIN_PATH" ]; then
  msg="$BIN_PATH - bitte aus diesem Verzeichnis starten (bin-only)."
  [ -n "$BOLD" ] && printf "%sGatekeeper:%s %s%s%s\n" "$YEL$BOLD" "$RST" "$RED" "$msg" "$RST" || echo "Gatekeeper: $msg"
  logfx_event "gatekeeper" "reason" "not-bin" "pwd" "$PWD_P"
  logfx_scope_end "$S_gate" "fail"
  exit 2
fi
logfx_scope_end "$S_gate" "ok"

# --- Helpers ------------------------------------------------------------------
now_s="$(date +%s)"

repos_list(){
  # listet Slugs (Unterordner) eines Basisverzeichnisses
  [ -d "$1" ] || return 0
  find "$1" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null | awk -F/ '{print $NF}' | sort
}

tools_list_dynamic(){
  # Aggregiert Tool-Namen über alle Repos unter RUNS_ROOT
  [ -d "$RUNS_ROOT" ] || return 0
  find "$RUNS_ROOT" -mindepth 2 -maxdepth 2 -type d -print 2>/dev/null \
    | awk -F/ '{print $(NF)}' | sort -u
}

tools_list(){
  if [ "$TOOL" = "all" ]; then
    tools_list_dynamic
  else
    printf "%s\n" "$TOOL"
  fi
}

# Generische Prune-Funktion für Datei-Listen (absteigend nach mtime)
# Args: <liste> <keep_days> <keep_files> <label>
prune_files(){
  local list="$1" kd="$2" kf="$3" label="${4:-files}"
  local kept=0 deleted=0 idx=0
  local to_delete=""

  [ -n "$list" ] || { echo "kept:0 delete:0"; return 0; }

  while IFS= read -r f; do
    [ -f "$f" ] || continue
    idx=$((idx+1))

    # Altersprüfung
    local del_age="no"
    if [ -n "$kd" ] && [ "$kd" -gt 0 ]; then
      local mt age_d
      mt="$(stat -c %Y "$f" 2>/dev/null || echo "$now_s")"
      age_d=$(( (now_s - mt) / 86400 ))
      [ "$age_d" -gt "$kd" ] && del_age="yes"
    fi
    # Mengenprüfung
    local del_cnt="no"
    if [ -n "$kf" ] && [ "$kf" -gt 0 ] && [ "$idx" -gt "$kf" ]; then
      del_cnt="yes"
    fi

    if [ "$del_age" = "yes" ] || [ "$del_cnt" = "yes" ]; then
      to_delete="${to_delete}${f}\n"
      deleted=$((deleted+1))
    else
      kept=$((kept+1))
    fi
  done <<EOF
$list
EOF

  echo "kept:$kept delete:$deleted"
  if [ -n "$to_delete" ]; then
    printf "%b" "$to_delete" | sed 's/^/  - /'
    if [ "${DRY_RUN:-}" != "yes" ]; then
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        rm -f -- "$f" 2>/dev/null || true
      done <<EOF
$(printf "%b" "$to_delete")
EOF
    fi
  fi
  logfx_event "prune" "label" "$label" "kept" "$kept" "deleted" "$deleted"
  return 0
}

# --- Banner / Plan ------------------------------------------------------------
printf "%sPRUNE%s  keep-days:%s  keep-files:%s  tool:%s  repo:%s\n" "$BOLD" "$RST" "$KEEP_DAYS" "$KEEP_FILES" "$TOOL" "$REPO"
[ "${DRY_RUN:-}" = "yes" ] && echo "${YEL}DRY-RUN:${RST} es wird nichts gelöscht."

# ========= 1) RUNS ============================================================
echo "${BLU}${BOLD}RUNS${RST} unter $RUNS_ROOT"
if [ -d "$RUNS_ROOT" ]; then
  for repo in $( [ "$REPO" = "all" ] && repos_list "$RUNS_ROOT" || echo "$REPO" ); do
    for tool in $(tools_list); do
      dir="$RUNS_ROOT/$repo/$tool"
      [ -d "$dir" ] || continue
      # alle JSON außer latest.json, mtime-absteigend
      files="$(ls -1t "$dir"/*.json 2>/dev/null | grep -v '/latest\.json$' || true)"
      echo "DIR runs  $repo/$tool"
      res="$(prune_files "$files" "$KEEP_DAYS" "$KEEP_FILES" "runs:$repo/$tool")"
      echo "$res"
      # latest.json neu setzen
      if [ "${DRY_RUN:-}" != "yes" ]; then
        newest_after="$(ls -1t "$dir"/*.json 2>/dev/null | grep -v '/latest\.json$' | head -n1 || true)"
        if [ -n "$newest_after" ]; then ln -sfn "$newest_after" "$dir/latest.json" 2>/dev/null || true
        else rm -f "$dir/latest.json" 2>/dev/null || true
        fi
      fi
    done
  done
else
  echo "Hinweis: $RUNS_ROOT existiert nicht."
fi

# ========= 2) AUDITS (optional) ===============================================
if [ "$ALSO_AUDITS" = "yes" ]; then
  kd="${KEEP_DAYS_AUDITS:-$KEEP_DAYS}"
  kf="${KEEP_FILES_AUDITS:-$KEEP_FILES}"
  echo "${BLU}${BOLD}AUDITS${RST} unter $AUDITS_ROOT  (keep-days:$kd keep-files:$kf)"
  if [ -d "$AUDITS_ROOT" ]; then
    for tool in $( [ "$TOOL" = "all" ] && repos_list "$AUDITS_ROOT" || echo "$TOOL" ); do
      base="$AUDITS_ROOT/$tool"
      [ -d "$base" ] || continue
      for repo in $( [ "$REPO" = "all" ] && repos_list "$base" || echo "$REPO" ); do
        dir="$base/$repo"
        [ -d "$dir" ] || continue
        files="$(ls -1t "$dir"/*.jsonl 2>/dev/null || true)"
        echo "DIR audits $tool/$repo"
        res="$(prune_files "$files" "$kd" "$kf" "audits:$tool/$repo")"
        echo "$res"
      done
    done
  else
    echo "Hinweis: $AUDITS_ROOT existiert nicht."
  fi
fi

# ========= 3) DEBUGS (optional) ===============================================
if [ "$ALSO_DEBUGS" = "yes" ]; then
  kd="${KEEP_DAYS_DEBUGS:-$KEEP_DAYS}"
  kf="${KEEP_FILES_DEBUGS:-$KEEP_FILES}"
  echo "${BLU}${BOLD}DEBUGS${RST} unter $DEBUGS_ROOT  (keep-days:$kd keep-files:$kf)"
  if [ -d "$DEBUGS_ROOT" ]; then
    # Struktur: debug/<script-id>/*.jsonl
    for tooldir in "$DEBUGS_ROOT"/*; do
      [ -d "$tooldir" ] || continue
      tool_name="$(basename "$tooldir")"
      if [ "$TOOL" != "all" ] && [ "$tool_name" != "$TOOL" ]; then continue; fi
      files="$(ls -1t "$tooldir"/*.jsonl 2>/dev/null || true)"
      echo "DIR debugs $tool_name"
      res="$(prune_files "$files" "$kd" "$kf" "debugs:$tool_name")"
      echo "$res"
    done
  else
    echo "Hinweis: $DEBUGS_ROOT existiert nicht."
  fi
fi

# ========= 4) BUNDLES (optional) ==============================================
if [ "$ALSO_BUNDLES" = "yes" ]; then
  kd="${KEEP_DAYS_BUNDLES:-$KEEP_DAYS}"
  kf="${KEEP_FILES_BUNDLES:-$KEEP_FILES}"
  echo "${BLU}${BOLD}BUNDLES${RST} unter $BUNDLES_ROOT  (keep-days:$kd keep-files:$kf)"
  if [ -d "$BUNDLES_ROOT" ]; then
    for repo in $( [ "$REPO" = "all" ] && repos_list "$BUNDLES_ROOT" || echo "$REPO" ); do
      dir="$BUNDLES_ROOT/$repo"
      [ -d "$dir" ] || continue
      files="$(ls -1t "$dir"/*.bundle 2>/dev/null || true)"
      echo "DIR bundles $repo"
      res="$(prune_files "$files" "$kd" "$kf" "bundles:$repo")"
      echo "$res"
    done
  else
    echo "Hinweis: $BUNDLES_ROOT existiert nicht."
  fi
fi

echo "${GRN}PRUNE fertig.${RST}"
[ "${DRY_RUN:-}" = "yes" ] && echo "Hinweis: DRY-RUN – es wurde nichts gelöscht."
exit 0
