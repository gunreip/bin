#!/usr/bin/env bash
# wiki_css_sync.sh – kopiert zentrale CSS-Styles aus ~/bin/css/ ins aktuelle Projekt gemäß @dest-Kommentar
# Version: 0.3.5
# Quelle: ~/bin/css/shell_script_styles.*.css
# Im CSS:  /* @dest: .wiki/logs/.shell_script_styles.logs.css */

set -Eeuo pipefail
IFS=$'\n\t'

VERSION="0.3.5"

ok(){ printf "✅"; }; warn(){ printf "⚠️"; }; bad(){ printf "❌"; }
ts_utc(){ date -u +"%Y-%m-%dT%H:%M:%SZ"; }; ts_local(){ TZ="$TZ_RUN" date +"%H:%M:%S"; }
date_de(){ TZ="$TZ_RUN" date +"%d.%m.%Y"; }; date_compact(){ TZ="$TZ_RUN" date +"%Y%m%d"; }; year_y(){ TZ="$TZ_RUN" date +"%Y"; }
user_name(){ id -un; }; host_name(){ hostname; }
script_name="$(basename "$0")"; run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"; pid="$$"

jesc(){ printf "%s" "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e ':a;N;$!ba;s/\n/\\n/g'; }
md_escape_pipes(){ sed -e 's/|/\\|/g'; }
ZWJ=$'\u200d'; md_hyphen_zwj(){ awk -v ZWJ="$ZWJ" '{gsub(/-/, ZWJ "-" ZWJ); print}'; }
md_code_cell(){ local s; s="$(cat)"; s="$(printf "%s" "$s" | md_hyphen_zwj | md_escape_pipes)"; [[ -z "$s" ]] && return 0; printf '`%s`' "$s"; }
md_text_cell(){ local s; s="$(cat)"; s="$(printf "%s" "$s" | md_hyphen_zwj | md_escape_pipes)"; printf "%s" "$s"; }
# FIX: & in sed-Replacement escapen, sonst verschwindet es
md_nbsp_colon(){ sed -E 's/: /:\&nbsp;/g'; }
redact(){ sed -E 's/(PASSWORD|SECRET|TOKEN|APP_KEY|PGPASSWORD)=([^[:space:]]+)/\1=********/gI'; }
trim_trailing_blanks(){ local f="$1" tmp; tmp="$(mktemp)"; awk '{a[NR]=$0} NF{last=NR} END{for(i=1;i<=last;i++) print a[i]}' "$f" > "$tmp" && mv "$tmp" "$f"; }
env_get(){ local k="$1" L v; L="$(grep -E "^[[:space:]]*${k}=" .env | tail -n1 | sed -E "s/^[[:space:]]*${k}=(.*)$/\1/" | tr -d '\r' || true)"; v="$L"; [[ "$v" =~ ^\".*\"$ ]] && v="${v:1:-1}"; [[ "$v" =~ ^\'.*\'$ ]] && v="${v:1:-1}"; printf "%s" "$v"; }

# Version bump
bump(){ local kind="$1" M m p; IFS=. read -r M m p <<<"$VERSION"
  case "$kind" in patch) p=$((p+1));; minor) m=$((m+1)); p=0;; major) M=$((M+1)); m=0; p=0;; esac
  local new="${M}.${m}.${p}"
  sed -E -i "s/^(VERSION=\")([0-9]+\.[0-9]+\.[0-9]+)(\")/\1${new}\3/" "$0"
  sed -E -i "s/^(# Version:\s*)([0-9]+\.[0-9]+\.[0-9]+)/\1${new}/" "$0"
  VERSION="$new"; echo "$VERSION"; }

# Argumente
ORIG_ARGS=("$@"); WIPE=0; DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) echo "$VERSION"; exit 0 ;;
    --bump-patch) bump patch; exit 0 ;;
    --bump-minor) bump minor; exit 0 ;;
    --bump-major) bump major; exit 0 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --wipe-today) WIPE=1; shift ;;
    --) shift; break ;;
    *) break ;;
  esac
