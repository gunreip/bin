#!/usr/bin/env bash
# _backup_shell_script.sh – minimales Backup + 1 Log-Eintrag
# Nutzung: _backup_shell_script.sh --shell_script /pfad/zum/script.sh

set -Eeuo pipefail
IFS=$'\n\t'

script_name="$(basename "$0")"
ORIG_CWD="$(pwd)"
run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"

# ----- Helpers -----
ts_utc(){ date -u +"%Y-%m-%dT%H:%M:%SZ"; }
ts_local(){ TZ="$1" date +"%H:%M:%S"; }
date_de(){ TZ="$1" date +"%d.%m.%Y"; }
date_compact(){ TZ="$1" date +"%Y%m%d"; }
year_y(){ TZ="$1" date +"%Y"; }
user_name(){ id -un; } ; host_name(){ hostname; }

# human readable size aus Bytes (ohne du-Pipeline)
humanize_bytes(){
  local b="${1:-0}" u=("B" "KiB" "MiB" "GiB" "TiB" "PiB" "EiB" "ZiB" "YiB") i=0
  while (( b >= 1024 && i < ${#u[@]}-1 )); do b=$(( (b + 512)/1024 )); ((i++)); done
  printf "%d %s" "$b" "${u[i]}"
}

# Markdown helpers
jesc(){ printf "%s" "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e ':a;N;$!ba;s/\n/\\n/g'; }
md_escape_pipes(){ sed -e 's/|/\\|/g'; }
ZWJ=$'\u200d'
md_hyphen_zwj_text(){ awk -v ZWJ="$ZWJ" '{gsub(/-/, ZWJ "-" ZWJ); print}'; }  # nur Textspalten
md_code_cell(){ local s; s="$(cat)"; s="$(printf "%s" "$s" | md_escape_pipes)"; [[ -z "$s" ]] && return 0; printf '`%s`' "$s"; }
md_text_cell(){ local s; s="$(cat)"; s="$(printf "%s" "$s" | md_hyphen_zwj_text | md_escape_pipes)"; printf "%s" "$s"; }
md_nbsp_colon(){ sed -E 's/: /:\&nbsp;/g'; }
ok(){ printf "✅"; } ; warn(){ printf "⚠️"; } ; bad(){ printf "❌"; }

# Projekt-Autodetect (.env genügt)
find_project_root(){ local d="$1"; while :; do [[ -f "$d/.env" ]] && { printf "%s" "$d"; return 0; }; [[ "$d" == "/" ]] && return 1; d="$(dirname "$d")"; done; }
PROJECT_ROOT=""; if root="$(find_project_root "$ORIG_CWD")"; then PROJECT_ROOT="$root"; fi
LOG_ROOT="${PROJECT_ROOT:-${HOME}/bin}"

PROJ_NAME="$( (grep -E '^[[:space:]]*PROJ_NAME=' "$LOG_ROOT/.env" 2>/dev/null | sed -E 's/^[[:space:]]*PROJ_NAME=(.*)$/\1/' | tr -d '\r') || true )"
[[ -n "$PROJ_NAME" ]] || PROJ_NAME="$(basename "$LOG_ROOT")"
TZ_RUN="$( (grep -E '^[[:space:]]*PROJ_TIMEZONE=' "$LOG_ROOT/.env" 2>/dev/null | sed -E 's/^[[:space:]]*PROJ_TIMEZONE=(.*)$/\1/' | tr -d '\r') || true )"
[[ -n "$TZ_RUN" ]] || TZ_RUN="Europe/Berlin"

Y="$(year_y "$TZ_RUN")"; D_compact="$(date_compact "$TZ_RUN")"; D_de="$(date_de "$TZ_RUN")"
MD_DIR="${LOG_ROOT}/.wiki/logs/${Y}"; JSON_DIR="${LOG_ROOT}/.wiki/logs/json/${Y}"
MD_FILE_BASENAME="LOG-${D_compact}"
if [[ "$LOG_ROOT" == "${HOME}/bin" ]]; then MD_FILE_BASENAME="_bin-LOG-${D_compact}"; fi
MD_FILE="${MD_DIR}/${MD_FILE_BASENAME}.md"; JSON_FILE="${JSON_DIR}/${MD_FILE_BASENAME}.jsonl"
mkdir -p "$MD_DIR" "$JSON_DIR"

# CSS + Header falls neue Datei
if [[ ! -f "$MD_FILE" ]]; then
  CSS_PATH="${LOG_ROOT}/.wiki/logs/.shell_script_styles.logs.css"
  if [[ -f "$CSS_PATH" ]]; then printf "<style>\n%s\n</style>\n\n" "$(tr -d '\r' < "$CSS_PATH")" > "$MD_FILE"
  else echo '`.wiki/logs/.shell_script_styles.logs.css` nicht gefunden!' > "$MD_FILE"; echo "" >> "$MD_FILE"; fi
  {
    echo "# Log - ${PROJ_NAME} -  ${D_de}"
    echo ""; echo "- Pfad: \`$LOG_ROOT\`"; echo "- Host: \`$(host_name)\`"; echo "- Zeitzone: \`$TZ_RUN\`"; echo ""
  } >> "$MD_FILE"
fi

# Run-Header + Tabellenkopf
{
  echo ""; echo "## Run-ID: \`${run_id}\`"; echo ""
  echo "| Zeit | Script | Version | Optionen | Sektion | Action | Grund | tags | Ergebnis | Dauer (ms) | Exit | User | Notiz | Skript-Meldungen |"
  echo "| --- | --- | ---: | --- | --- | --- | --- | --- | :---: | ---: | :---: | --- | --- | --- |"
} >> "$MD_FILE"

# Optionen (nur Darstellung)
ORIG_ARGS=("$@")
md_inline_code(){ local s; s="$(printf "%s" "$1" | md_escape_pipes)"; printf "\`%s\`" "$s"; }
opts_to_md_cell(){
  local n="${#ORIG_ARGS[@]}" i=0 out=""
  while (( i < n )); do
    local a="${ORIG_ARGS[i]}"; [[ "$a" == "--" ]] && ((i++)) && continue
    [[ -z "${a//[[:space:]]/}" ]] && ((i++)) && continue
    if [[ "$a" == -* && "$a" != *=* && $((i+1)) -lt $n ]]; then
      local b="${ORIG_ARGS[i+1]}"
      if [[ -n "$b" && "$b" != -* ]]; then out="${out:+${out}<br/>}$(md_inline_code "$a")&nbsp;$(md_inline_code "$b")"; ((i+=2)); continue; fi
    fi
    out="${out:+${out}<br/>}$(md_inline_code "$a")"; ((i++))
  done
  [[ -z "$out" ]] && printf "keine" || printf "%s" "$out"
}

write_json(){
  local lvl="$1" sec="$2" act="$3" why="$4" status="$5" dur="$6" code="$7" note="$8" tags="$9" msg="${10}"
  printf '{"ts":"%s","tz":"%s","lvl":"%s","script":"%s","version":"","project":"%s","run_id":"%s","pid":%s,"user":"%s","host":"%s","cwd":"%s","section":"%s","action":"%s","reason":"%s","tags":[%s],"options":[],"notes":"%s","script_message":"%s","result":{"status":"%s","code":%s},"duration_ms":%s}\n' \
    "$(ts_utc)" "$(jesc "$TZ_RUN")" "$(jesc "$lvl")" "$(jesc "$script_name")" "$(jesc "$PROJ_NAME")" "$(jesc "$run_id")" "$$" \
    "$(jesc "$(user_name)")" "$(jesc "$(host_name)")" "$(jesc "$ORIG_CWD")" \
    "$(jesc "$sec")" "$(jesc "$act")" "$(jesc "$why")" \
    "$(printf "%s" "$tags" | awk 'BEGIN{FS=",";f=1}{for(i=1;i<=NF;i++){gsub(/^[ \t]+|[ \t]+$/,"",$i); if($i!=""){if(!f)printf(","); printf("\""$i"\""); f=0}}}')" \
    "$(jesc "$note")" "$(jesc "$msg")" "$(jesc "$status")" "$code" "${dur:-0}" >> "$JSON_FILE"
}

