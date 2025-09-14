#!/usr/bin/env bash
# .shellscript_state_unfit.sh — markiert ein Zielskript als "unfit" (SCRIPT_STATE=0)
# v0.1.0
# shellcheck disable=SC2001,SC2016
set -euo pipefail
IFS=$'\n\t'

usage() {
  echo "Usage: .shellscript_state_unfit --script=<name|path> [--update-checklist]"
  echo "       .shellscript_state_unfit <name|path>"
}

SCRIPT_ARG=""
UPDATE_CL=0
for arg in "$@"; do
  case "$arg" in
    --script=*) SCRIPT_ARG="${arg#*=}";;
    --update-checklist) UPDATE_CL=1;;
    -h|--help) usage; exit 0;;
    *) if [ -z "${SCRIPT_ARG}" ]; then SCRIPT_ARG="$arg"; else echo "Unknown arg: $arg" >&2; usage; exit 64; fi;;
  esac
done
[ -n "${SCRIPT_ARG}" ] || { usage; exit 64; }

resolve_target() {
  local in="$1" cmd
  if [ -f "$in" ]; then readlink -f -- "$in"; return 0; fi
  cmd="$(command -v "$in" 2>/dev/null || true)"; if [ -n "$cmd" ]; then readlink -f -- "$cmd"; return 0; fi
  cmd="$(command -v "${in%.sh}" 2>/dev/null || true)"; if [ -n "$cmd" ]; then readlink -f -- "$cmd"; return 0; fi
  return 1
}

TARGET="$(resolve_target "$SCRIPT_ARG" || true)"
[ -n "${TARGET:-}" ] && [ -f "$TARGET" ] || { echo "Ziel nicht gefunden: $SCRIPT_ARG" >&2; exit 2; }

BAK_DIR="$HOME/bin/backups/script_state"; mkdir -p "$BAK_DIR"
cp -a "$TARGET" "$BAK_DIR/$(basename "$TARGET").bak.$(date +%Y%m%d_%H%M%S)"

if grep -q '^SCRIPT_STATE=' "$TARGET"; then
  sed -i '0,/^SCRIPT_STATE=/ s/^SCRIPT_STATE=.*/SCRIPT_STATE=0/' "$TARGET"
else
  if head -n1 "$TARGET" | grep -q '^#!'; then
    awk 'NR==1{print; print "SCRIPT_STATE=0"; next}1' "$TARGET" >"$TARGET.tmp" && mv "$TARGET.tmp" "$TARGET"
  else
    printf '%s\n%s\n' "SCRIPT_STATE=0" "$(cat "$TARGET")" > "$TARGET.tmp" && mv "$TARGET.tmp" "$TARGET"
  fi
fi

echo "UNFIT: $(basename "$TARGET") → SCRIPT_STATE=0"
if [ "$UPDATE_CL" -eq 1 ] && command -v .checklist_shellscripts >/dev/null 2>&1; then .checklist_shellscripts >/dev/null 2>&1 || true; fi
