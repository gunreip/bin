#!/usr/bin/env bash
# manpages-install.sh
# Version: v0.3.0
set -Eeuo pipefail; IFS=$'\n\t'

SCRIPT_ID="manpages-install"
VERSION="v0.3.0"

trap 'rc=$?; echo "ERROR: ${BASH_SOURCE##*/}:${LINENO}: exit $rc while running: ${BASH_COMMAND:-<none>}"; exit $rc' ERR

# Defaults
SRC_DEFAULT="$HOME/code/bin/shellscripts/man"
DST_DEFAULT="/usr/local/share/man"
INDEX_NAME_DEFAULT=".mirror-manpages-install.index"  # Plain
MANDO="yes"
APPLY="yes"     # --dry-run schaltet auf Vorschau
DRY_RUN="no"
AUDIT="no"      # --audit aktiviert Audit (append MD, Pandoc zu HTML, CSS nur wenn fehlt)

# Helpers
short(){ printf '%s\n' "${1/#$HOME/~}"; }
abspath(){ command -v readlink >/dev/null 2>&1 && readlink -f "$1" 2>/dev/null || printf '%s' "$1"; }
now_iso(){ date '+%Y-%m-%d %H:%M:%S'; }  # ohne TZ-Offset (wie gewünscht)
usage(){ cat <<USAGE
$SCRIPT_ID $VERSION
Spiegelt Manpages nach /usr/local/share/man. Apply schreibt Plain+JSON Index.
--audit: latest.md (append), pandoc->latest.html, CSS nur wenn nicht vorhanden.

Optionen:
  --src=PATH            Quelle (Default: $SRC_DEFAULT)
  --dst=PATH            Ziel (Default: $DST_DEFAULT)
  --index=FILENAME      Basisname des Plain-Index (Default: $INDEX_NAME_DEFAULT)
  --dry-run             Nur Vorschau (kein sudo, kein Schreiben)
  --apply               Anwenden (Default) – auto-sudo bei fehlenden Rechten
  --mandb=yes|no        man-Datenbank aktualisieren (Default: yes)
  --audit               Audit-Artefakte erzeugen (MD append + HTML via pandoc)
  --help | --version    Hilfe/Version
USAGE
}

# CLI
SRC="$SRC_DEFAULT"; DST="$DST_DEFAULT"; INDEX_NAME="$INDEX_NAME_DEFAULT"
for arg in "$@"; do
  case "$arg" in
    --help) usage; exit 0;;
    --version) echo "$VERSION"; exit 0;;
    --src=*) SRC="${arg#*=}";;
    --dst=*) DST="${arg#*=}";;
    --index=*) INDEX_NAME="${arg#*=}";;
    --mandb=yes|--mandb=no) MANDO="${arg#*=}";;
    --dry-run) DRY_RUN="yes"; APPLY="no";;
    --apply) DRY_RUN="no"; APPLY="yes";;
    --audit) AUDIT="yes";;
    *) echo "Unbekannte Option: $arg"; usage; exit 3;;
  esac
done

INDEX_PATH="$DST/$INDEX_NAME"                 # Plain
INDEX_JSON_PATH="${INDEX_PATH%.json}.json"    # JSON-Sibling

# Audit-Ziele
AUDIT_DIR="$HOME/code/bin/shellscripts/audits/$SCRIPT_ID"
AUDIT_CSS="$AUDIT_DIR/$SCRIPT_ID.css"
AUDIT_MD="$AUDIT_DIR/latest.md"
AUDIT_HTML="$AUDIT_DIR/latest.html"

# Header
printf "%s %s\n" "$SCRIPT_ID" "$VERSION"

# Quelle prüfen
[ -d "$SRC" ] || { echo "ERR: Quelle nicht gefunden: $(short "$SRC")"; exit 2; }

