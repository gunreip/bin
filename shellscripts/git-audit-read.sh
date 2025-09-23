#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# git-audit-read — Audits auswerten (git-branch-rm & git-branch-restore)
# Version: v0.1.3
# -----------------------------------------------------------------------------
set -euo pipefail
IFS=$'\n\t'

SCRIPT_ID="git-audit-read"
SCRIPT_VERSION="v0.1.3"

AUDITS_ROOT="${HOME}/code/bin/shellscripts/audits"
DEBUG_DIR="${HOME}/code/bin/shellscripts/debugs/${SCRIPT_ID}"

TOOL="all"                 # all|git-branch-rm|git-branch-restore
REPO="all"                 # all|<repo-slug>
SINCE=""                   # YYYY-MM-DD
UNTIL=""                   # YYYY-MM-DD
ACTION="any"               # rm: delete|skip|any ; restore: restore|any
SIDE="any"                 # rm: local|remote|any
BRANCH_RE="" USER_RE="" EMAIL_RE=""
LIMIT=0                    # 0 = unlimitiert
SUMMARY_ONLY="no"
LIST_FILES="no"
JSON_OUT="no"
SHOW_FILTERS="no"
NO_COLOR_FORCE="no"
LOG_LEVEL="trace"          # off|dbg|trace  (Testphase: trace)

usage(){ cat <<HLP
$SCRIPT_ID $SCRIPT_VERSION

Usage:
  git-audit-read [--tool=all|git-branch-rm|git-branch-restore]
                 [--repo=all|<repo-slug>]
                 [--since=YYYY-MM-DD] [--until=YYYY-MM-DD]
                 [--action=delete|skip|restore|any]
                 [--side=local|remote|any]
                 [--branch=<regex>] [--user=<regex>] [--email=<regex>]
                 [--limit=N] [--summary-only] [--list-files]
                 [--json] [--show-filters] [--no-color] [--debug=dbg|trace] [--help]
HLP
}

for arg in "$@"; do
  case "$arg" in
    --help) usage; exit 0 ;;
    --debug=*) LOG_LEVEL="${arg#*=}" ;;
    --no-color) NO_COLOR_FORCE="yes" ;;
    --tool=*) TOOL="${arg#*=}" ;;
    --repo=*) REPO="${arg#*=}" ;;
    --since=*) SINCE="${arg#*=}" ;;
    --until=*) UNTIL="${arg#*=}" ;;
    --action=*) ACTION="${arg#*=}" ;;
    --side=*) SIDE="${arg#*=}" ;;
    --branch=*) BRANCH_RE="${arg#*=}" ;;
    --user=*) USER_RE="${arg#*=}" ;;
    --email=*) EMAIL_RE="${arg#*=}" ;;
    --limit=*) LIMIT="${arg#*=}" ;;
    --summary-only) SUMMARY_ONLY="yes" ;;
    --list-files) LIST_FILES="yes" ;;
    --json) JSON_OUT="yes" ;;
    --show-filters) SHOW_FILTERS="yes" ;;
    *) echo "Unbekannte Option: $arg"; echo "Nutze --help"; exit 2 ;;
  esac
done

# Farben
BOLD=""; YEL=""; GRN=""; RED=""; BLU=""; RST=""
if [ "$NO_COLOR_FORCE" != "yes" ] && [ -z "${NO_COLOR:-}" ] && [ -t 1 ]; then
  BOLD=$'\033[1m'; YEL=$'\033[33m'; GRN=$'\033[32m'; RED=$'\033[31m'; BLU=$'\033[34m'; RST=$'\033[0m'
fi

# Debug
ts(){ date -u +"%Y-%m-%dT%H:%M:%SZ"; }
dbg_path(){ printf '%s/%s.%s.%s.jsonl\n' "$DEBUG_DIR" "$SCRIPT_ID" "$LOG_LEVEL" "$(date +%Y%m%d-%H%M%S)"; }
LOG_PATH=""
log_init(){
  [ "$LOG_LEVEL" = "off" ] && return 0
  mkdir -p "$DEBUG_DIR"
  LOG_PATH="$(dbg_path)"; : > "$LOG_PATH"
  printf '{"ts":"%s","event":"boot","level":"%s"}\n' "$(ts)" "$LOG_LEVEL" >> "$LOG_PATH"
  if [ -t 1 ]; then
    [ -n "$BOLD" ] && printf "%sDEBUG%s: %s%s%s\n" "$YEL$BOLD" "$RST" "$RED" "$LOG_PATH" "$RST" || echo "DEBUG: $LOG_PATH"
  fi
}
log_json(){ [ -n "$LOG_PATH" ] && printf '%s\n' "$1" >> "$LOG_PATH" || true; }
log_init

# Optionaler Kopf via git-ctx (nur im Repo)
if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  command -v git-ctx >/dev/null 2>&1 && git-ctx ${NO_COLOR_FORCE:+--no-color} || true
fi

