#!/usr/bin/env bash
# bin-tree — minimale Verzeichnisübersicht für ~/code/bin
# SCRIPT_VERSION="v0.5.0"
# Änderungen ggü. v0.4.9:
# - Subheader in Markdown mit stabiler ID: {#bin-tree-subheader}
# - Pandoc-Variante für Kommentare bleibt: *(...)*{.comment} + --from=gfm+attributes
# - Nachlaufendes Stripping in latest.md: "*{.comment}" -> "*"

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_ID="bin-tree"
SCRIPT_VERSION="v0.5.0"

usage() {
  cat <<EOF
${SCRIPT_ID} ${SCRIPT_VERSION}
Listet ~/code/bin rekursiv (tree-ähnlich), je Ordner max. 2 Dateien; schreibt nach:
  - audits/bin-tree/latest.jsonl (JSONL)
  - audits/bin-tree/latest.md (Markdown)
  - audits/bin-tree/latest.html (HTML via pandoc, CSS: bin-tree.css im selben Ordner)
Ignoriert: .git/

Optionen:
  --help       Hilfe
  --version    Version
EOF
}

# Argparse
if [ "$#" -gt 0 ]; then
  for arg in "$@"; do
    case "$arg" in
      --help) usage; exit 0 ;;
      --version) echo "$SCRIPT_VERSION"; exit 0 ;;
      *) echo "Unbekannte Option: $arg" >&2; usage; exit 2 ;;
    esac
  done
fi

BASE_DIR="$HOME/code/bin"
AUDIT_DIR="$HOME/code/bin/shellscripts/audits/${SCRIPT_ID}"
OUT_JSONL="$AUDIT_DIR/latest.jsonl"
OUT_MD="$AUDIT_DIR/latest.md"
OUT_HTML="$AUDIT_DIR/latest.html"
CSS_NAME="bin-tree.css"
COMMENT_FILE="comment-bin-tree.txt"

[ -d "$BASE_DIR" ] || { echo "Fehler: Ordner nicht gefunden: $BASE_DIR" >&2; exit 1; }
mkdir -p "$AUDIT_DIR"

ts_iso()    { date +"%Y-%m-%dT%H:%M:%S%z"; }
ts_human()  { date +"%Y-%m-%d %H:%M:%S %Z"; }
script_path(){ readlink -f "$0" 2>/dev/null || printf "%s" "$0"; }

# JSON escaper
json_esc(){ local s="${1//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"; s="${s//$'\r'/}"; printf '%s' "$s"; }

# Markdown-escaper für Kommentar-Inhalt
md_esc_comment(){ sed -e 's/[\\*_{}\[\]]/\\&/g'; }

# Header/Subheader
printf '{"header":"%s - %s - Audit"}\n' "$SCRIPT_ID" "$(ts_iso)" >"$OUT_JSONL"
printf '{"subheader":"%s - %s"}\n' "$(script_path)" "$SCRIPT_VERSION" >>"$OUT_JSONL"

{
  echo "# Audit \`bin-tree\` — $(ts_human)"
  # stabile ID für Subheader
  echo "## $(script_path) - ${SCRIPT_VERSION} {#bin-tree-subheader}"
} >"$OUT_MD"

# Zähler
total_dirs=0
total_files=0
total_files_listed=0

md_bold()   { printf "**%s**" "$1"; }
md_italic() { printf "*%s*" "$1"; }