# Auto-sudo nur in Apply
if [ "$APPLY" = "yes" ]; then
  need_sudo="no"
  if [ ! -d "$DST" ]; then
    parent="$(dirname "$DST")"; [ -w "$parent" ] || need_sudo="yes"
  else
    [ -w "$DST" ] || need_sudo="yes"
  fi
  if [ "$need_sudo" = "yes" ] && [ "${ELEVATED:-no}" != "yes" ]; then
    SELF="$(abspath "$0")"
    echo "elevate: re-running with sudo for write access to $(short "$DST")..."
    exec sudo -E ELEVATED=yes SRC="$SRC" DST="$DST" INDEX_NAME="$INDEX_NAME" \
      MANDO="$MANDO" APPLY="$APPLY" DRY_RUN="$DRY_RUN" AUDIT="$AUDIT" bash "$SELF" "$@"
  fi
fi

# Zähler
eq=0; new=0; upd=0; obs=0; total=0; unreadable=0
declare -A seen=(); declare -A src_secs=()

# Für JSON-Index sammeln
files_json_tmp="$(mktemp)"
trap 'rm -f "$files_json_tmp" 2>/dev/null || true' EXIT
: > "$files_json_tmp"

# Quelle scannen
mapfile -d '' -t files < <(find "$SRC" -type f -print0 2>/dev/null || true)

for f in "${files[@]:-}"; do
  section="$(basename "$(dirname "$f")")"
  case "$section" in man[0-9a-z]*) ;; *) continue ;; esac
  src_secs["$section"]=1

  base="$(basename "$f")"
  dest_rel="$section/$base"

  # Ziel immer .gz
  tmp_gz=""
  if [[ "$base" != *.gz ]]; then
    dest_rel="$section/$base.gz"
    tmp_gz="$(mktemp)"; gzip -n -c "$f" > "$tmp_gz"
    SRC_OBJ="$tmp_gz"
  else
    SRC_OBJ="$f"
  fi
  dest="$DST/$dest_rel"

  # Hashes/Größen (fehlertolerant)
  src_hash="$(sha256sum "$SRC_OBJ" 2>/dev/null | awk '{print $1}' || true)"
  src_size="$(stat -c %s "$SRC_OBJ" 2>/dev/null || echo 0)"

  if [[ -f "$dest" ]]; then
    if [[ -r "$dest" ]]; then
      dst_hash="$(sha256sum "$dest" 2>/dev/null | awk '{print $1}' || true)"
      if [[ -n "$dst_hash" && -n "$src_hash" && "$src_hash" == "$dst_hash" ]]; then
        ((eq+=1))
      else
        if [[ "$APPLY" == "yes" ]]; then
          mkdir -p "$(dirname "$dest")"
          cp -f "$SRC_OBJ" "$dest"
          chmod 0644 "$dest" || true
        fi
        ((upd+=1))
      fi
    else
      ((unreadable+=1))
    fi
  else
    if [[ "$APPLY" == "yes" ]]; then
      mkdir -p "$(dirname "$dest")"
      cp -f "$SRC_OBJ" "$dest"
      chmod 0644 "$dest" || true
    fi
    ((new+=1))
  fi

  printf '{"path":"%s","hash":"%s","size":%s}\n' "$dest_rel" "${src_hash:-}" "${src_size:-0}" >> "$files_json_tmp"

  [[ -n "$tmp_gz" ]] && rm -f "$tmp_gz"
  seen["$dest_rel"]=1
  ((total+=1))
done

# Obsolete (JSON bevorzugt, sonst Plain)
oldlist=()
if [[ -f "$INDEX_JSON_PATH" ]]; then
  mapfile -t oldlist < <(grep -oE '"path"[[:space:]]*:[[:space:]]*"[^"]+"' "$INDEX_JSON_PATH" | sed -E 's/.*:"([^"]+)"/\1/')
elif [[ -f "$INDEX_PATH" ]]; then
  while IFS= read -r line; do [[ -n "$line" ]] && oldlist+=("$line"); done < "$INDEX_PATH"
fi
for rel in "${oldlist[@]}"; do
  if [[ -z "${seen[$rel]:-}" ]]; then
    if [[ -f "$DST/$rel" ]]; then
      if [[ "$APPLY" == "yes" ]]; then rm -f "$DST/$rel"; fi
      ((obs+=1))
    fi
  fi
