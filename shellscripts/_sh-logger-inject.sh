#!/usr/bin/env bash
# _sh-logger-inject — hängt logfx in Skripte unter ~/code/bin/shellscripts/ ein
# Version: v0.2.0
set -euo pipefail
IFS=$'\n\t'

ROOT="${HOME}/code/bin/shellscripts"
BK="${ROOT}/backups/_sh-logger-inject"
mkdir -p "$BK"

usage(){
  cat <<H
_sh-logger-inject v0.2.0
Usage:
  _sh-logger-inject [--dry-run] [--no-color] [--only=<glob>] [--exclude=<glob>]

- Sucht alle *.sh in ${ROOT} (rekursiv NICHT).
- Fügt direkt nach dem Shebang einen idempotenten Block ein, falls nicht vorhanden.
- Setzt LOG_LEVEL default=trace; lädt lib/logfx.sh; ruft logfx_init mit Script-ID.
H
}

DRY="no"; NOCLR="no"; ONLY=""; EXC=""
for a in "$@"; do
  case "$a" in
    --help) usage; exit 0 ;;
    --dry-run) DRY="yes" ;;
    --no-color) NOCLR="yes" ;;
    --only=*) ONLY="${a#*=}" ;;
    --exclude=*) EXC="${a#*=}" ;;
    *) echo "Unbekannte Option: $a"; usage; exit 2 ;;
  esac
done

pfx(){ if [ "$NOCLR" = "yes" ] || [ -n "${NO_COLOR:-}" ] || ! [ -t 1 ]; then echo "[INFO]"; else printf '\033[34m%s\033[0m' "[INFO]"; fi; }

inject_block='
# >>> LOGFX INIT >>>
: "${LOG_LEVEL:=trace}"
# shellcheck source=/dev/null
. "$HOME/code/bin/shellscripts/lib/logfx.sh"
logfx_init "${SCRIPT_ID:-$(basename "$0" .sh)}" "${LOG_LEVEL}"
# <<< LOGFX INIT <<<
'

count=0
for f in "$ROOT"/*.sh; do
  [ -f "$f" ] || continue
  base="$(basename "$f")"
  [ -n "$ONLY" ] && [[ ! "$base" == $ONLY ]] && continue
  [ -n "$EXC" ] && [[ "$base" == $EXC ]] && continue
  if grep -q '<<< LOGFX INIT <<<' "$f"; then
    echo "$(pfx) skip (bereits vorhanden) - $base"
    continue
  fi
  cp -p "$f" "$BK/${base}.$(date -u +%Y%m%d-%H%M%S).bak"
  if [ "$DRY" = "yes" ]; then
    echo "$(pfx) DRY inject - $base"
  else
    # nach Shebang einfügen
    if head -n1 "$f" | grep -q '^#!'; then
      { head -n1 "$f"; printf "%s\n" "$inject_block"; tail -n +2 "$f"; } > "$f.tmp" && mv "$f.tmp" "$f"
    else
      { printf '%s\n' "#!/usr/bin/env bash"; printf "%s\n" "$inject_block"; cat "$f"; } > "$f.tmp" && mv "$f.tmp" "$f"
      chmod +x "$f"
    fi
    echo "$(pfx) injected - $base"
  fi
  count=$((count+1))
done

echo "$(pfx) fertig: $count Datei(en) bearbeitet."
