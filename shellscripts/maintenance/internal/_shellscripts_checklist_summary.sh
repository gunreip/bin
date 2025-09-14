#!/usr/bin/env bash
# _shellscripts_checklist_summary.sh — Summary der Checklist
# v0.4.0  (neu: Reports via _reports_core → ~/bin/reports/shellscripts_checklist_summary/)
set -euo pipefail
IFS=$'\n\t'; LC_ALL=C; LANG=C

SCRIPT_VERSION="v0.4.0"

QUIET=0
FORCE_REFRESH=1   # 1 = ruft checklist vorher auf; 0 = nur vorhandene JSON lesen
for a in "$@"; do
  case "$a" in
    --quiet|-q) QUIET=1;;
    --no-refresh) FORCE_REFRESH=0;;
    --help|-h) echo "Usage: shellscripts_checklist_summary [--no-refresh] [--quiet]"; exit 0;;
    *) echo "Unknown arg: $a"; exit 64;;
  esac
done

BIN_DIR="${HOME}/bin"
CHECK_JSON="${BIN_DIR}/reports/shellscripts_checklist/latest.json"

# ggf. vorher Checklist laufen lassen (schreibt latest.json)
if (( FORCE_REFRESH == 1 )); then
  if command -v shellscripts_checklist >/dev/null 2>&1; then
    shellscripts_checklist >/dev/null
  fi
fi

# Fallback: wenn JSON fehlt
if [[ ! -f "$CHECK_JSON" ]]; then
  echo "⚠️  Missing: $CHECK_JSON" >&2
  # schreibe Minimal-Report und raus
  source "$HOME/bin/shellscripts/maintenance/internal/_reports_core.sh"
  reports_init "shellscripts_checklist_summary" "${HOME}/bin/reports" 5
  reports_write_md $'# Zusammenfassung\n\n*(Keine Daten gefunden – Checklist vorher laufen lassen.)*'
  reports_write_json '{"error":"missing checklist json"}'
  reports_rotate; reports_paths_echo
  exit 0
fi

# Zählung via jq
if ! command -v jq >/dev/null 2>&1; then
  echo "❌ jq not found." >&2
  exit 1
fi

total="$(jq '.items | length' "$CHECK_JSON")"
fit="$(jq '[.items[] | select(.state==1)] | length' "$CHECK_JSON")"
unfit="$(( total - fit ))"
ok="$(jq '[.items[] | select(.guilty=="ok")] | length' "$CHECK_JSON")"
warn="$(jq '[.items[] | select(.guilty=="warning")] | length' "$CHECK_JSON")"
err="$(jq '[.items[] | select(.guilty=="missing")] | length' "$CHECK_JSON")"

# ── Reports via _reports_core ───────────────────────────────────────────────
source "$HOME/bin/shellscripts/maintenance/internal/_reports_core.sh"
reports_init "shellscripts_checklist_summary" "${HOME}/bin/reports" 5

# Markdown
{
  echo "# Zusammenfassung:"
  echo
  echo "- **Skripte gesamt:** ${total}"
  echo "- **fit:** ${fit}"
  echo "- **unfit:** ${unfit}"
  echo "- **Symlinks:**"
  echo "  - okay: ${ok}"
  echo "  - warnings: ${warn}"
  echo "  - errors: ${err}"
} > /tmp/.scl_sum.md

# JSON
printf '{ "total": %s, "fit": %s, "unfit": %s, "symlinks": { "ok": %s, "warning": %s, "error": %s } }\n' \
  "$total" "$fit" "$unfit" "$ok" "$warn" "$err" > /tmp/.scl_sum.json

reports_write_md   "$(cat /tmp/.scl_sum.md)"
reports_write_json "$(cat /tmp/.scl_sum.json)"
reports_rotate
reports_paths_echo

(( QUIET )) || echo "✅ Summary aktualisiert."
exit 0
