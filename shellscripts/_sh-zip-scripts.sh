#!/usr/bin/env bash
# _sh-zip-scripts.sh
# Version: v0.3.5
set -euo pipefail; IFS=$'\n\t'

SCRIPT_ID="_sh-zip-scripts"
PUBLIC_CMD="$(basename "$0")"
VERSION="v0.3.5"

BASE="$HOME/code/bin"; ROOT="$BASE"
SHELLS_DIR="$BASE/shellscripts"
LIB_DIR="$SHELLS_DIR/lib"
RUN_DIR="$SHELLS_DIR/runs/bin/sh-zip-scripts"
AUDIT_DIR="$SHELLS_DIR/audits/sh-zip-scripts"
DEBUG_DIR="$SHELLS_DIR/debugs/sh-zip-scripts"

CSS_FILE="$AUDIT_DIR/sh-zip-scripts.css"
MD_FILE="$AUDIT_DIR/latest.md"
HTML_FILE="$AUDIT_DIR/latest.html"

short_path(){ printf '%s\n' "${1/#$HOME/~}"; }
rel_sdir(){ local p="$1"; p="${p#${SHELLS_DIR}}"; p="${p#/}"; printf '/%s\n' "$p"; }
script_path(){ readlink -f "$0" 2>/dev/null || printf "%s" "$0"; }

[ "$PWD" = "$ROOT" ] || { echo "ERROR: Dieses Skript muss aus '$(short_path "$ROOT")' gestartet werden."; exit 2; }

# --- CLI ----------------------------------------------------------------------
RAW_ARGS=("$@")
SRC_MODE="canonical"; WITH_LIBS="none"; WITH_DOCS="no"; WITH_CHANGELOGS="no"
DRY_RUN="no"; DEBUG_MODE="OFF"
HTML_INLINE="pure"
SELECT_ALL="no"; SELECT_IDS=(); SELECT_PATTERNS=(); SELECT_CATS=()

usage(){
  cat <<EOF
$PUBLIC_CMD $VERSION
Packt ausgewählte Shellscripts zu EINEM ZIP. Ziel wird überschrieben.
Läuft nur aus: $(short_path "$ROOT")

AUSWAHL-LOGIK
  Basisliste:
    • --all                              [Default: aus]  → alle Symlinks in $(short_path "$ROOT")
    • --by-cat / --pattern (ohne --all)  → bauen AUTOMATISCH die Basisliste aus den Symlinks in $(short_path "$ROOT")
    • --scripts / --from-file            → explizite IDs (überschreibt Basisliste)
  Filter:
    • --by-cat=<c1,c2>     Kategorie = Präfix vor erstem '-' der ID (z. B. _sh, git)
    • --pattern=<p1,p2>    Shell-Glob auf IDs (z. B. git-*, _sh-*)
    • --all + --pattern    Hinweis: --pattern hat Vorrang (auch für ZIP-Benennung)

OPTIONEN (mit Defaults)
  Auswahl:
    --all                              # [Default: aus] alle Symlinks als Basis
    --scripts=ID1,ID2                  # explizite IDs (z. B. _sh-zip-scripts,_sh-logger-inject)
    --from-file=PFAD                   # je Zeile eine ID
    --pattern=GLOB[,GLOB...]           # [Default: —] z. B. git-*,_sh-*
    --by-cat=CAT[,CAT...]              # [Default: —] z. B. _sh,git
  Quelle/Extras:
    --src=canonical|symlink            # [Default: canonical] Pfadauflösung
    --with-libs=none|auto|all          # [Default: none] (Platzhalter)
    --with-docs                        # [Default: aus]
    --with-changelogs                  # [Default: aus]
  HTML:
    --html-inline=keep|pure            # [Default: pure] entfernt style/class/id an Tabellen
  Allgemein:
    --dry-run                          # [Default: aus] nur Ziele anzeigen
    --debug=OFF|dbg|trace|xtrace       # [Default: OFF]
    --help | --version

ZIEL-NAMEN (automatisch)
  • all → sh-zip-scripts-all.zip | eine Kategorie → sh-zip-scripts-<cat>.zip
  • genau 1 ID → sh-zip-scripts-<id>.zip | gemischt → sh-zip-scripts-mixed.zip
EOF
}