# Verzeichnisse rekursiv (ohne .git/)
while IFS= read -r dir; do
  total_dirs=$((total_dirs+1))

  if [ "$dir" = "$BASE_DIR" ]; then
    rel="bin/"; folder_name="bin"; depth=0
  else
    rel="${dir#$BASE_DIR/}/"; folder_name="$(basename "${rel%/}")"
    depth="$(awk -F'/' '{print NF}' <<<"${rel%/}")"
  fi

  # Kommentar (comment-bin-tree.txt), einzeilig, getrimmt
  COMMENT=""
  if [ -f "$dir/$COMMENT_FILE" ]; then
    COMMENT="$(sed -e 's/\r$//' "$dir/$COMMENT_FILE" | tr '\n' ' ' | sed -E 's/  +/ /g; s/^ *//; s/ *$//')"
  fi

  # Dateien (nur Ebene 1), alphabetisch, max 2
  mapfile -t files_all < <(find "$dir" -maxdepth 1 -type f -printf '%f\n' | LC_ALL=C sort)
  files_count="${#files_all[@]}"; total_files=$((total_files + files_count))

  show1=""; show2=""; files_more=0
  if [ "$files_count" -ge 1 ]; then show1="${files_all[0]}"; fi
  if [ "$files_count" -ge 2 ]; then show2="${files_all[1]}"; fi
  if [ "$files_count" -gt 2 ]; then files_more=$((files_count - 2)); fi

  listed=0; [ -n "$show1" ] && listed=$((listed+1)); [ -n "$show2" ] && listed=$((listed+1))
  total_files_listed=$((total_files_listed + listed))

  subdirs_count="$(find "$dir" -maxdepth 1 -mindepth 1 -type d ! -name '.git' | wc -l | awk '{print $1}')"

  # JSONL
  if [ -n "$show1" ] && [ -n "$show2" ]; then
    files_json='["'"$show1"'","'"$show2"'"]'
  elif [ -n "$show1" ]; then
    files_json='["'"$show1"'"]'
  else
    files_json='[]'
  fi
  if [ -n "$COMMENT" ]; then
    printf '{"dir":"%s","files":%s,"files_more":%s,"subdirs":%s,"comment":"%s"}\n' \
           "$rel" "$files_json" "$files_more" "$subdirs_count" "$(json_esc "$COMMENT")" >>"$OUT_JSONL"
  else
    printf '{"dir":"%s","files":%s,"files_more":%s,"subdirs":%s}\n' \
           "$rel" "$files_json" "$files_more" "$subdirs_count" >>"$OUT_JSONL"
  fi

  # Markdown: Ordnerzeile + Kommentar als *(...)*{.comment} (für Pandoc)
  indent="$(printf '%*s' $((depth*2)) '')"
  printf "%s- " "$indent" >>"$OUT_MD"
  md_bold "${folder_name}/" >>"$OUT_MD"
  printf " 📁" >>"$OUT_MD"
  if [ -n "$COMMENT" ]; then
    esc_comment="$(printf '%s' "$COMMENT" | md_esc_comment)"
    printf " *(%s)*{.comment}" "$esc_comment" >>"$OUT_MD"
  fi
  printf "\n" >>"$OUT_MD"

  # Dateien kursiv
  if [ -n "$show1" ]; then printf "%s  - " "$indent" >>"$OUT_MD"; md_italic "$show1" >>"$OUT_MD"; printf "\n" >>"$OUT_MD"; fi
  if [ -n "$show2" ]; then printf "%s  - " "$indent" >>"$OUT_MD"; md_italic "$show2" >>"$OUT_MD"; printf "\n" >>"$OUT_MD"; fi
  if [ "$files_more" -gt 0 ]; then echo "${indent}  - … ${files_more} weitere Datei(en)" >>"$OUT_MD"; fi

done < <(find "$BASE_DIR" -path '*/.git' -prune -o -type d -print | LC_ALL=C sort)

# Summary
files_more_total=$((total_files - total_files_listed))
printf '{"summary":{"total_dirs":%s,"total_files":%s,"total_files_listed":%s,"total_files_more":%s}}\n' \
  "$total_dirs" "$total_files" "$total_files_listed" "$files_more_total" >>"$OUT_JSONL"

{
  echo
  echo "## Summary"
  echo "- total_dirs: **${total_dirs}**"
  echo "- total_files: **${total_files}**"
  echo "- total_files_listed: **${total_files_listed}**"
  echo "- total_files_more: **${files_more_total}**"
} >>"$OUT_MD"

# HTML via pandoc (mit CSS-Link, KEIN Default-CSS) – nutzt die MD mit {.comment}
if command -v pandoc >/dev/null 2>&1; then
  ( cd "$AUDIT_DIR"
    pandoc "latest.md" \
      --from=gfm+attributes --to=html5 \
      --standalone \
      --metadata pagetitle="Audit \`bin-tree\` — $(ts_human)" \
      --css "$CSS_NAME" \
      --output "latest.html"
  ) || echo "Warnung: pandoc-Konvertierung fehlgeschlagen." >&2
else
  echo "Hinweis: pandoc nicht gefunden – HTML wurde nicht erzeugt." >&2
fi

# Nachbearbeitung: {.comment} in Markdown entfernen (aber NACH dem HTML-Build)
if [ -f "$OUT_MD" ]; then
  sed -i 's/\*[[:space:]]*[{]\.comment[}]/\*/g' "$OUT_MD" || true
fi

# Editor-Refresh
touch -c -m "$OUT_JSONL" "$OUT_MD" "$OUT_HTML" 2>/dev/null || true
exit 0