done

# ---- Index schreiben (Apply: immer beide) ----
if [[ "$APPLY" == "yes" ]]; then
  mkdir -p "$DST"
  printf "%s\n" "${!seen[@]}" | LC_ALL=C sort > "$INDEX_PATH"
  {
    printf '{\n'
    printf '  "script": "%s",\n' "$SCRIPT_ID"
    printf '  "version": "%s",\n' "$VERSION"
    printf '  "created": "%s",\n' "$(now_iso)"
    printf '  "src": "%s",\n' "$(short "$SRC")"
    printf '  "dst": "%s",\n' "$(short "$DST")"
    printf '  "files": [\n'
    awk 'BEGIN{first=1}{ if(!first){printf(",\n")} first=0; printf("    %s",$0) } END{print ""}' "$files_json_tmp"
    printf '  ]\n}\n'
  } > "$INDEX_JSON_PATH"
  index_plain_status="wrote:"; index_json_status="wrote:"
else
  if [[ -f "$INDEX_PATH" ]]; then index_plain_status="kept:"; else index_plain_status="none:"; fi
  if [[ -f "$INDEX_JSON_PATH" ]]; then index_json_status="kept:"; else index_json_status="none:"; fi
fi

# ---- Audit: MD append + Pandoc zu HTML + CSS nur wenn fehlt ----
md_status="none:"; html_status="none:"; css_status="none:"; css_note=""
if [[ "$AUDIT" == "yes" ]]; then
  mkdir -p "$AUDIT_DIR"
  ts_id="$(date +%Y%m%d-%H%M%S)"
  ts_human="$(now_iso)"

  # CSS nur schreiben, wenn NICHT vorhanden
  if [[ -f "$AUDIT_CSS" ]]; then
    css_status="kept:"; css_note="(linked-ok)"
  else
    cat > "$AUDIT_CSS" <<'CSS'
