#!/usr/bin/env bash
set -euo pipefail

# Ziel-Dateien
WRITER="${HOME}/bin/_backup_shell_script.sh"
RENDER="${HOME}/bin/log_render_html.sh"

# Backup-Ordner
BKDIR="${HOME}/bin/backups"
mkdir -p "$BKDIR"
TS="$(date +%Y%m%dT%H%M%S)"

cp -a "$WRITER" "${BKDIR}/_backup_shell_script.sh.${TS}.bak"
cp -a "$RENDER" "${BKDIR}/log_render_html.sh.${TS}.bak"

echo "🔧 Patching ${WRITER} …"
tmp="$(mktemp)"
awk '
  # Ersetze die Zeile, die MD_FILE und JSON_FILE auf LOG-<date> setzt,
  # durch einen kleinen Block mit Bin-Prefix-Logik (_bin-…)
  /^MD_FILE="\$\{MD_DIR\}\/LOG-\$\{D_compact\}\.md"; JSON_FILE="\$\{JSON_DIR\}\/LOG-\$\{D_compact\}\.jsonl"$/ {
    print "MD_FILE_BASENAME=\"LOG-${D_compact}\""
    print "if [[ \"$LOG_ROOT\" == \"${HOME}/bin\" ]]; then MD_FILE_BASENAME=\"_bin-LOG-${D_compact}\"; fi"
    print "MD_FILE=\"${MD_DIR}/${MD_FILE_BASENAME}.md\"; JSON_FILE=\"${JSON_DIR}/${MD_FILE_BASENAME}.jsonl\""
    next
  }
  { print }
' "$WRITER" > "$tmp" && mv "$tmp" "$WRITER"

echo "🔧 Patching ${RENDER} (lc_init_ctx → BIN JSON/MD Basename) …"
# In lc_init_ctx nach der Standard-JSON_FILE-Zuweisung eine BIN-Override-Zeile einfügen
# (nur für ROOT == $HOME/bin). Das lässt PRIMARY unverändert.
tmp="$(mktemp)"
# - matcht die JSON_FILE Standardzeile mit LOG-${Dcomp}.jsonl
sed -E '/^[[:space:]]*JSON_FILE="\$\{JSON_DIR\}\/LOG-\$\{Dcomp\}\.jsonl"[[:space:]]*$/a\
if [[ "$ROOT" == "${HOME}/bin" ]]; then MD_FILE="$MD_DIR/_bin-LOG-${Dcomp}.md"; JSON_FILE="$JSON_DIR/_bin-LOG-${Dcomp}.jsonl"; fi
' "$RENDER" > "$tmp" && mv "$tmp" "$RENDER"

# Rechte setzen
chmod 755 "$WRITER" "$RENDER"

echo "✅ Patch fertig."
echo "Backups: ${BKDIR}/_backup_shell_script.sh.${TS}.bak und ${BKDIR}/log_render_html.sh.${TS}.bak"
echo
echo "Kurzer Smoke-Test (optional):"
echo "  - Bin-Writer einen Eintrag erzeugen lassen (egal welcher):"
echo "    ${WRITER##${HOME}/}/ --help >/dev/null 2>&1 || true"
echo "  - Renderer laufen lassen:"
echo "    ${RENDER##${HOME}/} --debug=ON"
echo
echo "Erwartet:"
echo "  ~/bin/.wiki/logs/json/YYYY/_bin-LOG-YYYYMMDD.jsonl (neu)"
echo "  ~/bin/.wiki/logs/YYYY/_bin-LOG-YYYYMMDD.md (wie gewünscht)"