short_id_to_cat(){ local id="$1"; printf '%s\n' "${id%%-*}"; }
resolve_script_path(){
  local id="$1" cand link
  cand="$SHELLS_DIR/${id}.sh";     [ -f "$cand" ] && { readlink -f -- "$cand"; return; }
  cand="$SHELLS_DIR/${id#_}.sh";   [ -f "$cand" ] && { readlink -f -- "$cand"; return; }
  link="$ROOT/${id#_}";            [ -L "$link" ] && { readlink -f -- "$link"; return; }
  cand="$(find "$SHELLS_DIR" -type f \( -name "${id}.sh" -o -name "${id#_}.sh" \) | head -n1 || true)"
  [ -n "$cand" ] && [ -f "$cand" ] && { readlink -f -- "$cand"; return; }
  return 1
}
add_unique(){ local arr="$1"; shift; local v; for v in "$@"; do eval 'case " ${'"$arr"'[*]} " in *" '"$v"' "*) :;; *) '"$arr"'+=("'"$v"'");; esac'; done; }

# Args
for arg in "$@"; do
  case "$arg" in
    --all) SELECT_ALL="yes" ;;
    --scripts=*)  IFS=',' read -r -a tmp <<<"${arg#*=}"; add_unique SELECT_IDS "${tmp[@]}";;
    --from-file=*) while IFS= read -r line; do [ -n "${line// }" ] && add_unique SELECT_IDS "$line"; done < "${arg#*=}";;
    --pattern=*)  IFS=',' read -r -a tmp <<<"${arg#*=}"; add_unique SELECT_PATTERNS "${tmp[@]}";;
    --by-cat=*)   IFS=',' read -r -a tmp <<<"${arg#*=}"; add_unique SELECT_CATS "${tmp[@]}";;
    --src=canonical|--src=symlink) SRC_MODE="${arg#*=}";;
    --with-libs=none|--with-libs=auto|--with-libs=all) WITH_LIBS="${arg#*=}";;
    --with-docs) WITH_DOCS="yes";;
    --with-changelogs) WITH_CHANGELOGS="yes";;
    --html-inline=keep|--html-inline=pure) HTML_INLINE="${arg#*=}";;
    --dry-run) DRY_RUN="yes";;
    --debug=*) DEBUG_MODE="${arg#*=}";;
    --help) usage; exit 0;;
    --version) echo "$VERSION"; exit 0;;
    --no-color|--unicode=*) :;;
    *) echo "Unbekannte Option: $arg"; usage; exit 1;;
  esac
done

mkdir -p "$RUN_DIR" "$AUDIT_DIR" "$DEBUG_DIR"

# Basisliste
declare -a base_ids=() final_ids=()
[ "${#SELECT_IDS[@]}" -gt 0 ] && add_unique final_ids "${SELECT_IDS[@]}"
if [ "$SELECT_ALL" = "yes" ] || { [ "${#SELECT_CATS[@]}" -gt 0 ] || [ "${#SELECT_PATTERNS[@]}" -gt 0 ]; }; then
  while IFS= read -r -d '' ln; do base_ids+=("$(basename "$ln")"); done \
    < <(find "$ROOT" -maxdepth 1 -type l -print0 | LC_ALL=C sort -z)
fi
filter_ids(){
  local in=("$@") out=() id keep
  for id in "${in[@]}"; do
    keep="yes"
    if [ "${#SELECT_CATS[@]}" -gt 0 ]; then
      keep="no"; local cat; cat="$(short_id_to_cat "$id")"
      for c in "${SELECT_CATS[@]}"; do [ "$cat" = "$c" ] && { keep="yes"; break; }; done
    fi
    if [ "$keep" = "yes" ] && [ "${#SELECT_PATTERNS[@]}" -gt 0 ]; then
      keep="no"; local p; for p in "${SELECT_PATTERNS[@]}"; do case "$id" in $p) keep="yes"; break;; esac; done
    fi
    [ "$keep" = "yes" ] && out+=("$id")
  done
  printf '%s\n' "${out[@]}"
}
if [ "${#base_ids[@]}" -gt 0 ]; then
  mapfile -t base_ids < <(printf '%s\n' "${base_ids[@]}" | LC_ALL=C sort -u)
  mapfile -t filtered < <(filter_ids "${base_ids[@]}")
  add_unique final_ids "${filtered[@]}"
fi
mapfile -t final_ids < <(printf '%s\n' "${final_ids[@]}" | awk 'NF' | LC_ALL=C sort -u)
[ "$SELECT_ALL" = "yes" ] && [ "${#SELECT_PATTERNS[@]}" -gt 0 ] && \
  echo "Hinweis: --pattern überschreibt --all (Auswahl & ZIP-Benennung)."
[ "${#final_ids[@]}" -gt 0 ] || { echo "Keine gültigen Dateien gefunden."; exit 3; }

