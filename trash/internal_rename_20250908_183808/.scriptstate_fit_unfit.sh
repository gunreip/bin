#!/usr/bin/env bash
# .scriptstate_fit_unfit.sh — setzt/aktualisiert SCRIPT_STATE in einem Ziel-Skript im ~/bin
# v0.1.0
#
# shellcheck disable=

set -euo pipefail

BIN_DIR="${HOME}/bin"

usage() {
  cat <<'HLP'
.scriptstate_fit_unfit.sh --script=<name|name.sh> --state=fit|unfit
  Gatekeeper: nur im ~/bin ausführen.

Beispiele:
  .scriptstate_fit_unfit.sh --script=laravel_workspace_scan --state=fit
  .scriptstate_fit_unfit.sh --script=pg_quickcheck.sh        --state=unfit
HLP
}

# Gatekeeper
if [[ "$(pwd -P)" != "${BIN_DIR}" ]]; then
  echo "❌ Gatekeeper: bitte im Ordner ${BIN_DIR} ausführen." >&2
  exit 2
fi

# Args
TARGET_BASE=""
STATE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --script=*) TARGET_BASE="${1#*=}"; shift;;
    --state=*)  STATE="${1#*=}"; shift;;
    --help|-h)  usage; exit 0;;
    --version)  echo ".scriptstate_fit_unfit.sh v0.1.0"; exit 0;;
    *) echo "Unbekannte Option: $1" >&2; usage; exit 64;;
  esac
done

[[ -z "$TARGET_BASE" || -z "$STATE" ]] && { usage; exit 64; }

# Target normalisieren (nur Basename; erlaube name oder name.sh)
TARGET_BASE="$(basename -- "$TARGET_BASE")"
if [[ "$TARGET_BASE" != *.sh ]]; then TARGET_BASE="${TARGET_BASE}.sh"; fi
TARGET="${BIN_DIR}/${TARGET_BASE}"

# Ziel prüfen
if [[ ! -f "$TARGET" ]]; then
  echo "❌ Zielskript nicht gefunden: $TARGET_BASE" >&2
  exit 3
fi
if [[ ! -w "$TARGET" ]]; then
  echo "❌ Keine Schreibrechte für: $TARGET_BASE" >&2
  exit 4
fi

# state → 1/0
case "${STATE,,}" in
  fit|1|yes|true)  NEW="1" ;;
  unfit|0|no|false) NEW="0" ;;
  *) echo "❌ Ungültiger --state: $STATE (erwartet: fit|unfit)" >&2; exit 64;;
esac

# Backup vom Zielskript
TS="$(date +%Y%m%d_%H%M%S)"
BAK_DIR="${BIN_DIR}/backups/${TARGET_BASE%.sh}"
mkdir -p "$BAK_DIR"
cp -a "$TARGET" "$BAK_DIR/${TARGET_BASE}.bak.${TS}"

# Einfügeposition bestimmen: nach "# shellcheck disable=" oder nach Shebang, sonst an Anfang
insert_after_line=0
if grep -qn '^# shellcheck disable=' -- "$TARGET"; then
  insert_after_line="$(grep -n '^# shellcheck disable=' -- "$TARGET" | head -n1 | cut -d: -f1)"
elif head -n1 -- "$TARGET" | grep -q '^#!'; then
  insert_after_line=1
else
  insert_after_line=0
fi

# Falls vorhanden: ersetzen, sonst einfügen
if grep -qE '^[[:space:]]*SCRIPT_STATE=[01][[:space:]]*$' -- "$TARGET"; then
  # ersetzen
  sed -i -E 's/^[[:space:]]*SCRIPT_STATE=[01][[:space:]]*$/SCRIPT_STATE='"$NEW"'/' "$TARGET"
else
  # einfügen
  if (( insert_after_line > 0 )); then
    awk -v ln="$insert_after_line" -v val="$NEW" '
      NR==ln { print; print "SCRIPT_STATE=" val; next } { print }
    ' "$TARGET" > "${TARGET}.tmp" && mv "${TARGET}.tmp" "$TARGET"
  else
    printf 'SCRIPT_STATE=%s\n' "$NEW" | cat - "$TARGET" > "${TARGET}.tmp" && mv "${TARGET}.tmp" "$TARGET"
  fi
fi

echo "✅ SCRIPT_STATE=${NEW} gesetzt in ${TARGET_BASE}"

# Checkliste aktualisieren, falls vorhanden
if [[ -x "${BIN_DIR}/.checklist_shellscripts.sh" ]]; then
  ( cd "${BIN_DIR}" && ./.checklist_shellscripts.sh >/dev/null 2>&1 || true )
fi

exit 0
