#!/usr/bin/env bash
# =====================================================================
# _changelog_extract.sh — extrahiert # CHANGELOG aus Skriptköpfen
# Script-ID: changelog_extract
# Version:   v0.2.20
# Datum:     2025-09-14
# TZ:        Europe/Berlin
#
# CHANGELOG
# v0.2.20 (2025-09-14) ✅
#   - Ausrichtung der Statuszeilen vereinheitlicht (Spalten).
#   - Farben/Icons: exists yes = ✅ grün; no = ❌ rot; mode write = ✅ grün; dry-run = ⏳ gelb.
#   - target-Wert in blau.
#   - steps=0 bleibt Default; deprecated Optionen sind entfernt (seit v0.2.19).
#
# v0.2.19 (2025-09-14) ✅
#   - Default steps=0; doppelte "resolved" entfernt; Farb-Status eingeführt.
#
# v0.2.18 (2025-09-14) ✅
#   - Stabile Fehlerpropagation; ERR-Trap.
#
# v0.2.17 (2025-09-14) ✅
#   - Hilfe erweitert; Exit-Codes; CRLF-Säuberung.
#
# v0.2.16 (2025-09-13) ✅
#   - FIX: Render-Hänger beseitigt (Renderer liest aus Datei).
#
#
# shellcheck disable=
#
# =====================================================================

set -euo pipefail
set -o errtrace
IFS=$'\n\t'
export LC_ALL=C.UTF-8 LANG=C.UTF-8

SCRIPT_VERSION="v0.2.20"
trap 'echo "ERR at ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}" >&2' ERR

# ---- Gatekeeper ----
if [[ "$(pwd -P)" != "$HOME/bin" ]]; then
  echo "Dieses Skript muss aus ~/bin gestartet werden. Aktuell: $(pwd -P)" >&2
  exit 2
fi

# ---- Defaults ----
OUTPUT_ROOT="$HOME/bin/changelogs"
SCAN_ROOT="$HOME/bin/shellscripts"
TMPROOT="$HOME/bin/temp"
QUIET=0
DRY_RUN=0
REDUCE=0
STEPS=0          # 0=still (Default), 1=Schritte, 2=Details, 3=Debug
ROTATE=0
ROTATE_MAX=5

SINGLE_PATH=""
SINGLE_NAME=""
DO_SCAN=0

# Farben (nur bei TTY)
if [[ -t 1 ]]; then
  C_RESET=$'\e[0m'; C_GREEN=$'\e[32m'; C_RED=$'\e[31m'; C_YEL=$'\e[33m'; C_BLUE=$'\e[34m'
else
  C_RESET=""; C_GREEN=""; C_RED=""; C_YEL=""; C_BLUE=""
fi

# Icons
ICON_INFO="◆"
ICON_RUN="▶"
ICON_OK="✅"
ICON_WARN="⚠️"
ICON_FAIL="❌"
ICON_UNKNOWN="❓"
ICON_WAIT="⏳"

usage(){ cat <<'HLP'
Usage:
  changelog_extract --file=NAME        [--rotation[=N]] [--reduce] [--dry-run] [--steps=N] [-q]
  changelog_extract --scriptname=NAME  [--rotation[=N]] [--reduce] [--dry-run] [--steps=N] [-q]
  changelog_extract --path=PATH        [--rotation[=N]] [--reduce] [--dry-run] [--steps=N] [-q]
  changelog_extract --script=PATH      [--rotation[=N]] [--reduce] [--dry-run] [--steps=N] [-q]
  changelog_extract --scan             [--dry-run] [--steps=N] [-q]
  changelog_extract -V | --version
  changelog_extract -h | --help
HLP
}

_log(){ local lvl="$1"; shift; (( STEPS >= lvl )) && echo "$@"; }
say(){ (( QUIET==0 )) && echo "$*"; }

