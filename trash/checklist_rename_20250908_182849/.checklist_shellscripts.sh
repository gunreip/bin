#!/usr/bin/env bash
# .checklist_shellscripts.sh — Markdown-Checkliste der Shell-Skripte in ~/bin (liest SCRIPT_STATE)
# v0.3.1
#
# Sucht rekursiv in: install/ scans/ reports/ ops/ maintenance/
# maintenance/internal wird jetzt mit erfasst.
# Ausgabe: ~/bin/.checklist_shellscripts.md

set -euo pipefail
IFS=$'\n\t'

BIN_DIR="${HOME}/bin"
OUT_MD="${BIN_DIR}/.checklist_shellscripts.md"

# Gatekeeper
if [[ "$(pwd -P)" != "${BIN_DIR}" ]]; then
  echo "❌ Gatekeeper: bitte im Ordner ${BIN_DIR} ausführen." >&2
  exit 2
fi

# Version aus Skriptkopf extrahieren (best effort)
get_version() {
  local f="$1" head v
  head="$(head -n 120 -- "$f" 2>/dev/null || true)"
  v="$(printf '%s\n' "$head" \
      | sed -nE 's/.*SCRIPT_VERSION[[:space:]]*=[[:space:]]*["'"'"']?([vV]?[0-9]+(\.[0-9]+){1,3}([._-][A-Za-z0-9]+)?)["'"'"']?.*/\1/p' \
      | head -n1)"
  [[ -z "$v" ]] && v="$(printf '%s\n' "$head" \
      | sed -nE 's/^#.*[Vv]ersion[:[:space:]]*([vV]?[0-9]+(\.[0-9]+){1,3}([._-][A-Za-z0-9]+)?).*/\1/p' \
      | head -n1)"
  [[ -z "$v" ]] && v="$(printf '%s\n' "$head" \
      | sed -nE 's/^#.*\b(v[0-9]+(\.[0-9]+){1,3}([._-][A-Za-z0-9]+)?).*/\1/p' \
      | head -n1)"
  [[ -z "$v" ]] && v="unknown"
  [[ "$v" != v* && "$v" != V* && "$v" != unknown ]] && v="v${v}"
  printf '%s' "$v"
}

# SCRIPT_STATE ermitteln: 1=fit, 0=unfit (Default: 0)
get_state() {
  local f="$1" head s
  head="$(head -n 200 -- "$f" 2>/dev/null || true)"
  s="$(printf '%s\n' "$head" | sed -nE 's/^[[:space:]]*SCRIPT_STATE=([01])[[:space:]]*$/\1/p' | head -n1)"
  [[ -z "$s" ]] && s="0"
  printf '%s' "$s"
}

# Skripte einsammeln (rekursiv über Kategorien; internal jetzt inkl.)
mapfile -d '' -t FILES < <(
  find install scans reports ops maintenance -type f -name '*.sh' -printf '%p\0' 2>/dev/null | LC_ALL=C sort -z
)

# Markdown schreiben
{
  echo "# Shellskript-Checkliste"
  echo
  TZ="Europe/Berlin" date +"_Stand:_ %Y-%m-%d %H:%M %Z"
  echo
  echo "| Skript-Name | Version | okay |"
  echo "|---|---|---|"
  for f in "${FILES[@]}"; do
    v="$(get_version "$f")"
    s="$(get_state  "$f")"
    mark="❌"; [[ "$s" == "1" ]] && mark="✅"
    printf '| `%s` | %s | %s |\n' "$f" "$v" "$mark"
  done
} > "${OUT_MD}"

echo "✅ geschrieben: ${OUT_MD}"
