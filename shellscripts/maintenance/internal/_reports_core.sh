#!/usr/bin/env bash
# _reports_core.sh — zentrale Helpers zum Schreiben/Rotieren von Skript-Reports
# v0.1.0
set -euo pipefail
IFS=$'\n\t'; LC_ALL=C; LANG=C

REPORTS_ROOT_DEFAULT="${HOME}/bin/reports"
REPORTS_KEEP_DEFAULT=5

__rep_sp(){ local p="${1:-}"; [[ -z "$p" ]] && { printf '%s' ""; return; }; case "$p" in "$HOME"*) printf '~%s' "${p#"$HOME"}";; *) printf '%s' "$p";; esac; }

# reports_init <script_id> [reports_root] [keep]
reports_init(){
  REPORTS_SCRIPT_ID="${1:?need script_id}"
  REPORTS_ROOT="${2:-$REPORTS_ROOT_DEFAULT}"
  REPORTS_KEEP="${3:-$REPORTS_KEEP_DEFAULT}"
  REPORTS_DIR="${REPORTS_ROOT}/${REPORTS_SCRIPT_ID}"
  mkdir -p "$REPORTS_DIR"
  REPORTS_STAMP="$(date +%Y%m%d_%H%M%S)"
  REPORTS_MD="${REPORTS_DIR}/${REPORTS_SCRIPT_ID}_${REPORTS_STAMP}.md"
  REPORTS_JSON="${REPORTS_DIR}/${REPORTS_SCRIPT_ID}_${REPORTS_STAMP}.json"
}

reports_write_md(){ : > "$REPORTS_MD"; printf '%s\n' "${1:-}" > "$REPORTS_MD"; ln -sfn "$(basename -- "$REPORTS_MD")" "${REPORTS_DIR}/latest.md"; }
reports_write_json(){ : > "$REPORTS_JSON"; printf '%s\n' "${1:-}" > "$REPORTS_JSON"; ln -sfn "$(basename -- "$REPORTS_JSON")" "${REPORTS_DIR}/latest.json"; }

reports_rotate(){
  local keep="${REPORTS_KEEP:-$REPORTS_KEEP_DEFAULT}" cnt
  for ext in md json; do
    mapfile -t files < <(find "$REPORTS_DIR" -maxdepth 1 -type f -name "${REPORTS_SCRIPT_ID}_*.${ext}" -printf '%T@ %p\n' | sort -nr | awk '{print $2}')
    cnt=0
    for f in "${files[@]}"; do
      cnt=$((cnt+1))
      [[ $cnt -le $keep ]] && continue
      rm -f -- "$f"
    done
  done
}

reports_paths_echo(){
  [[ -f "$REPORTS_DIR/latest.md" ]] && echo "📝 MD:  $(__rep_sp "$REPORTS_DIR")/latest.md"
  [[ -f "$REPORTS_DIR/latest.json" ]] && echo "🧾 JSON: $(__rep_sp "$REPORTS_DIR")/latest.json"
}
