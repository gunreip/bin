#!/usr/bin/env bash
# _symlink-chk-fix.sh — Symlinks prüfen/reparieren + optional nach ~/bin spiegeln
# Version: v0.2.0
set -Eeuo pipefail; IFS=$'\n\t'; [ -z "${BASH_VERSION:-}" ] && exec /usr/bin/env bash "$0" "$@"
SCRIPT_ID="_symlink-chk-fix"; VERSION="v0.2.0"
MODE="check"; MIRROR_HOME="no"
usage(){ cat <<USAGE
$SCRIPT_ID $VERSION
Prüft ~/code/bin/<id> -> shellscripts/<id>.sh für alle *.sh in ~/code/bin/shellscripts.
Optionen: --check (Default) | --fix | --mirror-homebin | --help|--version
Ausgabe:
  Anzahl Skripts: N
  Anzahl Symlinks: N
  Symlinks defekt: N
  --check: defekte <id>-Liste; --fix: "<id> (repaired)"; --mirror-homebin: "<id> (mirrored)"
USAGE
}
for a in "$@"; do case "$a" in --help)usage;exit 0;;--version)echo "$VERSION";exit 0;;
 --check)MODE="check";; --fix)MODE="fix";; --mirror-homebin)MIRROR_HOME="yes";;
 *)echo "Unbekannte Option: $a"; usage; exit 2;; esac; done
BASE="$HOME/code/bin"; SHELLS="$BASE/shellscripts"; HOMBIN="$HOME/bin"
scripts=0; symlinks=0; defects=0; def_list=""; rep_list=""; mir_list=""; mkdir -p "$HOMBIN"
while IFS= read -r -d '' f; do
  id="${f##*/}"; id="${id%.sh}"; scripts=$((scripts+1))
  link="$BASE/$id"; canon="$SHELLS/$id.sh"
  if [ -L "$link" ]; then
    symlinks=$((symlinks+1))
    tgt="$(readlink -f "$link" 2>/dev/null || true)"; exp="$(readlink -f "$canon" 2>/dev/null || true)"
    if [ "$tgt" != "$exp" ] || [ ! -e "$tgt" ]; then defects=$((defects+1)); def_list+="${def_list:+$'\n'}$id"; [ "$MODE" = "fix" ] && { ln -sf "shellscripts/$id.sh" "$link"; rep_list+="${rep_list:+$'\n'}$id (repaired)"; }
  else
    defects=$((defects+1)); def_list+="${def_list:+$'\n'}$id"; [ "$MODE" = "fix" ] && { ln -sf "shellscripts/$id.sh" "$link"; rep_list+="${rep_list:+$'\n'}$id (repaired)"; symlinks=$((symlinks+1)); }
  fi
  if [ "$MIRROR_HOME" = "yes" ]; then ln -sf "$BASE/$id" "$HOMBIN/$id"; mir_list+="${mir_list:+$'\n'}$id (mirrored)"; fi
done < <(find "$SHELLS" -maxdepth 1 -type f -name '*.sh' -print0 2>/dev/null)
echo "Anzahl Skripts: $scripts"
echo "Anzahl Symlinks: $symlinks"
echo "Symlinks defekt: $defects"
[ "$defects" -gt 0 ] && { [ "$MODE" = "fix" ] && [ -n "$rep_list" ] && printf '%s\n' "$rep_list" || [ "$MODE" = "check" ] && [ -n "$def_list" ] && printf '%s\n' "$def_list"; }
[ "$MIRROR_HOME" = "yes" ] && [ -n "$mir_list" ] && printf '%s\n' "$mir_list"
exit 0
