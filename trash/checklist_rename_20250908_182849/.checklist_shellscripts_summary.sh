#!/usr/bin/env bash
# .checklist_shellscripts_summary.sh — baut die Checkliste und hängt eine Zusammenfassung an
# v0.2.1
set -euo pipefail
IFS=$'\n\t'

BIN_DIR="${HOME}/bin"
MD_FILE="${BIN_DIR}/.checklist_shellscripts.md"
CHECKER="${BIN_DIR}/.checklist_shellscripts.sh"

# Gatekeeper
if [[ "$(pwd -P)" != "${BIN_DIR}" ]]; then
  echo "❌ Gatekeeper: bitte im Ordner ${BIN_DIR} ausführen." >&2
  exit 2
fi

# Fallback: falls Checker intern oder nur als Symlink ohne .sh existiert
if [[ ! -x "${CHECKER}" ]]; then
  if CAND="$(command -v .checklist_shellscripts 2>/dev/null || true)"; then
    CHECKER="$CAND"
  elif [[ -x "${BIN_DIR}/maintenance/internal/.checklist_shellscripts.sh" ]]; then
    CHECKER="${BIN_DIR}/maintenance/internal/.checklist_shellscripts.sh"
  fi
fi
[[ -x "${CHECKER}" ]] || { echo "❌ fehlt/unklar: ${CHECKER}"; exit 3; }

# 1) Checkliste erstellen/aktualisieren
"$CHECKER" >/dev/null

# 2) Zusammenfassung anhängen (alte entfernen)
[[ -f "${MD_FILE}" ]] || { echo "❌ Datei fehlt: ${MD_FILE}"; exit 4; }
TMP="$(mktemp)"
sed '/^\*\*Zusammenfassung\*\*$/,$d' "${MD_FILE}" > "${TMP}"

total=$(grep -E '^\| `[^`]+` \|' "${TMP}" | wc -l | tr -d ' ')
fit=$(grep -E '^\| `[^`]+` \|.*✅' "${TMP}" | wc -l | tr -d ' ')
unfit=$(( total - fit ))

{
  cat "${TMP}"
  echo
  echo "**Zusammenfassung**"
  echo
  printf 'Anzahl Skripte gesamt: %d<br />Anzahl Skripte fit: %d<br />Anzahl Skripte unfit: %d\n' "$total" "$fit" "$unfit"
} > "${MD_FILE}"
rm -f "${TMP}"

echo "✅ Checkliste + Zusammenfassung aktualisiert: ${MD_FILE}"
