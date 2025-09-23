#!/usr/bin/env bash
# audit-shellscripts — Report über ~/code/bin/shellscripts
# Version: v0.4.1
# Änderungen ggü. v0.4.0:
# - Subheader mit stabiler ID: {#audit-shellscripts-subheader}
# - Pandoc auf --from=gfm+attributes, damit ID sicher gesetzt wird

set -euo pipefail
IFS=$'\n\t'

SCRIPT_VERSION="v0.4.1"

ROOT="${HOME}/code/bin/shellscripts"
OUT_DIR="${ROOT}/audits/audit-shellscripts"
OUT_MD="${OUT_DIR}/latest.md"
OUT_JSON="${OUT_DIR}/latest.json"
OUT_HTML="${OUT_DIR}/latest.html"
CSS_FILE="${OUT_DIR}/audit-shellscripts.css"

NBH=$'\u2011'
SORT_COL="modified"  # created|changed|modified|accessed

# --- Args ---------------------------------------------------------------------
for arg in "$@"; do
  case "$arg" in
    --sort=*)
      SORT_COL="${arg#*=}"; SORT_COL="${SORT_COL,,}"
      case "$SORT_COL" in
        created|changed|modified|accessed) : ;;
        *) echo "Unbekannte Sortierspalte: $SORT_COL (erlaubt: Created|Changed|Modified|Accessed)"; exit 2 ;;
      esac
      ;;
    --help|-h)
      echo "Usage: audit-shellscripts [--sort=Created|Changed|Modified|Accessed]"
      exit 0
      ;;
    *)
      echo "Unbekannte Option: $arg"; echo "Nutze --help"; exit 2 ;;
  esac
done

mkdir -p "$OUT_DIR"

human_size() {
  local b="${1:-0}"
  if [ "$b" -lt 1000 ] 2>/dev/null; then printf "%dB" "$b"; return; fi
  if command -v numfmt >/dev/null 2>&1; then
    out="$(numfmt --to=si --suffix=B --format='%.1f' "$b" 2>/dev/null || echo "")"
    [ -n "$out" ] && { printf "%s" "${out/kB/KB}"; return; }
  fi
  awk -v b="$b" '
    function fmt(x,u){ printf("%.1f%s", x, u); exit }
    BEGIN{
      if (b>=1e12)      fmt(b/1e12,"TB");
      else if (b>=1e9)  fmt(b/1e9,"GB");
      else if (b>=1e6)  fmt(b/1e6,"MB");
      else              fmt(b/1e3,"KB");
    }'
}

json_escape() { printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'; }

ts_header="$(date '+%Y-%m-%d %H:%M:%S %Z')"
SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || printf "%s" "$0")"

TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT

if [ ! -d "$ROOT" ]; then
  {
    printf "# Audit \`/shellscripts\` — %s\n\n" "$ts_header"
    printf "## %s - %s {#audit-shellscripts-subheader}\n\n" "$SCRIPT_PATH" "$SCRIPT_VERSION"
    printf "_Hinweis: Verzeichnis %s nicht gefunden._\n" "$ROOT"
  } > "$OUT_MD"
  printf '{ "ts": %s, "root": %s, "error": %s }\n' \
    "$(json_escape "$ts_header")" "$(json_escape "$ROOT")" "$(json_escape "not found")" > "$OUT_JSON"
  if command -v pandoc >/dev/null 2>&1; then
    (
      cd "$OUT_DIR"
      css_opt=""
      [ -f "$CSS_FILE" ] && css_opt="-c $(basename "$CSS_FILE")"
      pandoc -s -f gfm+attributes -t html5 \
        --metadata pagetitle="Audit /shellscripts — ${ts_header}" \
        $css_opt \
        -o "$(basename "$OUT_HTML")" "$(basename "$OUT_MD")"
    )
  fi
  exit 0
fi

# --- Daten sammeln ------------------------------------------------------------
shopt -s nullglob
for f in "$ROOT"/*.sh; do
  [ -f "$f" ] || continue
  base="$(basename "$f")"
  script="${base%.sh}"
  catg="${script%%-*}"; [ "$catg" = "$script" ] && catg="uncategorized"

  ver="$(awk -F: '/^# *Version:/ {gsub(/^[ \t]+/, "", $2); print $2; exit}' "$f" || true)"
  if [ -z "$ver" ]; then
    ver="$(grep -E '^[[:space:]]*SCRIPT_VERSION=' "$f" | head -n1 | sed -E 's/.*SCRIPT_VERSION=["'"'"']?([^"'"'"']+)["'"'"']?.*/\1/' || true)"
  fi
  [ -z "$ver" ] && ver="-"

  at_s="$(stat -c %X "$f" 2>/dev/null || echo 0)"
  mo_s="$(stat -c %Y "$f" 2>/dev/null || echo 0)"
  ch_s="$(stat -c %Z "$f" 2>/dev/null || echo 0)"
  cr_s="$(stat -c %W "$f" 2>/dev/null || echo 0)"
  sz_b="$(stat -c %s "$f" 2>/dev/null || echo 0)"

  accessed="$(date -u -d "@$at_s" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo '-')"
  modified="$(date -u -d "@$mo_s" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo '-')"
  changed="$(date -u -d "@$ch_s" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo '-')"
  if [ "${cr_s:-0}" -gt 0 ] 2>/dev/null; then
    created="$(date -u -d "@$cr_s" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo '-')"
  else
    created="-"
  fi

  link_target="$HOME/code/bin/$script"
  link_status="-"
  if [ -L "$link_target" ]; then
    if [ -e "$link_target" ]; then link_status="✅"; else link_status="❌"; fi
  elif [ -e "$link_target" ]; then
    link_status="✅"
  fi

  printf "%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n" \
    "$catg" "$script" "$ver" "$created" "$changed" "$modified" "$accessed" "$sz_b" \
    "$cr_s" "$ch_s" "$mo_s" "$at_s" "$link_status" >> "$TMP"