log_event_md(){
  local status="$1" dur="$2" code="$3" note="$4" sec="$5" act="$6" why="$7" tags_csv="$8" msg="$9"
  local icon; case "$status" in ok) icon="$(ok)";; warn) icon="$(warn)";; error) icon="$(bad)";; *) icon="$status";; esac
  printf "| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n" \
    "$(ts_local "$TZ_RUN")" \
    "$(printf "%s" "$script_name" | md_code_cell)" \
    "" \
    "$(opts_to_md_cell)" \
    "$(printf "%s" "$sec" | md_text_cell)" \
    "$(printf "%s" "$act" | md_text_cell)" \
    "$(printf "%s" "$why" | md_text_cell)" \
    "$(printf "%s" "$tags_csv" | sed 's/,/, /g' | md_text_cell)" \
    "$(printf "%s" "$icon")" \
    "$(printf "%s" "${dur:-0}" | md_escape_pipes)" \
    "$(printf "%s" "$code" | md_escape_pipes)" \
    "$(printf "%s" "$(user_name)" | md_escape_pipes)" \
    "$(printf "%s" "$note" | md_nbsp_colon | md_text_cell)" \
    "$(printf "%s" "$msg" | md_nbsp_colon | md_text_cell)" >> "$MD_FILE"
}