# Einheitliche Ausgabe (Spalten)
# icon, label, value, optional color
kv(){ 
  local icon="$1" label="$2" val="$3" color="${4:-}"
  # Icon separat, Label gepolstert auf 10 (colon inklusive)
  printf "%s %-10s %s%s%s\n" "$icon" "${label}:" "${color}" "${val}" "${C_RESET}"
}

# ---- Args ----
for a in "$@"; do
  case "$a" in
    --file=*|--scriptname=*)  SINGLE_NAME="${a#*=}";;
    --path=*|--script=*)      SINGLE_PATH="${a#*=}";;
    --scan)                   DO_SCAN=1;;
    --rotation)               ROTATE=1; ROTATE_MAX=5;;
    --rotation=*)             ROTATE=1; ROTATE_MAX="${a#*=}";;
    --reduce)                 REDUCE=1;;
    --dry-run)                DRY_RUN=1;;
    --steps=*)                STEPS="${a#*=}";;
    -q|--quiet)               QUIET=1;;
    -V|--version)             echo "changelog_extract ${SCRIPT_VERSION}"; exit 0;;
    -h|--help)                usage; exit 0;;
    *) echo "Unknown arg: $a"; usage; exit 64;;
  esac
done
case "${STEPS:-0}" in 0|1|2|3) :;; *) STEPS=0;; esac
[[ "${ROTATE_MAX}" =~ ^[0-9]+$ ]] || ROTATE_MAX=5

check_deps(){ command -v awk >/dev/null || { echo "awk fehlt" >&2; exit 70; }; }
check_deps
mkdir -p "$TMPROOT"

die(){ echo "ERROR: $*" >&2; exit 1; }
basen(){ local b; b="$(basename -- "$1")"; b="${b#_}"; b="${b%.sh}"; printf '%s' "$b"; }

mirror_dir_for(){
  local abs="$1"
  case "$abs" in "$HOME/bin/shellscripts/"*) ;; *) die "Pfad liegt nicht unter ~/bin/shellscripts/: $abs";; esac
  local rel="${abs#"$HOME/bin/shellscripts/"}"
  printf '%s/%s' "$OUTPUT_ROOT" "$(dirname -- "$rel")"
}