done
shopt -u nullglob

case "$SORT_COL" in
  created)  SORT_IDX=9 ;;
  changed)  SORT_IDX=10 ;;
  modified) SORT_IDX=11 ;;
  accessed) SORT_IDX=12 ;;
  *) SORT_IDX=11 ;;
esac

mapfile -t CATS < <(cut -d'|' -f1 "$TMP" | sort -u)

{
  printf "# Audit \`/shellscripts\` — %s\n\n" "$ts_header"
  printf "## %s - %s {#audit-shellscripts-subheader}\n\n" "$SCRIPT_PATH" "$SCRIPT_VERSION"

  if [ ! -s "$TMP" ]; then
    echo "_Keine Skripte gefunden._"
  else
    total_scripts=0
    total_bytes=0

    for c in "${CATS[@]}"; do
      printf "### Kategorie: %s\n\n" "$c"
      echo "| Script | Version | Created | Changed | Modified | Accessed | Size | Link |"
      echo "|---|---|---|---|---|---|---|---|"

      while IFS='|' read -r cat script ver created changed modified accessed size cr_s ch_s mo_s at_s link_status; do
        [ "$cat" = "$c" ] || continue
        script_nb="${script//-/$NBH}"
        hs="$(human_size "$size")"

        c_created="$created"; c_changed="$changed"; c_modified="$modified"; c_accessed="$accessed"
        case "$SORT_COL" in
          created)  c_created="*$created*" ;;
          changed)  c_changed="*$changed*" ;;
          modified) c_modified="*$modified*" ;;
          accessed) c_accessed="*$accessed*" ;;
        esac

        printf "| \`%s\` | %s | %s | %s | %s | %s | %s | %s |\n" \
          "$script_nb" "$ver" "$c_created" "$c_changed" "$c_modified" "$c_accessed" "$hs" "$link_status"

        total_scripts=$((total_scripts+1))
        total_bytes=$((total_bytes + size))
      done < <(awk -F'|' -v C="$c" '$1==C' "$TMP" | sort -t'|' -k${SORT_IDX},${SORT_IDX}nr)

      echo
    done

    echo "### Summary"
    echo
    echo "- Kategorien: **${#CATS[@]}**"
    echo "- Skripte gesamt: **${total_scripts}**"
    echo "- Gesamtgröße: **$(human_size "$total_bytes")**"
  fi
} > "$OUT_MD"

{
  printf '{\n'
  printf '  "ts": %s,\n' "$(json_escape "$ts_header")"
  printf '  "root": %s,\n' "$(json_escape "$ROOT")"
  printf '  "sort": %s,\n' "$(json_escape "$SORT_COL")"
  printf '  "script_path": %s,\n' "$(json_escape "$SCRIPT_PATH")"
  printf '  "script_version": %s,\n' "$(json_escape "$SCRIPT_VERSION")"
  printf '  "categories": [\n'
  for i in "${!CATS[@]}"; do
    c="${CATS[$i]}"
    printf '    { "name": %s, "scripts": [\n' "$(json_escape "$c")"
    rows="$(awk -F'|' -v C="$c" '$1==C' "$TMP" | sort -t'|' -k${SORT_IDX},${SORT_IDX}nr)"
    n=0
    while IFS='|' read -r cat script ver created changed modified accessed size cr_s ch_s mo_s at_s link_status; do
      [ -z "$script" ] && continue
      [ $n -gt 0 ] && printf ',\n'
      printf '      { "script": %s, "version": %s, "created": %s, "changed": %s, "modified": %s, "accessed": %s, "size_bytes": %s, "size_h": %s, "link": %s }' \
        "$(json_escape "$script")" \
        "$(json_escape "$ver")" \
        "$(json_escape "$created")" \
        "$(json_escape "$changed")" \
        "$(json_escape "$modified")" \
        "$(json_escape "$accessed")" \
        "$size" \
        "$(json_escape "$(human_size "$size")")" \
        "$(json_escape "$link_status")"
      n=$((n+1))
    done <<< "$rows"
    printf '\n    ] }'
    [ $i -lt $(( ${#CATS[@]} - 1 )) ] && printf ',\n' || printf '\n'
  done
  printf '  ]\n'
  printf '}\n'
} > "$OUT_JSON"

# HTML via Pandoc (mit CSS-Link)
if command -v pandoc >/dev/null 2>&1; then
  (
    cd "$OUT_DIR"
    css_opt=""
    [ -f "$CSS_FILE" ] && css_opt="-c $(basename "$CSS_FILE")"
    pandoc -s -f gfm+attributes -t html5 \
      --metadata pagetitle="Audit /shellscripts — ${ts_header}" \
      $css_opt \
      -o "$(basename "$OUT_HTML")" "$(basename "$OUT_MD")"
  )
fi

echo "OK: $OUT_MD"
echo "OK: $OUT_JSON"