# Helpers
has_jq(){ command -v jq >/dev/null 2>&1; }
tools_list(){
  case "$TOOL" in
    all) printf "git-branch-rm\ngit-branch-restore\n" ;;
    git-branch-rm|git-branch-restore) printf "%s\n" "$TOOL" ;;
    *) echo "Unbekannter --tool: $TOOL" >&2; exit 2 ;;
  esac
}
list_repos_under(){ [ -d "$1" ] || return 0; find "$1" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null | awk -F/ '{print $NF}' | sort; }
month_span_files(){ # $1 tool $2 repo
  case "$1" in
    git-branch-rm)      pat="deletions" ;;
    git-branch-restore) pat="restores" ;;
    *) return 0 ;;
  esac
  dir="${AUDITS_ROOT}/${1}/${2}"
  [ -d "$dir" ] || return 0
  find "$dir" -maxdepth 1 -type f -name "${pat}.*.jsonl" -print 2>/dev/null | sort
}

jq_date_filter(){ local f=""; [ -n "$SINCE" ] && f="${f} and .ts >= \"${SINCE}T00:00:00Z\""; [ -n "$UNTIL" ] && f="${f} and .ts <= \"${UNTIL}T23:59:59Z\""; [ -n "$f" ] && printf "%s" "${f# and }"; }
jq_field_filter(){
  local f="true"
  case "$ACTION" in
    delete) f="${f} and ((.action? // \"delete\") == \"delete\")" ;;
    skip)   f="${f} and (.action? == \"skip\")" ;;
    restore) f="${f} and (.source? != null)" ;;
    any)    : ;;
  esac
  case "$SIDE" in
    local)  f="${f} and ((.side? // \"-\") == \"local\")" ;;
    remote) f="${f} and ((.side? // \"-\") == \"remote\")" ;;
    any)    : ;;
  esac
  [ -n "$BRANCH_RE" ] && f="${f} and (.branch | test(\"$BRANCH_RE\"))"
  [ -n "$USER_RE" ] && f="${f} and ((.user? // \"\") | test(\"$USER_RE\"))"
  [ -n "$EMAIL_RE" ] && f="${f} and ((.email? // \"\") | test(\"$EMAIL_RE\"))"
  printf "%s" "$f"
}
jq_out_fmt(){
  if [ "$JSON_OUT" = "yes" ]; then echo '.'; else cat <<'JQ'
. as $r | if ($r.source? != null) then
  "\(.ts)  [restore]  repo=\(.repo)  src=\(.source):\(.source_id // "-")  -> branch=\(.target_branch // "-")  rc=\(.rc // -1)"
else
  "\(.ts)  [rm:\(.side // "-"):\(.action // "delete")]  repo=\(.repo)  branch=\(.branch)  sha=\(.sha[0:8])  rc=\(.rc // -1)"
end
JQ
  fi
}
jq_summary(){ cat <<'JQ'
group_by(.repo)[] | {
  repo: .[0].repo,
  counts: {
    rm_delete: ( [ .[] | select(.source == null and (.action // "delete") == "delete") ] | length ),
    rm_skip:   ( [ .[] | select(.source == null and (.action? == "skip")) ] | length ),
    restore:   ( [ .[] | select(.source != null) ] | length )
  }
}
JQ
}

filter_summary(){
  local f="tool=${TOOL} repo=${REPO}"
  [ -n "$SINCE" ] && f="$f since=${SINCE}"
  [ -n "$UNTIL" ] && f="$f until=${UNTIL}"
  f="$f action=${ACTION} side=${SIDE}"
  [ -n "$BRANCH_RE" ] && f="$f branch=/${BRANCH_RE}/"
  [ -n "$USER_RE" ] && f="$f user=/${USER_RE}/"
  [ -n "$EMAIL_RE" ] && f="$f email=/${EMAIL_RE}/"
  [ "$LIMIT" -gt 0 ] && f="$f limit=${LIMIT}"
  [ "$JSON_OUT" = "yes" ] && f="$f json=yes" || f="$f json=no"
  echo "$f"
}

# Dateien einsammeln
files_tmp="$(mktemp)"; trap 'rm -f "$files_tmp"' EXIT
for t in $(tools_list); do
  if [ "$REPO" = "all" ]; then
    for r in $(list_repos_under "${AUDITS_ROOT}/${t}"); do
      month_span_files "$t" "$r"
    done
  else
    month_span_files "$t" "$REPO"
  fi
done | sort -r > "$files_tmp"

if [ "$LIST_FILES" = "yes" ]; then
  [ "$SHOW_FILTERS" = "yes" ] && echo "FILTER: $(filter_summary)"
  echo "AUDIT-Dateien:"
  if [ -s "$files_tmp" ]; then sed 's/^/  · /' "$files_tmp"; else echo "  (keine)"; fi
  exit 0
fi

if [ ! -s "$files_tmp" ]; then
  [ "$SHOW_FILTERS" = "yes" ] && echo "FILTER: $(filter_summary)"
  echo "Keine Audit-Dateien gefunden (Filter zu streng oder noch keine Audits?)."
  exit 0
fi

# --- Lesen & Ausgeben ---------------------------------------------------------
if command -v jq >/dev/null 2>&1; then
  df="$(jq_date_filter)"; ff="$(jq_field_filter)"
  tmp_all="$(mktemp)"; trap 'rm -f "$tmp_all"' EXIT

  # Dateien getrennt einsammeln (robust)
  mapfile -t rm_paths < <(grep '/git-branch-rm/' "$files_tmp" || true)
  if [ "${#rm_paths[@]}" -gt 0 ]; then
    {
      for p in "${rm_paths[@]}"; do [ -f "$p" ] && cat "$p"; done
    } | jq -c 'if .source? then empty else . end | (if (.action? == null) then .action = "delete" else . end)' >> "$tmp_all" || true
  fi
  mapfile -t rs_paths < <(grep '/git-branch-restore/' "$files_tmp" || true)
  if [ "${#rs_paths[@]}" -gt 0 ]; then
    {
      for p in "${rs_paths[@]}"; do [ -f "$p" ] && cat "$p"; done
    } | jq -c 'select(.source != null)' >> "$tmp_all" || true
  fi

  jq_filter="."
  [ -n "$df" ] && jq_filter="${jq_filter} | select(${df})"
  [ -n "$ff" ] && jq_filter="${jq_filter} | select(${ff})"

  # Einmal filtern, dann anhand dessen entscheiden
  lines="$(jq -c "${jq_filter}" "$tmp_all")"

  [ "$SHOW_FILTERS" = "yes" ] && echo "FILTER: $(filter_summary)"

  if [ -z "$lines" ]; then
    echo "Keine Treffer (Filter: $(filter_summary))."
    exit 0
  fi

  if [ "$SUMMARY_ONLY" = "yes" ]; then
    # Zusammenfassen
    if [ "$JSON_OUT" = "yes" ]; then
      printf "%s\n" "$lines" | jq -s "${jq_summary}"
    else
      printf "%s\n" "$lines" | jq -r -s 'group_by(.repo)[] | "repo: \(.[] | .repo | select(.!=null) | .)[0]  rm_delete:\([ .[] | select(.source == null and (.action // "delete") == "delete") ] | length)  rm_skip:\([ .[] | select(.source == null and (.action? == "skip")) ] | length)  restore:\([ .[] | select(.source != null) ] | length)"'
    fi
    exit 0
  else
    fmt="$(jq_out_fmt)"
    if [ "$LIMIT" -gt 0 ]; then
      printf "%s\n" "$lines" | head -n "$LIMIT" | jq -r "$fmt"
    else
      printf "%s\n" "$lines" | jq -r "$fmt"
    fi
    exit 0
  fi

else
  echo "Hinweis: 'jq' nicht gefunden – benutze vereinfachte Filter (Regex/Grep)."
  [ "$SHOW_FILTERS" = "yes" ] && echo "FILTER: $(filter_summary)"
  printed=0
  while IFS= read -r f; do
    case "$f" in
      *"/git-branch-restore/"*)
        while IFS= read -r line; do
          if [ -n "$BRANCH_RE" ]; then printf "%s" "$line" | grep -E "\"target_branch\":\".*${BRANCH_RE}.*\"" >/dev/null 2>&1 || continue; fi
          [ "$ACTION" = "restore" -o "$ACTION" = "any" ] || continue
          echo "$line"; printed=$((printed+1))
        done < "$f"
        ;;
      *"/git-branch-rm/"*)
        while IFS= read -r line; do
          if [ -n "$BRANCH_RE" ]; then printf "%s" "$line" | grep -E "\"branch\":\".*${BRANCH_RE}.*\"" >/dev/null 2>&1 || continue; fi
          if [ "$ACTION" = "skip" ]; then printf "%s" "$line" | grep -q '"action":"skip"' || continue; fi
          if [ "$SIDE" = "local" ]; then printf "%s" "$line" | grep -q '"side":"local"' || continue; fi
          if [ "$SIDE" = "remote" ]; then printf "%s" "$line" | grep -q '"side":"remote"' || continue; fi
          echo "$line"; printed=$((printed+1))
        done < "$f"
        ;;
    esac
  done < "$files_tmp"
  if [ "$printed" -eq 0 ]; then echo "Keine Treffer (Filter: $(filter_summary))."; fi
  [ "$SUMMARY_ONLY" = "yes" ] && echo "(Summary ohne jq nicht verfügbar.)"
  exit 0
fi