# CHANGELOG-Block aus Skriptkopf extrahieren
extract_block(){
  awk '
    BEGIN{INBLK=0}
    /^# *CHANGELOG/                    {INBLK=1; next}
    INBLK && /^# *shellcheck disable=/ {INBLK=0; exit}
    INBLK {
      gsub(/\r$/,"",$0)
      if ($0 ~ /^# ?/) { sub(/^# ?/, "", $0); print; next }
      if ($0 ~ /^$/)   { print ""; next }
      print
    }
  ' "$1"
}

# Markdown rendern (Icons/Tail 1:1 übernehmen)
render_markdown(){
  local tname="${1:-}"
  local src="${2:-}"
  local GEN_TS; GEN_TS="$(TZ=Europe/Berlin date '+%Y-%m-%d %H:%M %Z')"

  awk -v target="$tname" -v gentime="$GEN_TS" -v steps="${STEPS:-0}" '
    function trim(s){ gsub(/^[ \t\r\n]+|[ \t\r\n]+$/,"",s); return s }
    function hdr(ver,date,tail){
      if (printed_any) print ""
      printed_any=1
      printf("- **%s**", ver)
      if (date!="") printf(" *(%s)*", date)
      if (tail!="") printf(" — %s", tail)
      print ""
    }
    function dbg(msg){ if (steps>=3) print msg > "/dev/stderr" }

    BEGIN{
      printed_any=0
      print "# CHANGELOG " target "\n";
      print "_Erstellt: " gentime "_\n";
      print "## History\n"
    }
    {
      line=$0
      gsub(/\r$/,"",line)
      if (match(line, /^v[0-9][^ ]*/)) {
        # Datum optional
        dpos=match(line, /\([0-9]{4}-[0-9]{2}-[0-9]{2}\)/); date=""; rest=line
        if (dpos){
          date=substr(line, dpos+1, RLENGTH-2)
          rest=trim(substr(line,1,dpos-1) substr(line,dpos+RLENGTH))
        } else {
          rest=line
        }
        vpos=match(rest, /^v[0-9][^ ]*/); ver=(vpos?substr(rest, vpos, RLENGTH):"")
        tail=trim(substr(rest, vpos+RLENGTH))
        hdr(ver,date,tail)
        dbg(sprintf("  [render] ver=%s date=%s tail=%s", ver, date, tail))
      }
      else if (match(line, /^[ \t]*[-*•][ \t]+/)) {
        sub(/^[ \t]*[-*•][ \t]+/, "", line)
        print "  - " line
      }
      else if (trim(line)!="") {
        print "  - " line
      }
    }
  ' "$src"
}

# Rotation
prune_rotation(){
  local pattern="$1" max="$2"
  shopt -s nullglob
  local -a files=( $pattern )
  shopt -u nullglob
  (( ${#files[@]} )) || return 0
  local -a arr=()
  mapfile -t arr < <(printf '%s\0' "${files[@]}" | xargs -0 stat -c '%Y %n' 2>/dev/null | sort -nr | cut -d' ' -f2-)
  local n="${#arr[@]}"
  if (( n > max )); then for ((i=max;i<n;i++)); do rm -f -- "${arr[i]}"; done; fi
}

resolve_by_name(){
  local name="$1" cand="" ; local -a hits=()
  if [[ -e "$HOME/bin/$name" ]]; then
    cand="$(readlink -f -- "$HOME/bin/$name" 2>/dev/null || echo "$HOME/bin/$name")"
    [[ -f "$cand" ]] && { echo "$cand"; return 0; }
  fi
  while IFS= read -r -d '' f; do hits+=("$f"); end=1; done < <(
    find "$SCAN_ROOT" -type f \( -name "_${name}.sh" -o -name "${name}.sh" -o -name "${name}" \) -print0 2>/dev/null
  )
  if (( ${#hits[@]} == 1 )); then echo "${hits[0]}"; return 0
  elif (( ${#hits[@]} > 1 )); then echo "Mehrere Treffer für --file/--scriptname=${name}:" >&2; printf '   - %s\n' "${hits[@]}" >&2; return 2
  else return 1; fi
}

reduce_header(){
  local s="$1"
  local tmp; tmp="$(mktemp -p "$TMPROOT" chlog_src_XXXXXX.tmp)"
  awk '
    BEGIN{INBLK=0;KEPT=0}
    /^# *CHANGELOG/ {INBLK=1; print; next}
    INBLK && /^# *shellcheck disable=/ {INBLK=0; print; next}
    INBLK {
      if (KEPT==0) { if ($0 ~ /^# *v[0-9]/) { print; KEPT=1; next } next }
      else { if ($0 ~ /^# *v[0-9]/) { next } print; next }
    }
    { print }
  ' "$s" > "$tmp" && mv -f "$tmp" "$s"
  _log 2 "  reduce: source header trimmed to latest entry"
}

process_script(){
  local s="$1"; [[ -f "$s" ]] || return 0

  local name outdir outfile ts outfile_rot
  local tmp="" tmp_mid="" tmp_err="" tmp_latest=""
  cleanup(){ set +u; rm -f -- "${tmp:-}" "${tmp_mid:-}" "${tmp_err:-}" "${tmp_latest:-}"; }
  trap cleanup EXIT

  name="$(basen "$s")"
  outdir="$(mirror_dir_for "$s")"
  outfile="$outdir/CHANGELOG-${name}.md"
  ts="$(date +%Y%m%d_%H%M%S)"
  outfile_rot="$outdir/CHANGELOG-${name}_${ts}.md"

  tmp="$(mktemp -p "$TMPROOT" changelog_out_XXXXXX.md)"
  tmp_mid="$(mktemp -p "$TMPROOT" changelog_ext_XXXXXX.txt)"
  tmp_err="$(mktemp -p "$TMPROOT" changelog_err_XXXXXX.log)"

  # Kopf-Zeilen (ausgerichtet, mit Farben/Icons)
  kv "$ICON_RUN" "target" "${name}" "$C_BLUE"
  kv " "         "src"    "${s}"
  kv " "         "dst"    "${outfile}"
  if (( DRY_RUN )); then
    kv " " "mode" "${ICON_WAIT} dry-run" "$C_YEL"
  else
    kv " " "mode" "${ICON_OK} write" "$C_GREEN"
  fi

  # [1/3] extract
  _log 1 "[1/3] extract ..."
  if ! extract_block "$s" >"$tmp_mid" 2>"$tmp_err"; then
    echo "extract_block failed" >&2
    return 71
  fi
  _log 2 "  extract: ok (lines=$(wc -l <"$tmp_mid"))"

  # [2/3] render
  _log 1 "[2/3] render ..."
  if ! render_markdown "$name" "$tmp_mid" >"$tmp" 2>>"$tmp_err"; then
    echo "render_markdown failed" >&2
    [[ -s "$tmp_err" ]] && { echo "---- stderr (render) ----" >&2; sed 's/^/  /' "$tmp_err" >&2; }
    return 72
  fi
  _log 2 "  render:  ok (lines=$(wc -l <"$tmp"))"

  # [3/3] write
  _log 1 "[3/3] write ..."
  if (( DRY_RUN )); then
    (( ROTATE )) && { _log 1 "  rotate: would write snapshot -> ${outfile_rot}"; _log 2 "  rotate: would keep last ${ROTATE_MAX}"; }
    _log 1 "  latest:  would update (atomic mv)"
  else
    if (( ROTATE )); then
      cp -f -- "$tmp" "$outfile_rot"
      _log 1 "  rotate: snapshot written -> ${outfile_rot}"
    fi
    tmp_latest="$(mktemp -p "$TMPROOT" changelog_latest_XXXXXX.md)"
    cp -f -- "$tmp" "$tmp_latest"
    mv -f -- "$tmp_latest" "$outfile"
    _log 1 "  latest:  updated (atomic)"
  fi

  if (( ROTATE )) && (( DRY_RUN == 0 )); then
    prune_rotation "$outdir/CHANGELOG-${name}_*.md" "$ROTATE_MAX"
    _log 2 "  rotate: pruned to last ${ROTATE_MAX}"
  fi

  if (( REDUCE )); then
    if (( DRY_RUN )); then
      _log 1 "[post] reduce header: would shorten source header to latest entry"
    else
      _log 1 "[post] reduce header ..."
      reduce_header "$s"
    fi
  fi

  cleanup; trap - EXIT
  return 0
}

# ---- Main ----
if (( DO_SCAN == 1 )); then
  (( STEPS>=1 )) && echo "[scan] starte Durchlauf ..."
  while IFS= read -r -d '' s; do
    grep -qE '^# *CHANGELOG' "$s" && { (( STEPS>=2 )) && echo "• $(basename "$s")"; process_script "$s" || true; }
  done < <(find "$SCAN_ROOT" -type f -name '*.sh' -print0 2>/dev/null)
  (( DRY_RUN )) && (( STEPS>=1 )) && echo "dry-run: keine Dateien geschrieben."
  exit 0
fi

resolved=""
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

# Head-Zeilen oben (einmalig)
echo "${ICON_INFO} resolved:  ${resolved}"
if [[ -f "${resolved}" ]]; then
  echo "${ICON_INFO} exists:    ${C_GREEN}${ICON_OK} yes${C_RESET}"
else
  echo "${ICON_INFO} exists:    ${C_RED}${ICON_FAIL} no${C_RESET}"
fi

case "$resolved" in "$HOME/bin/shellscripts/"*) ;; *) die "Pfad liegt nicht unter ~/bin/shellscripts/: $resolved";; esac
[[ -f "$resolved" ]] || die "Skript nicht gefunden: $resolved"

rc=0
process_script "$resolved" || rc=$?
exit "$rc"