# ----- Argumente parsen -----
SHELL_SCRIPT=""
if (( $# == 0 )); then echo "[ERROR] --shell_script <pfad> ist erforderlich" >&2; exit 2; fi
while [[ $# -gt 0 ]]; do
  case "$1" in
    --shell_script) SHELL_SCRIPT="${2:-}"; shift 2 || { echo "[ERROR] --shell_script braucht einen Pfad" >&2; exit 2; } ;;
    --) shift; break ;;
    *) echo "[ERROR] Unbekannte Option: $1" >&2; exit 2 ;;
  esac
done

# ----- Backup -----
TAGS="backup"
start_ns="$(date +%s%N 2>/dev/null || echo 0)"

if [[ -z "${SHELL_SCRIPT}" ]]; then
  note="Fehler:&nbsp;kein&nbsp;Pfad"; msg="Erforderlich:&nbsp;--shell_script&nbsp;/pfad/zum/script.sh"
  log_event_md "error" 0 2 "$note" "backup" "create" "manual" "$TAGS" "$msg"
  write_json "ERROR" "backup" "create" "manual" "error" 0 2 "$note" "$TAGS" "$msg"
  echo "[ERROR] --shell_script <pfad> ist erforderlich" >&2; exit 2
fi

if [[ ! -f "$SHELL_SCRIPT" ]]; then
  note="Fehler:&nbsp;Datei&nbsp;nicht&nbsp;gefunden"; msg="Quelle:&nbsp;$SHELL_SCRIPT"
  log_event_md "error" 0 2 "$note" "backup" "create" "manual" "$TAGS" "$msg"
  write_json "ERROR" "backup" "create" "manual" "error" 0 2 "$note" "$TAGS" "$msg"
  echo "[ERROR] Datei nicht gefunden: $SHELL_SCRIPT" >&2; exit 2
fi

mkdir -p "${HOME}/bin/backups"
base="$(basename "$SHELL_SCRIPT")"
ts="$(date -u +%Y%m%dT%H%M%SZ)"
dest="${HOME}/bin/backups/${base}.bak-${ts}"

if cp -p -- "$SHELL_SCRIPT" "$dest"; then
  new_bytes="$(stat -c%s "$dest" 2>/dev/null || echo 0)"
  new_h="$(humanize_bytes "$new_bytes")"
  dur=0; [[ "$start_ns" != 0 ]] && dur=$(( ( $(date +%s%N) - start_ns ) / 1000000 ))
  note="OK:&nbsp;Backup&nbsp;erstellt"
  msg="Quelle:&nbsp;$SHELL_SCRIPT; Ziel:&nbsp;$dest; Größe:&nbsp;${new_h}&nbsp;(Bytes:&nbsp;${new_bytes})"
  log_event_md "ok" "$dur" 0 "$note" "backup" "create" "manual" "$TAGS" "$msg"
  write_json "INFO" "backup" "create" "manual" "ok" "$dur" 0 "$note" "$TAGS" "$msg"
  echo "OK: Backup -> $dest"
  exit 0
else
  note="Fehler:&nbsp;Backup&nbsp;gescheitert"; msg="Quelle:&nbsp;$SHELL_SCRIPT; Ziel:&nbsp;$dest"
  log_event_md "error" 0 1 "$note" "backup" "create" "io" "$TAGS" "$msg"
  write_json "ERROR" "backup" "create" "io" "error" 0 1 "$note" "$TAGS" "$msg"
  echo "[ERROR] Backup fehlgeschlagen" >&2
  exit 1
fi