# IDs -> Pfade
declare -a files=() ids_ok=()
for id in "${final_ids[@]}"; do
  if path="$(resolve_script_path "$id")"; then
    case "$path" in "$LIB_DIR"/*) continue;; esac
    files+=("$path"); ids_ok+=("$id")
  else
    echo "WARN: Pfad für ID '$id' nicht gefunden – übersprungen."
  fi
done
[ "${#files[@]}" -gt 0 ] || { echo "Keine gültigen Dateien gefunden."; exit 3; }

# Zielname
zip_basename="sh-zip-scripts-mixed"
if   [ "${#ids_ok[@]}" -eq 1 ]; then zip_basename="sh-zip-scripts-${ids_ok[0]}"
elif [ "${#SELECT_CATS[@]}" -eq 1 ] && [ "${#SELECT_PATTERNS[@]}" -eq 0 ]; then zip_basename="sh-zip-scripts-${SELECT_CATS[0]}"
elif [ "$SELECT_ALL" = "yes" ] && [ "${#SELECT_PATTERNS[@]}" -eq 0 ] && [ "${#SELECT_CATS[@]}" -eq 0 ]; then zip_basename="sh-zip-scripts-all"
else
  declare -a uniq_cats=()
  for id in "${ids_ok[@]}"; do cat="$(short_id_to_cat "$id")"
    case " ${uniq_cats[*]} " in *" $cat "*) :;; *) uniq_cats+=("$cat");; esac
  done
  [ "${#uniq_cats[@]}" -eq 1 ] && zip_basename="sh-zip-scripts-${uniq_cats[0]}"
fi
ZIP_PATH="$RUN_DIR/${zip_basename}.zip"

# Dry-run
if [ "$DRY_RUN" = "yes" ]; then
  printf 'target(s): %s/...\n' "$(short_path "$SHELLS_DIR")"
  printf "%-6s %-11s %s\n" "zip:"  "would:"  "$(rel_sdir "$ZIP_PATH")"
  printf "%-6s %-11s %s\n" "md:"   "would:"  "$(rel_sdir "$MD_FILE")"
  printf "%-6s %-11s %s\n" "html:" "would:"  "$(rel_sdir "$HTML_FILE")"
  printf "%-6s %-11s %s\n" "css:"  "would:"  "$(rel_sdir "$CSS_FILE")"
  exit 0
fi

# Staging & ZIP
mkdir -p "$RUN_DIR" "$AUDIT_DIR"
stage="$RUN_DIR/.stage.$$"; trap 'rm -rf "$stage"' EXIT INT TERM ERR
rm -rf "$stage"; mkdir -p "$stage"

# --- WICHTIG: Zeitstempel OHNE OFFSET ---
ts="$(date +%Y%m%d-%H%M%S)"                         # Run-Id ohne %z
ts_touch="$(date -d "@$(date +%s)" +%Y%m%d%H%M.%S)" 2>/dev/null || ts_touch="$(date +%Y%m%d%H%M.%S)"

manifest="$stage/manifest.json"
{
  echo '{'
  echo '  "run_id": "'$ts'",'
  echo '  "zip_name": "'$(basename "$ZIP_PATH")'",'
  echo '  "source": "'$SRC_MODE'",'
  echo '  "count": '"${#files[@]}"','
  echo '  "entries": ['
  first=1
  for i in "${!files[@]}"; do
    id="${ids_ok[$i]}"; src="${files[$i]}"; dst="$stage/${id}.sh"
    cp -p -- "$src" "$dst"; touch -t "$ts_touch" "$dst" 2>/dev/null || true
    size=$(wc -c < "$dst" | tr -d ' '); sha=$(sha256sum "$dst" | awk '{print $1}')
    [ $first -eq 1 ] || echo '    ,'; first=0
    echo '    { "id":"'$id'","src":"'"$(printf "%s" "$src" | sed 's/"/\\"/g')"'","dst":"'"$(basename "$dst")"'","bytes":'$size',"sha256":"'$sha'" }'
  done
  echo '  ]'
  echo '}'
} > "$manifest"
touch -t "$ts_touch" "$manifest" 2>/dev/null || true

zip_existed=0; [ -f "$ZIP_PATH" ] && zip_existed=1
( cd "$stage"; rm -f "$ZIP_PATH"; zip -X -9 -q "$ZIP_PATH" ./* )
zip_sha256="$(sha256sum "$ZIP_PATH" | awk '{print $1}')"
zip_size="$(wc -c < "$ZIP_PATH" | tr -d ' ')"

# Helfer für Tabelle
human_zip_size(){
  awk -v b="$zip_size" 'BEGIN{
    u="B"; v=b;
    if (b<1e3){u="B"; v=b}
    else if (b<1e6){u="kB"; v=b/1e3}
    else if (b<1e9){u="MB"; v=b/1e6}
    else if (b<1e12){u="GB"; v=b/1e9}
    else {u="TB"; v=b/1e12}
    printf "%.1f %s", v, u
  }' | sed 's/\./,/'
}
opts_cell_from_raw_args(){
  local -a toks=(); local a
  for a in "${RAW_ARGS[@]}"; do case "$a" in -*) toks+=("$a");; esac; done
  local n=${#toks[@]}; [ $n -gt 0 ] || { printf '—'; return; }
  local out="" i tok sep
  for i in "${!toks[@]}"; do
    tok="${toks[$i]}"; tok="${tok//--/--}"         # NB-Hyphen
    sep=$([ "$i" -gt 0 ] && [ $n -gt 1 ] && echo "<br/>" || echo "")
    out+="${sep}\`$tok\`"
  done
  printf '%s' "$out"
}
semicolon_sep_ids_with_ext(){
  # Liefert: `id1.sh`; `id2.sh`; …
  local out="" id
  for id in "$@"; do
    [ -n "$out" ] && out+="; "
    out+="\`$id.sh\`"
  done
  printf '%s' "$out"
}

# Audit append (Monat)
month="$(date +%Y-%m)"
[ -f "$MD_FILE" ] || : > "$MD_FILE"
grep -q "^## $month" "$MD_FILE" || { printf '## %s\n\n' "$month" >> "$MD_FILE"; }

opts_cell="$(opts_cell_from_raw_args)"
human_size="$(human_zip_size)"
zip_dir_rel="$(rel_sdir "$(dirname "$ZIP_PATH")")"
zip_name="$(basename "$ZIP_PATH")"

{
  echo "### Run-Id: $ts"
  echo
  echo "| Script | Version | Created | Optionen | Count | Dateigröße (zip) | Target-ZIP-Path | Target-ZIP-Name | SHA256 | Quelle |"
  echo "|:------ |:-------:| ------: |:-------- | ----: | ---------------: |:--------------- |:---------------- |:------:|:------ |"
  echo "| \`$SCRIPT_ID\` | $VERSION | $(date '+%Y-%m-%d %H:%M:%S') | $opts_cell | ${#files[@]} | $human_size | \`$zip_dir_rel\` | \`$zip_name\` | \`$zip_sha256\` | \`$SRC_MODE\` |"
  echo
  echo "<details><summary>Script-IDs</summary>"
  echo
  echo "$(semicolon_sep_ids_with_ext "${ids_ok[@]}")"
  echo
  echo "</details>"
  echo
} >>"$MD_FILE"

# HTML rendern
TITLE="Audit ${SCRIPT_ID} — $(date '+%Y-%m-%d %H:%M:%S %Z')"  # H1 behält %Z (Abk.)
PRELUDE="$AUDIT_DIR/.html-prelude.$$"; html_input="$AUDIT_DIR/.html-input.$$"
{ echo "## $(script_path) - ${VERSION} {#_sh-zip-scripts-subheader}"; echo; } > "$PRELUDE"
cat "$PRELUDE" "$MD_FILE" > "$html_input"

css_opt=()
[ -f "$CSS_FILE" ] && css_opt=(-c "$(basename "$CSS_FILE")")
html_existed=0; [ -f "$HTML_FILE" ] && html_existed=1
pandoc -s --from=gfm+attributes --to=html5 \
  --metadata title="$TITLE" \
  "${css_opt[@]}" \
  --no-highlight \
  -o "$HTML_FILE" "$html_input"
rm -f "$PRELUDE" "$html_input"

# HTML "pure": style/class/id an Tabellen-Elementen entfernen
if [ "$HTML_INLINE" = "pure" ]; then
  perl -0777 -i -pe '
    s{<(table|thead|tbody|tfoot|tr|t[hd])\b([^>]*?)>}{
      my ($tag,$attrs)=($1,$2);
      $attrs =~ s/\s+(?:id|class|style)="[^"]*"//gi;
      $attrs =~ s/\s+/ /g; $attrs =~ s/\s+$//;
      "<$tag".($attrs ne "" ? " $attrs" : "").">"
    }egix;
  ' "$HTML_FILE"
fi

# Terminal-Ausgabe
css_link="none"; [ -f "$CSS_FILE" ] && css_link="linked-ok"
printf 'target(s): %s/...\n' "$(short_path "$SHELLS_DIR")"
if [ $zip_existed -eq 1 ]; then zip_status="overwrote:"; else zip_status="wrote:"; fi
if [ $html_existed -eq 1 ]; then html_status="overwrote:"; else html_status="wrote:"; fi
printf "%-6s %-11s %s\n" "zip:"  "$zip_status"  "$(rel_sdir "$ZIP_PATH")"
printf "%-6s %-11s %s\n" "md:"   "appended:"    "$(rel_sdir "$MD_FILE")"
printf "%-6s %-11s %s\n" "html:" "$html_status" "$(rel_sdir "$HTML_FILE")"
printf "%-6s %-11s %s\n" "css:"  "$css_link"    "$(rel_sdir "$CSS_FILE")"

exit 0