:root{--fg:#222;--bg:#fff;--muted:#666;--accent:#0a7;}
body{font-family:system-ui,Arial,sans-serif;color:var(--fg);background:var(--bg);line-height:1.5;margin:2rem;}
h1{margin:0 0 .25rem 0;font-weight:700}
h2{margin:.25rem 0 1rem 0;color:var(--muted);font-weight:500}
table{border-collapse:collapse;width:100%;margin:1rem 0}
th,td{border:1px solid #ddd;padding:.5rem .6rem;text-align:left}
th{background:#f5f5f5}
code,pre{font-family:ui-monospace,Menlo,Consolas,monospace;font-size:.95em}
details{margin:.4rem 0}
summary{cursor:pointer;color:var(--accent)}
CSS
    css_status="wrote:"; css_note=""
  fi

  # MD: Abschnitt anhängen (vorweg eine Leerzeile falls Datei existiert & nicht leer)
  if [[ -s "$AUDIT_MD" ]]; then printf "\n" >> "$AUDIT_MD"; fi
  {
    echo "### Run-Id: $ts_id"
    echo ""
    echo "| Script | Version | Mode | Equal | New | Updated | Obsolete | Existing-not-readable |"
    echo "|-------:|:-------:|:----:|------:|---:|--------:|---------:|-----------------------:|"
    echo "| \`$SCRIPT_ID\` | \`$VERSION\` | \`$([[ "$APPLY" == "yes" ]] && echo apply || echo dry-run)\` | $eq | $new | $upd | $obs | $unreadable |"
    echo ""
    echo "<details class=\"details-list\"><summary>Summary:</summary>"
    echo "<details><summary>Source</summary><code>$(short "$SRC")</code></details>"
    echo "<details><summary>Destination</summary><code>$(short "$DST")</code></details>"
    echo "<details><summary>Index (plain)</summary><code>$(short "$INDEX_PATH")</code></details>"
    echo "<details><summary>Index (json)</summary><code>$(short "$INDEX_JSON_PATH")</code></details>"
    echo "</details>"
  } >> "$AUDIT_MD"
  md_status="appended:"

  # HTML via pandoc (standalone; Title + CSS-Link injizieren)
  # Erzeuge HTML
  tmp_html="$(mktemp)"
  pandoc --from gfm --to html5 --standalone \
    --metadata title="Audit \`$SCRIPT_ID\` — $ts_human" \
    --output "$tmp_html" "$AUDIT_MD"

  # CSS-Link nach <head> injizieren, H1/H2 vor den Inhalt setzen
  # (H2 enthält kanonischen Pfad + Version)
  CANON_PATH="$HOME/code/bin/shellscripts/$SCRIPT_ID.sh"
  {
    awk -v css="$(basename "$AUDIT_CSS")" -v sid="$SCRIPT_ID" -v ver="$VERSION" -v canon="$CANON_PATH" -v ts="$ts_human" '
      BEGIN{ins=0}
      /<head>/ && ins==0 { print; print "  <link rel=\"stylesheet\" href=\"" css "\"/>"; ins=1; next }
      /<body[^>]*>/ && !seen_body { print; print "<h1>Audit <code>" sid "</code> — " ts "</h1>"; print "<h2 id=\"" sid "-subheader\">" canon " - " ver "</h2>"; seen_body=1; next }
      { print }
    ' "$tmp_html" > "$AUDIT_HTML"
  }
  rm -f "$tmp_html"
  html_status="$( [[ -f "$AUDIT_HTML" ]] && echo "overwrote:" || echo "wrote:" )"
fi

# mandb
mandb_note="skipped"
if [[ "$MANDO" == "yes" ]]; then
  if command -v mandb >/dev/null 2>&1; then
    if [[ "$APPLY" == "yes" ]]; then mandb -q || true; mandb_note="updated"
    else mandb_note="would-update"; fi
  else
    mandb_note="not-found"
  fi
fi

# ---- Ausgaberoutine mit fester Breite (Umlaute-safe) ----
W=38
pad_kv(){ # prefix label value [width]
  local pfx="$1" lbl="$2" val="$3" w="${4:-$W}"
  local n=${#lbl}; local pad=$(( w - n )); (( pad < 1 )) && pad=1
  printf "%-6s %s%*s %6d\n" "$pfx" "$lbl" "$pad" "" "$val"
}

# ---- Ausgabe ----
echo "target(s):"
printf "%-6s %s\n" "src:" "$(short "$SRC")"
printf "%-6s %s\n" "dst:" "$(short "$DST")"

printf "%-6s %-13s %s\n" "scan:"  "files:"      "$total"
printf "%-6s %-13s %s\n" "apply:" "mode:"       "$([[ "$APPLY" == "yes" ]] && echo apply || echo dry-run)"

if [[ "$APPLY" = "yes" ]]; then
  pad_kv "copy:"  "equal:"    "$eq"
  pad_kv ""       "new:"      "$new"
  pad_kv ""       "updated:"  "$upd"
  pad_kv "prune:" "obsolete:" "$obs"
else
  pad_kv "copy:"  "equal (identisch):"               "$eq"
  pad_kv ""       "new (würde installieren):"        "$new"
  pad_kv ""       "updated (würde überschreiben):"   "$upd"
  pad_kv ""       "existing (am Ziel nicht lesbar):" "$unreadable"
  pad_kv "prune:" "obsolete (würde löschen):"        "$obs"
fi

printf "%-6s %-13s %-8s %s\n" "index:" "plain:" "$index_plain_status" "$(short "$INDEX_PATH")"
printf "%-6s %-13s %-8s %s\n" ""       "json:"  "$index_json_status"  "$(short "$INDEX_JSON_PATH")"

if [[ "$AUDIT" == "yes" ]]; then
  printf "%-6s %-13s %s\n" "md:"   "$md_status"   "$(short "$AUDIT_MD")"
  printf "%-6s %-13s %s\n" "html:" "$html_status" "$(short "$AUDIT_HTML")"
  printf "%-6s %-13s %s %s\n" "css:"  "$css_status" "$(short "$AUDIT_CSS")" "$css_note"
fi

printf "%-6s %-13s %s\n" "mandb:" "" "$mandb_note"

exit 0
