#!/usr/bin/env bash
# _dbg_switch.sh — Debug-Status für Skripte setzen/toggeln (central TSV)
# v0.1.2
set -euo pipefail
IFS=$'\n\t'
LC_ALL=C; LANG=C

BIN_DIR="${HOME}/bin"
CFG_FILE="${BIN_DIR}/debug/_config/debug_status.tsv"
mkdir -p "$(dirname "$CFG_FILE")"; : > "$CFG_FILE" || true

usage(){
  cat <<'HLP'
Usage:
  _dbg_switch --script=<name|path> --debug=all|trace|syntax|OFF [--toggle]
  _dbg_switch --script=<name|path> --status
HLP
}

SCRIPT_ARG=""; MODE=""; TOGGLE=0; SHOW=0
for a in "${@:-}"; do
  case "$a" in
    --script=*) SCRIPT_ARG="${a#*=}";;
    --debug=all|--debug=trace|--debug=syntax|--debug=OFF) MODE="${a#*=}";;
    --toggle) TOGGLE=1;;
    --status) SHOW=1;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $a" >&2; usage; exit 64;;
  esac
done
[[ -n "$SCRIPT_ARG" ]] || { usage; exit 64; }

resolve() {
  local in="$1" p n id
  if [[ -f "$in" ]]; then p="$(readlink -f -- "$in")"
  else
    local cmd; cmd="$(command -v "$in" 2>/dev/null || true)"
    [[ -n "$cmd" ]] || { echo "❌ not found: $in" >&2; exit 2; }
    p="$(readlink -f -- "$cmd")"
  fi
  n="$(basename -- "$p")"; id="${n%.sh}"
  case "$p" in */maintenance/internal/*) id="${id#_}"; id="${id#.}";; esac
  printf '%s\t%s\n' "$p" "$id"
}

read -r TARGET CANON_ID < <(resolve "$SCRIPT_ARG")
CUR="$(awk -F'\t' -v id="$CANON_ID" '$1==id{print $2}' "$CFG_FILE" 2>/dev/null || true)"
[[ -z "${CUR:-}" ]] && CUR="(unset)"

if (( SHOW )); then
  echo "script: $CANON_ID"; echo "path:   $TARGET"; echo "debug:  $CUR"; exit 0
fi
[[ -n "$MODE" ]] || { echo "❌ need --debug=all|trace|syntax|OFF" >&2; usage; exit 64; }

NEW="$MODE"
if (( TOGGLE )) && [[ "$CUR" == "$MODE" ]]; then NEW="OFF"; fi

TMP="$(mktemp)"
awk -F'\t' -v id="$CANON_ID" 'BEGIN{OFS="\t"} $1!=id{print}' "$CFG_FILE" >"$TMP"
printf '%s\t%s\n' "$CANON_ID" "$NEW" >>"$TMP"
mv -f "$TMP" "$CFG_FILE"

echo "✅ debug[$CANON_ID] = $NEW"
