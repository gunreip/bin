#!/usr/bin/env bash
# =====================================================================
# _changelog_mark_unknown.sh — setzt im Skriptkopf nach dem Datum ein "?" (unknown) pro Version
# Script-ID: changelog_mark_unknown
# Version:   v0.1.0
# Datum:     2025-09-13
# TZ:        Europe/Berlin
#
# CHANGELOG
# v0.1.0 (2025-09-13)
#   - Initiale Version: --file/--path/--scan, --dry-run, --steps; Backup & atomic write.
#
#
# shellcheck disable=
#
# =====================================================================

set -euo pipefail
IFS=$'\n\t'

# ---- Gatekeeper ----
if [[ "$(pwd -P)" != "$HOME/bin" ]]; then
  echo "Dieses Skript muss aus ~/bin gestartet werden. Aktuell: $(pwd -P)" >&2
  exit 2
fi

SCRIPT_VERSION="v0.1.0"
SCAN_ROOT="$HOME/bin/shellscripts"
TMPROOT="$HOME/bin/temp"
mkdir -p "$TMPROOT"

QUIET=0
DRY_RUN=0
STEPS=1

SINGLE_PATH=""
SINGLE_NAME=""
DO_SCAN=0

usage() {
  cat <<'HLP'
Usage:
  changelog_mark_unknown --file=NAME        [--dry-run] [--steps=N] [-q]
  changelog_mark_unknown --scriptname=NAME  [--dry-run] [--steps=N] [-q]
  changelog_mark_unknown --path=PATH        [--dry-run] [--steps=N] [-q]
  changelog_mark_unknown --scan             [--dry-run] [--steps=N] [-q]
  -h | --help   |  -V | --version
HLP
}

_log(){ local lvl="$1"; shift; (( STEPS >= lvl )) && echo "$@"; }
say(){ (( QUIET==0 )) && echo "$*"; }

for a in "$@"; do
  case "$a" in
    --file=*|--scriptname=*)  SINGLE_NAME="${a#*=}";;
    --path=*)                 SINGLE_PATH="${a#*=}";;
    --scan)                   DO_SCAN=1;;
    --dry-run)                DRY_RUN=1;;
    --steps=*)                STEPS="${a#*=}";;
    -q|--quiet)               QUIET=1;;
    -V|--version)             echo "changelog_mark_unknown ${SCRIPT_VERSION}"; exit 0;;
    -h|--help)                usage; exit 0;;
    *) echo "Unknown arg: $a"; usage; exit 64;;
  esac
done
case "${STEPS:-1}" in 0|1|2|3) :;; *) STEPS=1;; esac

die(){ echo "ERROR: $*" >&2; exit 1; }
basen(){ local b; b="$(basename -- "$1")"; printf '%s' "$b"; }

resolve_by_name(){
  local name="$1" cand="" ; local -a hits=()
  if [[ -e "$HOME/bin/$name" ]]; then
    cand="$(readlink -f -- "$HOME/bin/$name" 2>/dev/null || echo "$HOME/bin/$name")"
    [[ -f "$cand" ]] && { echo "$cand"; return 0; }
  fi
  while IFS= read -r -d '' f; do hits+=("$f"); done < <(
    find "$SCAN_ROOT" -type f \( -name "_${name}.sh" -o -name "${name}.sh" -o -name "${name}" \) -print0 2>/dev/null
  )
  if (( ${#hits[@]} == 1 )); then echo "${hits[0]}"; return 0
  elif (( ${#hits[@]} > 1 )); then echo "Mehrere Treffer für --file/--scriptname=${name}:" >&2; printf '   - %s\n' "${hits[@]}" >&2; return 2
  else return 1; fi
}

mark_file(){
  local f="$1"
  [[ -f "$f" ]] || return 0

  _log 1 "• $(basen "$f")"
  local tmp; tmp="$(mktemp -p "$TMPROOT" markunk_XXXXXX.tmp)"

  # Nur im CHANGELOG-Block (# CHANGELOG ... # shellcheck disable=) arbeiten:
  # In jeder Versionszeile "# vX.Y.Z (YYYY-MM-DD)" am Zeilenende " ?" ergänzen,
  # falls noch kein Status vorhanden ( ?, [OK], [WARN], [FAIL] ).
  awk '
    BEGIN{IN=0}
    /^# *CHANGELOG/                    {IN=1; print; next}
    IN && /^# *shellcheck disable=/    {IN=0; print; next}
    IN && /^# *v[0-9]/ {
      line=$0
      if (line ~ /\)\s*(\?|\[(OK|WARN|FAIL)\])\s*$/) { print line; next }
      print line " ?"
      next
    }
    { print }
  ' "$f" > "$tmp"

  if (( DRY_RUN )); then
    _log 2 "  would write: $f"
    rm -f "$tmp"
  else
    cp -a "$f" "$HOME/bin/backups/changelog_mark_unknown/$(basename "$f").$(date +%Y%m%d_%H%M%S).bak"
    mv -f "$tmp" "$f"
    _log 2 "  updated: $f"
  fi
}

process_one(){
  local resolved="$1"
  case "$resolved" in "$HOME/bin/shellscripts/"*) ;; *) die "Pfad liegt nicht unter ~/bin/shellscripts/: $resolved";; esac
  mark_file "$resolved"
}

main(){
  if (( DO_SCAN==1 )); then
    _log 1 "[scan] starte …"
    while IFS= read -r -d '' s; do
      # nur Dateien mit CHANGELOG-Kopf
      grep -qE '^# *CHANGELOG' "$s" && mark_file "$s"
    done < <(find "$SCAN_ROOT" -type f -name '*.sh' -print0 2>/dev/null)
    (( DRY_RUN )) && _log 1 "dry-run: keine Dateien geschrieben."
    exit 0
  fi

  local resolved=""
  if [[ -n "${SINGLE_NAME:-}" ]]; then
    if resolved="$(readlink -f -- "$HOME/bin/$SINGLE_NAME" 2>/dev/null)"; then [[ -f "$resolved" ]] || resolved=""; fi
    if [[ -z "$resolved" ]]; then
      mapfile -d '' hits < <(find "$SCAN_ROOT" -type f \( -name "_${SINGLE_NAME}.sh" -o -name "${SINGLE_NAME}.sh" -o -name "${SINGLE_NAME}" \) -print0 2>/dev/null || true)
      if (( ${#hits[@]} == 1 )); then resolved="${hits[0]}"
      elif (( ${#hits[@]} > 1 )); then echo "Mehrere Treffer für --file/--scriptname='${SINGLE_NAME}':" >&2; printf '   - %s\n' "${hits[@]}" >&2; exit 65
      else echo "Kein Treffer für --file/--scriptname='${SINGLE_NAME}'." >&2; [[ -n "${SINGLE_PATH:-}" ]] || exit 66; resolved="$SINGLE_PATH"
      fi
    fi
  else
    resolved="$SINGLE_PATH"
  fi

  [[ -f "$resolved" ]] || die "Skript nicht gefunden: $resolved"
  process_one "$resolved"
}
main "$@"
