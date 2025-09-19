#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# _sh-chmod — Setzt alle *.sh unter ~/code/bin/shellscripts/ auf Modus 0744
# Läuft NUR aus ~/code/bin. Mit --dry-run und --no-color. Summary am Ende.
# -----------------------------------------------------------------------------
set -euo pipefail
IFS=$'\n\t'

NO_COLOR_FORCE="no"
DRY_RUN="no"
for arg in "$@"; do
  case "$arg" in
    --no-color) NO_COLOR_FORCE="yes" ;;
    --dry-run)  DRY_RUN="yes" ;;
    --help|-h)  echo "Usage: _sh-chmod [--dry-run] [--no-color]"; exit 0 ;;
    *) echo "Unbekannte Option: $arg"; echo "Nutze --help"; exit 2;;
  esac
done

# Farben
BOLD=""; YEL=""; GRN=""; RED=""; BLU=""; RST=""
if [ "$NO_COLOR_FORCE" != "yes" ] && [ -z "${NO_COLOR:-}" ] && [ -t 1 ]; then
  BOLD=$'\033[1m'; YEL=$'\033[33m'; GRN=$'\033[32m'; RED=$'\033[31m'; BLU=$'\033[34m'; RST=$'\033[0m'
fi

BIN_PATH="$HOME/code/bin"
if [ "$(pwd -P)" != "$BIN_PATH" ]; then
  printf "%sGatekeeper:%s %sNur aus%s %s%s%s %sausführbar.%s\n" "$BOLD$YEL" "$RST" "$RED" "$RST" "$BLU" "$BIN_PATH" "$RST" "$RED" "$RST"
  exit 2
fi

TARGET="$HOME/code/bin/shellscripts"
[ -d "$TARGET" ] || { printf "%sFehler:%s Verzeichnis fehlt: %s\n" "$RED" "$RST" "$TARGET"; exit 3; }

changed=0 ok=0 total=0
while IFS= read -r -d '' f; do
  total=$((total+1))
  # Nur reguläre Dateien
  [ -f "$f" ] || continue
  mode="$(stat -c '%a' "$f" 2>/dev/null || echo '?')"
  if [ "$mode" != "744" ]; then
    if [ "$DRY_RUN" = "yes" ]; then
      printf "%sDRY-RUN:%s setze 744: %s\n" "$YEL" "$RST" "$f"
    else
      chmod 0744 -- "$f"
      printf "%sSET 744:%s %s\n" "$GRN" "$RST" "$f"
    fi
    changed=$((changed+1))
  else
    ok=$((ok+1))
  fi
done < <(find "$TARGET" -type f -name '*.sh' -print0)

printf "%s%d Skripte geändert (744 gesetzt);%s %s\n" "$GRN" "$changed" "$RST" "$TARGET"
printf "%s%d Skripte geprüft (744 OK);%s %s\n"     "$BLU" "$ok"      "$RST" "$TARGET"
printf "%s%d Skripte gesamt;%s %s\n"              "$BOLD" "$total"  "$RST" "$TARGET"
exit 0