done
opts_to_json(){ local arr=() a t; for a in "${ORIG_ARGS[@]:-}"; do [[ "$a" == "--" ]] && continue; t="${a//[[:space:]]/}"; [[ -z "$t" ]] && continue; arr+=("$a"); done
  if ((${#arr[@]}==0)); then printf '[]'; else printf '%s\n' "${arr[@]}" | awk 'BEGIN{printf("[");f=1}{gsub(/\\/,"\\\\");gsub(/"/,"\\\"");if(!f)printf(",");printf("\"%s\"",$0);f=0}END{printf("]")}'; fi; }
opts_to_md_cell(){ local arr=() a t; for a in "${ORIG_ARGS[@]:-}"; do [[ "$a" == "--" ]] && continue; t="${a//[[:space:]]/}"; [[ -z "$t" ]] && continue; arr+=("$a"); done
  if ((${#arr[@]}==0)); then printf "keine"; else local out="" line cell; for line in "${arr[@]}"; do cell="$(printf "%s" "$line" | md_code_cell)"; [[ -z "$cell" ]] && continue; [[ -z "$out" ]] && out="$cell" || out="${out}<br/>${cell}"; done; [[ -z "$out" ]] && printf "keine" || printf "%s" "$out"; fi; }

# Gatekeeper
[[ -f ".env" ]] || { echo "[ERROR] Projekt-Root erforderlich (.env fehlt)." >&2; exit 1; }
PROJ_NAME="$(env_get PROJ_NAME)"; [[ -n "$PROJ_NAME" ]] || PROJ_NAME="$(basename "$(pwd)")"
TZ_RUN="$(env_get PROJ_TIMEZONE)"; [[ -n "$TZ_RUN" ]] || TZ_RUN="Europe/Berlin"
GIT_REV="$(git rev-parse --short HEAD 2>/dev/null || true)"

# Pfade Logs
Y="$(year_y)"; D_compact="$(date_compact)"; D_de="$(date_de)"
MD_DIR=".wiki/logs/${Y}"; JSON_DIR=".wiki/logs/json/${Y}"
MD_FILE="${MD_DIR}/LOG-${D_compact}.md"; JSON_FILE="${JSON_DIR}/LOG-${D_compact}.jsonl"
mkdir -p "$MD_DIR" "$JSON_DIR"; [[ $WIPE -eq 1 ]] && { rm -f "$MD_FILE" "$JSON_FILE"; }

# CSS-Kopf: NUR .wiki/logs/.shell_script_styles.logs.css
CSS_PATH=".wiki/logs/.shell_script_styles.logs.css"
if [[ -f "$CSS_PATH" ]]; then
  MD_STYLE="$(printf "<style>\n%s\n</style>" "$(tr -d '\r' < "$CSS_PATH")")"
else
  MD_STYLE='`.wiki/logs/.shell_script_styles.logs.css` nicht gefunden!'
fi
if [[ ! -f "$MD_FILE" ]]; then
  { printf "%s\n\n" "$MD_STYLE"; } > "$MD_FILE"
else
  tmp="$(mktemp)"
  awk 'BEGIN{at_start=1;in_style=0;skipped_hint=0}
       { if(at_start){
           if($0 ~ /^<style>[[:space:]]*$/){in_style=1;next}
           if(in_style){ if($0 ~ /^<\/style>[[:space:]]*$/){in_style=0;next}else next}
           if($0 ~ /nicht gefunden!/){skipped_hint=1;next}
           if(skipped_hint && $0 ~ /^[[:space:]]*$/){next}
           if($0 ~ /^[[:space:]]*$/){next}
           at_start=0
         } print }' "$MD_FILE" > "$tmp"
  { printf "%s\n\n" "$MD_STYLE"; cat "$tmp"; } > "$MD_FILE"; rm -f "$tmp"
fi

# Tageskopf
if ! grep -q "^# Log - " "$MD_FILE"; then
  { echo "# Log - ${PROJ_NAME} -  ${D_de}"; echo ""; echo "- Pfad: \`$(pwd)\`"; echo "- Host: \`$(host_name)\`"; echo "- Zeitzone: \`${TZ_RUN}\`"; [[ -n "$GIT_REV" ]] && echo "- Git: \`$GIT_REV\`"; echo ""; } >> "$MD_FILE"
fi

# JSON Start
mkdir -p "$(dirname "$JSON_FILE")"
{ printf '{"ts":"%s","tz":"%s","lvl":"INFO","script":"%s","version":"%s","project":"%s","run_id":"%s","pid":%s,"user":"%s","host":"%s","cwd":"%s","git_rev":"%s","section":"start","action":"bootstrap","reason":"css-sync","tags":[],"options":%s,"result":{"status":"started"}}\n' \
  "$(ts_utc)" "$(jesc "$TZ_RUN")" "$(jesc "$script_name")" "$(jesc "$VERSION")" "$(jesc "$PROJ_NAME")" "$(jesc "$run_id")" "$pid" "$(jesc "$(user_name)")" "$(jesc "$(host_name)")" "$(jesc "$(pwd)")" "$(jesc "$GIT_REV")" "$(opts_to_json)"; } >> "$JSON_FILE"

# Markdown Run-Header
{ echo ""; echo "## Run-ID: \`${run_id}\`"; echo ""; echo "| Zeit | Script | Version | Optionen | Sektion | Action | Grund | tags | Ergebnis | Dauer (ms) | Exit | User | Notiz | Skript-Meldungen |"; echo "| --- | --- | ---: | --- | --- | --- | --- | --- | :---: | ---: | :---: | --- | --- | --- |"; } >> "$MD_FILE"

# Quelle & Kopierlogik
SRC_DIR="${HOME}/bin/css"; [[ -d "$SRC_DIR" ]] || { echo "[ERROR] Quellverzeichnis nicht gefunden: $SRC_DIR" >&2; exit 1; }
extract_dest(){ local f="$1" L D; L="$(grep -im1 '@dest:' "$f" || true)"; [[ -n "$L" ]] || return 0; D="$(printf "%s" "$L" | sed -E 's/.*@dest:[[:space:]]*//I' | sed -E 's@[[:space:]]*\*/[[:space:]]*$@@' | tr -d '\r' | sed -E 's/[[:space:]]+$//')"; printf "%s" "$D"; }
is_safe_relpath(){ local p="$1"; [[ "$p" != /* ]] && [[ "$p" != *"/.."* ]] && [[ "$p" != ".."* ]] && [[ "$p" != *"../"* ]]; }

csv_to_json_array(){ awk -v s="$1" 'BEGIN{n=split(s,a,",");printf("[");c=0;for(i=1;i<=n;i++){gsub(/^[ \t]+|[ \t]+$/,"",a[i]);if(a[i]!=""){gsub(/\\/,"\\\\",a[i]);gsub(/"/,"\\\"",a[i]);if(c++)printf(",");printf("\""a[i]"\"")}}printf("]")}' ; }

log_event(){
  local lvl="$1" sec="$2" act="$3" why="$4" status="$5" dur="$6" ex="${7:-0}" note="$8" tags_csv="${9:-}" script_msg="${10:-}" icon
  case "$status" in ok) icon="$(ok)";; warn) icon="$(warn)";; error) icon="$(bad)";; *) icon="$status";; esac
  # JSON
  { printf '{"ts":"%s","tz":"%s","lvl":"%s","script":"%s","version":"%s","project":"%s","run_id":"%s","pid":%s,"user":"%s","host":"%s","cwd":"%s","git_rev":"%s","section":"%s","action":"%s","reason":"%s","tags":%s,"options":%s,"notes":"%s","script_message":"%s","result":{"status":"%s","code":%s},"duration_ms":%s}\n' \
    "$(ts_utc)" "$(jesc "$TZ_RUN")" "$(jesc "$lvl")" "$(jesc "$script_name")" "$(jesc "$VERSION")" "$(jesc "$PROJ_NAME")" "$(jesc "$run_id")" "$pid" "$(jesc "$(user_name)")" "$(jesc "$(host_name)")" "$(jesc "$(pwd)")" "$(jesc "$GIT_REV")" \
    "$(jesc "$sec")" "$(jesc "$act")" "$(jesc "$why")" "$(csv_to_json_array "$tags_csv")" "$(opts_to_json)" "$(jesc "$note")" "$(jesc "$script_msg")" "$(jesc "$status")" "$ex" "${dur:-0}"; } >> "$JSON_FILE"
  # MD – Notiz & Skript-Meldungen mit NBSP nach ":" formatieren
  printf "| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n" \
    "$(ts_local)" \
    "$(printf "%s" "$script_name" | md_code_cell)" \
    "$(printf "%s" "$VERSION" | md_escape_pipes)" \
    "$(opts_to_md_cell)" \
    "$(printf "%s" "$sec" | md_text_cell)" \
    "$(printf "%s" "$act" | md_text_cell)" \
    "$(printf "%s" "$why" | md_text_cell)" \
    "$(printf "%s" "$tags_csv" | sed 's/,/, /g' | md_text_cell)" \
    "$(printf "%s" "$icon")" \
    "$(printf "%s" "${dur:-0}" | md_escape_pipes)" \
    "$(printf "%s" "$ex" | md_escape_pipes)" \
    "$(printf "%s" "$(user_name)" | md_escape_pipes)" \
    "$(printf "%s" "$note" | md_nbsp_colon | md_text_cell)" \
    "$(printf "%s" "$script_msg" | md_nbsp_colon | md_text_cell)" \
    | redact >> "$MD_FILE"
}

copy_one(){
  local src="$1" dest_rel="$2" start_ns msg=""
  dest_rel="${dest_rel#./}"
  if ! is_safe_relpath "$dest_rel"; then
    log_event WARN "sync" "validate" "unsafe-path" "warn" 0 0 "" "css,sync" "unsicherer Zielpfad: $dest_rel"
    return 2
  fi
  local dest_abs dest_dir; dest_abs="$(pwd)/$dest_rel"; dest_dir="$(dirname "$dest_abs")"
  start_ns="$(date +%s%N 2>/dev/null || echo 0)"
  if [[ $DRY_RUN -eq 1 ]]; then
    log_event INFO "sync" "copy" "dry-run" "ok" 0 0 "" "css,sync,dry-run" "DRY: $src -> $dest_rel"
    return 0
  fi
  mkdir -p "$dest_dir" || { log_event ERROR "sync" "mkdir" "io" "error" 0 1 "" "css,sync" "mkdir fehlgeschlagen: $dest_dir"; return 1; }
  if cp -p "$src" "$dest_abs" 2> >(read err; msg="$err"); then
    local dur=0; [[ "$start_ns" != 0 ]] && dur=$(( ( $(date +%s%N) - start_ns ) / 1000000 ))
    log_event INFO "sync" "copy" "apply" "ok" "$dur" 0 "" "css,sync" "$src -> $dest_rel"
    return 0
  else
    log_event ERROR "sync" "copy" "io" "error" 0 2 "" "css,sync" "cp: $msg"
    return 2
  fi
}

total=0; copied=0; skipped=0; warned=0
while IFS= read -r -d '' css; do
  ((total++)) || true
  dest_rel="$(extract_dest "$css")"
  if [[ -z "${dest_rel:-}" ]]; then
    ((skipped++)) || true
    log_event WARN "scan" "parse" "no-dest" "warn" 0 0 "" "css,sync" "kein @dest: in $(basename "$css")"
    continue
  fi
  if copy_one "$css" "$dest_rel"; then
    ((copied++)) || true
  else
    ((warned++)) || true
  fi
done < <(find "${HOME}/bin/css" -type f -name 'shell_script_styles.*.css' -print0)

# Abschluss – Notiz mit NBSP nach ":" formatiert
log_event INFO "finish" "summary" "report" "ok" 10 0 "OK: $copied, Skip: $skipped, Warn: $warned, Total: $total" "summary" ""
trim_trailing_blanks "$MD_FILE"

echo ""; echo "Fertig:"; echo "  gefunden : $total"; echo "  kopiert  : $copied"; echo "  überspr. : $skipped"; echo "  Warnungen: $warned"
echo "Logs:"; echo "  - ${MD_FILE}"; echo "  - ${JSON_FILE}"
