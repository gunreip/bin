#!/usr/bin/env bash
# _audits-check-css-path — prüft CSS-Pfade aus templates/css/.css.conf.json + (optional) JS aus templates/js/.js.conf.json
#                         schreibt HTML/JSONL Audits, rotiert Debugs, injiziert CSS/JS-Links in <head>.
# Version: v0.26.0 (JS-Support)
IFS=$'\n\t'
set -o pipefail

SCRIPT_ID="_audits-check-css-path"
PUBLIC_CMD="$(basename "$0")"
VERSION="v0.26.0"

HOME_BIN="$HOME/code/bin"
SHELLS_DIR="$HOME_BIN/shellscripts"
CFG_DEFAULT_CSS="$HOME_BIN/templates/css/.css.conf.json"
CFG_DEFAULT_JS="$HOME_BIN/templates/js/.js.conf.json"   # NEU (optional)
LIB_DIR="$SHELLS_DIR/lib"
OPT_CFG="$LIB_DIR/.script-options.conf.json"

DEBUG_DIR="$SHELLS_DIR/debugs/$SCRIPT_ID"
TRASH_DIR="$HOME_BIN/trash/debug/$SCRIPT_ID"
AUD_BASE="$SHELLS_DIR/audits/$SCRIPT_ID/bin"

# Farben & Helfer
supports_color(){ [ -t 1 ] && [ "${NO_COLOR:-0}" != "1" ]; }
fxG(){ supports_color && printf '\033[32m%s\033[0m' "$1" || printf '%s' "$1"; }
fxR(){ supports_color && printf '\033[31m%s\033[0m' "$1" || printf '%s' "$1"; }
fxB(){ supports_color && printf '\033[34m%s\033[0m' "$1" || printf '%s' "$1"; }
fxBold(){ supports_color && printf '\033[1m%s\033[0m' "$1" || printf '%s' "$1"; }
pad(){  local label="$1" w="$2"; printf "%-${w}s" "$label"; }
kv(){   local label="$1" val="$2"; printf "%s %s\n" "$(pad "$label" 23)" "$val"; }
sep(){ echo '---'; }
html_escape(){ local s="${1//&/&amp;}"; s="${s//</&lt;}"; s="${s//>/&gt;}"; s="${s//\"/&quot;}"; printf '%s' "$s"; }

# Gatekeeper & Tools
PWD_P="$(pwd -P)"
[ "$PWD_P" = "$HOME_BIN" ] || { echo "Gatekeeper: Bitte aus $HOME_BIN starten. Aktuell: $PWD_P"; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "jq wird benötigt."; exit 3; }
command -v python3 >/dev/null 2>&1 || { echo "python3 wird benötigt."; exit 3; }

mkdir -p "$DEBUG_DIR" "$TRASH_DIR" "$AUD_BASE" "$LIB_DIR"

# CLI
CFG_CSS="$CFG_DEFAULT_CSS"; CFG_JS="$CFG_DEFAULT_JS"
ONLY_ID=""
CLI_DEBUG_MODE=""; CLI_DKEEP=""; CLI_DAGE=""; CLI_MINIFY=""
WITH_NOISE=0; WITH_OPTIONS=0
DUMP_RAW=0; DUMP_RES=0
for arg in "$@"; do
  case "$arg" in
    --help) cat <<USAGE
$SCRIPT_ID $VERSION
Usage:
  $PUBLIC_CMD [--config=PATH] [--config-js=PATH] [--id=SEKTION]
             [--debug=MODE] [--debug-keep=N] [--debug-age=SPAN] [--minify=yes|no]
             [--with-noise] [--with-options|--options] [--dump-raw] [--dump-resolved]
             [--no-color] [--version]
USAGE
      exit 0;;
    --version) echo "$VERSION"; exit 0;;
    --config=*)    CFG_CSS="${arg#*=}";;
    --config-js=*) CFG_JS="${arg#*=}";;
    --id=*)        ONLY_ID="${arg#*=}";;
    --debug=*)     CLI_DEBUG_MODE="$(printf '%s' "${arg#*=}" | tr '[:upper:]' '[:lower:]')";;
    --debug-keep=*) CLI_DKEEP="${arg#*=}";;
    --debug-age=*)  CLI_DAGE="${arg#*=}";;
    --minify=*)     CLI_MINIFY="$(printf '%s' "${arg#*=}" | tr '[:upper:]' '[:lower:]')";;
    --with-noise)   WITH_NOISE=1;;
    --with-options|--options) WITH_OPTIONS=1;;
    --dump-raw)     DUMP_RAW=1;;
    --dump-resolved) DUMP_RES=1;;
    --no-color) export NO_COLOR=1;;
    *) echo "Unbekannte Option: $arg"; exit 3;;
  esac
done
[ -f "$CFG_CSS" ] || { echo "CSS-Config nicht gefunden: $CFG_CSS"; exit 4; }
if [ $DUMP_RAW -eq 1 ] || [ $DUMP_RES -eq 1 ]; then WITH_NOISE=1; fi

# Options-Config laden (strikt)
[ -f "$OPT_CFG" ] || { kv "Options-config:" "$OPT_CFG"; echo "$(fxR '✖') Options-Config fehlt. Erwartet unter: $OPT_CFG"; exit 8; }

OPTS_JSON="$(python3 - "$OPT_CFG" "$SCRIPT_ID" <<'PY'
import sys, json, re
from pathlib import Path
cfg_path = Path(sys.argv[1]); script_id = sys.argv[2]
def die(code,msg,extra=None):
    print(f"ERR|{code}|{msg}")
    if extra:
        for ln in extra.splitlines(): print("SNIP|"+ln)
    raise SystemExit(1)
try:
    doc = json.loads(cfg_path.read_text(encoding="utf-8"))
except json.JSONDecodeError as e:
    b = cfg_path.read_text(encoding="utf-8",errors='replace').splitlines()
    lo=max(1,e.lineno-1); hi=min(len(b),e.lineno+1)
    extra="\n".join([f"{'>>' if i==e.lineno else '  '} {i:5d}: {b[i-1]}" for i in range(lo,hi+1)])
    die("JSON", f"{e.msg} (Zeile {e.lineno}, Spalte {e.colno})", extra)
allowed_defaults={"debug","debug_keep","debug_min_keep","debug_age","minify","minifier","link_mode"}
def ensure(c,m): 
    if not c: die("SCHEMA", m)
ensure("defaults" in doc and isinstance(doc["defaults"],dict),"Pflichtsektion 'defaults' fehlt oder ist kein Objekt.")
if "scripts" in doc:
    ensure(isinstance(doc["scripts"],dict),"'scripts' muss ein Objekt sein.")
for k in doc.keys():
    if k not in {"defaults","scripts"}: die("SCHEMA", f"Unbekannter Top-Level-Schlüssel: '{k}'")
for k in doc["defaults"].keys():
    if k not in allowed_defaults: die("SCHEMA", f"Unbekannter Schlüssel in defaults: '{k}'")
def check(p):
    for k in p.keys():
        if k not in allowed_defaults: die("SCHEMA", f"Unbekannter Schlüssel in Profil/defaults: '{k}'")
    if "debug" in p and p["debug"] not in ["off","dbg","trace","xtrace","all"]: die("SCHEMA","debug muss off|dbg|trace|xtrace|all sein.")
    if "debug_keep" in p and (not isinstance(p["debug_keep"],int) or p["debug_keep"]<2): die("SCHEMA","debug_keep muss int >=2 sein.")
    if "debug_min_keep" in p and (not isinstance(p["debug_min_keep"],int) or p["debug_min_keep"]<2): die("SCHEMA","debug_min_keep muss int >=2 sein.")
    if "debug_keep" in p and "debug_min_keep" in p and p["debug_min_keep"]>p["debug_keep"]: die("SCHEMA","debug_min_keep darf debug_keep nicht überschreiten.")
    if "debug_age" in p and (not isinstance(p["debug_age"],str) or not re.match(r"^\s*\d+\s*[smhd]\s*$",p["debug_age"])): die("SCHEMA","debug_age erwartet z.B. '30m', '12h', '2d', '90s'.")
    if "minify" in p and p["minify"] not in ["yes","no"]: die("SCHEMA","minify muss yes|no sein.")
    if "link_mode" in p and p["link_mode"] not in ["relative","absolute"]: die("SCHEMA","link_mode muss relative|absolute sein.")
check(doc["defaults"])
profile="defaults"; merged=dict(doc["defaults"])
if "scripts" in doc and script_id in doc["scripts"]:
    s=doc["scripts"][script_id]
    ensure(isinstance(s,dict),f"scripts['{script_id}'] muss Objekt sein.")
    ensure("defaults" in s and isinstance(s["defaults"],dict),f"scripts['{script_id}'].defaults fehlt/kein Objekt.")
    check(s["defaults"]); merged.update(s["defaults"]); profile=script_id
print("OPTS|"+json.dumps({"profile":profile,"options":merged},ensure_ascii=False))
PY
)"
if printf '%s\n' "$OPTS_JSON" | grep -q '^ERR|'; then
  kv "Options-config:" "$OPT_CFG"
  echo "Options-JSON-Syntax:  $(fxR '[ERR]')"
  printf '%s\n' "$OPTS_JSON" | sed -n '1,200p' | sed 's/^/  /'
  exit 10
fi
OPTS_LINE="$(printf '%s\n' "$OPTS_JSON" | awk -F'OPTS\\|' 'NF>1{print $2; exit}')"
[ -n "$OPTS_LINE" ] || { kv "Options-config:" "$OPT_CFG"; echo "$(fxR '✖') Options-Config konnte nicht extrahiert werden."; exit 10; }

OPT_PROFILE="$(printf '%s' "$OPTS_LINE" | jq -r '.profile')"
OPT_DEBUG="$(  printf '%s' "$OPTS_LINE" | jq -r '.options.debug')"
OPT_KEEP="$(   printf '%s' "$OPTS_LINE" | jq -r '.options.debug_keep')"
OPT_MIN_KEEP="$(printf '%s' "$OPTS_LINE" | jq -r '.options.debug_min_keep')"
OPT_AGE="$(    printf '%s' "$OPTS_LINE" | jq -r '.options.debug_age')"
OPT_MINIFY="$( printf '%s' "$OPTS_LINE" | jq -r '.options.minify')"
OPT_LINK="$(   printf '%s' "$OPTS_LINE" | jq -r '.options.link_mode')"
MIN_BIN="$(     printf '%s' "$OPTS_LINE" | jq -r '.options.minifier.bin // "html-minifier-terser"')"
readarray -t MIN_ARGS_ARR < <(printf '%s' "$OPTS_LINE" | jq -r '.options.minifier.args // [] | .[]')

# CLI-Overrides (nur nach erfolgreichem Load)
[ -n "$CLI_DEBUG_MODE" ] && OPT_DEBUG="$CLI_DEBUG_MODE"
[ -n "$CLI_DKEEP" ]      && OPT_KEEP="$CLI_DKEEP"
[ -n "$CLI_DAGE" ]       && OPT_AGE="$CLI_DAGE"
[ -n "$CLI_MINIFY" ]     && OPT_MINIFY="$CLI_MINIFY"

# Validierung Overrides
case "$OPT_DEBUG" in off|dbg|trace|xtrace|all) ;; *) echo "$(fxR '✖') Ungültiger --debug=$OPT_DEBUG"; exit 10;; esac
case "$OPT_MINIFY" in yes|no) ;; *) echo "$(fxR '✖') Ungültiger --minify=$OPT_MINIFY"; exit 10;; esac
case "$OPT_KEEP" in ''|*[!0-9]*) echo "$(fxR '✖') --debug-keep erwartet Zahl >=2"; exit 10;; esac
[ "$OPT_KEEP" -ge 2 ] || { echo "$(fxR '✖') debug_keep < 2"; exit 10; }
[ "$OPT_MIN_KEEP" -ge 2 ] || { echo "$(fxR '✖') options.debug_min_keep < 2"; exit 10; }
[ "$OPT_MIN_KEEP" -le "$OPT_KEEP" ] || { echo "$(fxR '✖') debug_min_keep > debug_keep"; exit 10; }

# Alters-Parsing
age_to_secs(){ local s="${1//[[:space:]]/}"; local n="${s::-1}"; local u="${s: -1}";
  case "$n" in ''|*[!0-9]*) return 1;; esac
  case "$u" in s|S) echo "$((n))";; m|M) echo "$((n*60))";; h|H) echo "$((n*3600))";; d|D) echo "$((n*86400))";; *) return 1;; esac; }
AGE_SECS="$(age_to_secs "$OPT_AGE" || true)"

# Debug initialisieren & rotieren
XTRACE_CUR=""
if [ "$OPT_DEBUG" = "xtrace" ] || [ "$OPT_DEBUG" = "all" ]; then
  ts_run="$(TZ=Europe/Berlin date +%Y%m%d-%H%M%S)"
  XTRACE_CUR="$DEBUG_DIR/${SCRIPT_ID}.xtrace.$ts_run.jsonl"
  exec 9> "$XTRACE_CUR" || true
  export BASH_XTRACEFD=9
  export PS4='+ ${BASH_SOURCE##*/}:${LINENO}: ${FUNCNAME[0]:-main}() '
  set -x
fi
rotate_debugs(){ local max_age="${1:-43200}" max_keep="${2:-5}" min_keep="${3:-2}"
  local now epoch age; now="$(date +%s)"
  mapfile -t all < <(ls -1t "$DEBUG_DIR"/*.jsonl 2>/dev/null || true)
  [ "${#all[@]}" -gt 0 ] || return 0
  local i=0
  for f in "${all[@]}"; do
    if [ $i -lt "$min_keep" ]; then : ; else
      epoch="$(stat -c %Y -- "$f" 2>/dev/null || echo 0)"; age=$(( now - epoch ))
      if [ $i -ge "$max_keep" ] || { [ -n "$max_age" ] && [ "$age" -gt "$max_age" ]; }; then
        mv -f -- "$f" "$TRASH_DIR/" 2>/dev/null || true
      fi
    fi
    i=$((i+1))
  done
}
rotate_debugs "$AGE_SECS" "$OPT_KEEP" "$OPT_MIN_KEEP"

MODE_SEC="ALL"; [ -n "$ONLY_ID" ] && MODE_SEC="ID=$ONLY_ID"

# CSS-JSON Syntaxcheck (strikt, Pflicht)
JSON_CHK_CSS="$(python3 - "$CFG_CSS" <<'PY'
import sys, json
from pathlib import Path
p=Path(sys.argv[1])
try:
    json.load(p.open('r',encoding='utf-8')); print("OK")
except json.JSONDecodeError as e:
    print(f"ERR|{e.msg}|{e.lineno}|{e.colno}")
    lines=p.read_text(encoding='utf-8',errors='replace').splitlines()
    ln=e.lineno
    for i in range(max(1,ln-1),min(len(lines),ln+1)+1):
        mark=">>" if i==ln else "  "
        print(f"SNIP|{mark}|{i}|{lines[i-1]}")
PY
)"
if ! printf '%s\n' "$JSON_CHK_CSS" | head -n1 | grep -q '^OK$'; then
  kv "Options-config:"     "$OPT_CFG"
  kv "Options-JSON-Syntax:" "$(fxG '[OK]')"
  kv "Options-Schema:"      "$(fxG '[OK]')"
  sep
  kv "CSS-config:"          "$CFG_CSS"
  kv "CSS-JSON-Syntax:"     "$(fxR '[ERR]')"
  printf '%s\n' "$JSON_CHK_CSS" | sed -n '1,200p' | sed 's/^/  /'
  exit 7
fi

# JS-JSON Syntaxcheck (optional: nur wenn Datei existiert)
JSON_CHK_JS=""
if [ -f "$CFG_JS" ]; then
  JSON_CHK_JS="$(python3 - "$CFG_JS" <<'PY'
import sys, json
from pathlib import Path
p=Path(sys.argv[1])
try:
    json.load(p.open('r',encoding='utf-8')); print("OK")
except json.JSONDecodeError as e:
    print(f"ERR|{e.msg}|{e.lineno}|{e.colno}")
    lines=p.read_text(encoding='utf-8',errors='replace').splitlines()
    ln=e.lineno
    for i in range(max(1,ln-1),min(len(lines),ln+1)+1):
        mark=">>" if i==ln else "  "
        print(f"SNIP|{mark}|{i}|{lines[i-1]}")
PY
)"
fi

# Sammel-Funktionen
pairs_for(){ jq -r --arg id "$1" '
  .audits[$id] as $root
  | if $root == null then empty else
      ( $root
        | paths(scalars) as $p
        | ($root | getpath($p)) as $v
        | select($v|type=="string")
        | [ ($p|map(tostring)|join(".")), $v ] ),
      ( $root
        | to_entries[]
        | select(.value|type=="object" and (.value|has("files")))
        | .key as $k
        | .value.files
        | if type=="array" then
            to_entries[] | [ ($k + "[" + ( .key|tostring ) + "]"), .value ]
          elif type=="string" then [ $k, . ] else empty end )
      | @tsv
    end' "$2"; }

PY_RESOLVER="$(mktemp)"
cat >"$PY_RESOLVER" <<'PY'
import sys, json, os, re
if len(sys.argv) < 3: sys.exit(2)
cfg, mode = sys.argv[1], sys.argv[2]
d = json.load(open(cfg,'r',encoding='utf-8'))
v = dict((d.get('vars') or {}).items())
def ex(s): return os.path.abspath(os.path.expanduser(os.path.expandvars(str(s))))
v = { k: (os.environ.get("HOME","") if k=="HOME" else ex(val)) for k,val in v.items() }
def sub_all(txt:str)->str:
    txt = re.sub(r'\${([A-Za-z_]\w*)}', lambda m: v.get(m.group(1), m.group(0)), str(txt))
    txt = re.sub(r'\$([A-Za-z_]\w*)',   lambda m: v.get(m.group(1), m.group(0)), txt)
    return ex(txt)
for line in sys.stdin:
    if "\t" not in line: continue
    label, raw = line.rstrip("\n").split("\t",1)
    res = sub_all(raw)
    if mode=="show":
        print("\t".join([label, raw, res]))
    else:
        st = "OK" if os.path.isfile(res) else "ERR"
        print("\t".join([label, res, st]))
PY
resolve_batch(){ python3 "$PY_RESOLVER" "$1" "$2"; }

# Sektionen ermitteln
SECS=()
if [ -n "$ONLY_ID" ]; then
  if jq -e --arg id "$ONLY_ID" '.audits[$id]' "$CFG_CSS" >/dev/null 2>&1; then SECS=("$ONLY_ID"); else echo "Sektion nicht gefunden: $ONLY_ID"; rm -f "$PY_RESOLVER"; exit 5; fi
else
  while IFS= read -r s; do SECS+=("$s"); done < <(jq -r '.audits | keys[]' "$CFG_CSS")
  [ ${#SECS[@]} -gt 0 ] || { echo "Keine Sektionen unter .audits (CSS-Config) gefunden."; rm -f "$PY_RESOLVER"; exit 6; }
fi

css_sec_status="Missing"
jq -e --arg id "$SCRIPT_ID" '.audits[$id]' "$CFG_CSS" >/dev/null 2>&1 && css_sec_status="OK"

TOTAL_OK=0; TOTAL_ERR=0; TOTAL_ALL=0
for sec in "${SECS[@]}"; do
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    :
  done < <(pairs_for "$sec" "$CFG_CSS") \
  | resolve_batch "$CFG_CSS" check \
  | while IFS=$'\t' read -r _ resolved st; do
      [ -n "$resolved" ] || continue
      TOTAL_ALL=$((TOTAL_ALL+1))
      if [ "$st" = "OK" ]; then TOTAL_OK=$((TOTAL_OK+1)); else TOTAL_ERR=$((TOTAL_ERR+1)); fi
    done
done

# Terminal Kopf (kompakt)
kv "Options-config:"      "$OPT_CFG"
kv "Options-JSON-Syntax:" "$(fxG '[OK]')"
kv "Options-Schema:"      "$(fxG '[OK]')"
kv "Options-Profil:"      "$OPT_PROFILE [$(fxG OK)]"
kv "Mode:"                "$(printf 'sections=%s / debug=%s' "$MODE_SEC" "$OPT_DEBUG")"
sep
kv "CSS-config:"          "$CFG_CSS"
kv "CSS-JSON-Syntax:"     "$(fxG '[OK]')"
kv "CSS-Sektion:"         "$(printf '%s [%s]' "$SCRIPT_ID" "$( [ "$css_sec_status" = OK ] && fxG OK || echo Missing )")"
kv "CSS-Summary:"         "$(printf '%s %d / %s %d / Total: %d' "$(fxG '[OK]')" "$TOTAL_OK" "$(fxR '[ERR]')" "$TOTAL_ERR" "$TOTAL_ALL")"
if [ -n "$JSON_CHK_JS" ]; then
  if printf '%s\n' "$JSON_CHK_JS" | head -n1 | grep -q '^OK$'; then
    kv "JS-config:"       "$CFG_JS"
    kv "JS-JSON-Syntax:"  "$(fxG '[OK]')"
  else
    kv "JS-config:"       "$CFG_JS"
    kv "JS-JSON-Syntax:"  "$(fxR '[ERR]')"
  fi
fi
sep
if [ $WITH_OPTIONS -eq 1 ]; then
  echo "Options-Key-Value     $(printf -- '--debug=%s' "$OPT_DEBUG")"
  echo "                      $(printf -- '--debug-keep=%s' "$OPT_KEEP")"
  echo "                      $(printf -- '--debug-age=%s'  "$OPT_AGE")"
  echo "                      $(printf -- '--minify=%s'     "$OPT_MINIFY")"
  echo "                      $(printf -- '--link-mode=%s'  "$OPT_LINK")"
  sep
fi

# ===== HTML/JSON Audit =====
YEAR_NOW="$(TZ=Europe/Berlin date +%Y)"; MON_NOW="$(TZ=Europe/Berlin date +%Y-%m)"
mkdir -p "$AUD_BASE/$YEAR_NOW" || true
LATEST_HTML="$AUD_BASE/latest.html"
LATEST_DIR="$(dirname "$LATEST_HTML")"
MONTHLY_JSON="$AUD_BASE/$YEAR_NOW/$MON_NOW.jsonl"
LATEST_JSON="$AUD_BASE/latest.jsonl"
SCRIPT_CSS="$AUD_BASE/${SCRIPT_ID}.css"
SCRIPT_JS="$AUD_BASE/${SCRIPT_ID}.js"

# Monatsrotation
if [ -f "$LATEST_HTML" ]; then
  MON_PREV="$(TZ=Europe/Berlin date -r "$LATEST_HTML" +%Y-%m 2>/dev/null || echo "")"
  YEAR_PREV="$(TZ=Europe/Berlin date -r "$LATEST_HTML" +%Y 2>/dev/null || echo "")"
  if [ -n "$MON_PREV" ] && [ "$MON_PREV" != "$MON_NOW" ]; then
    mkdir -p "$AUD_BASE/$YEAR_PREV" || true
    mv -f -- "$LATEST_HTML" "$AUD_BASE/$YEAR_PREV/$MON_PREV.html"
  fi
fi

# latest.html initial (Dark + Wide + Marker für CSS/JS-Blöcke)
if [ ! -f "$LATEST_HTML" ]; then
  TS_H1="$(TZ=Europe/Berlin date '+%Y-%m-%d %H:%M:%S %Z')"
  {
    echo '<!doctype html>'
    echo '<html data-bs-theme="dark"><head><meta charset="utf-8"><title>Audit _audits-check-css-path</title>'
    echo '<!-- CSS-LINKS START (auto) -->'
    echo '<!-- CSS-LINKS END (auto) -->'
    echo '<!-- JS-SCRIPTS START (auto) -->'
    echo '<!-- JS-SCRIPTS END (auto) -->'
    echo '</head><body class="bg-body text-body">'
    echo '<main class="container-fluid py-3 px-3 px-md-4">'
    printf '<h1 class="h4 fw-semibold text-body-emphasis mb-1">Audit %s — %s</h1>\n' "$SCRIPT_ID" "$TS_H1"
    printf '<h2 class="h6 text-body-secondary mb-3">%s</h2>\n' "$(html_escape "$SHELLS_DIR/${SCRIPT_ID}.sh")"
  } > "$LATEST_HTML"
fi

# Script-CSS/JS einmalig anlegen (nie überschreiben)
if [ ! -f "$SCRIPT_CSS" ]; then
  cat > "$SCRIPT_CSS" <<'CSS'
/* _audits-check-css-path.css — Platz für eigene Styles
   Beispielbreiten (optional aktivieren/ändern):
   .th-col-1,.td-col-1{width:15%}
   .th-col-2,.td-col-2{width:10%}
   .th-col-4,.td-col-4{width:10%;text-align:center}
   table.audit{width:100%;table-layout:fixed}
*/
CSS
fi
if [ ! -f "$SCRIPT_JS" ]; then
  cat > "$SCRIPT_JS" <<'JS'
// _audits-check-css-path.js — Platz für eigene JS-Helfer im Audit (wird zuletzt geladen)
console.debug('_audits-check-css-path.js geladen');
JS
fi

# Rel/Abs Helper
rel_to_latest(){ python3 - "$LATEST_DIR" "$1" <<'PY'
import sys, os; print(os.path.relpath(sys.argv[2], start=sys.argv[1]))
PY
}
href_for(){ local abs="$1"; case "$OPT_LINK" in absolute) printf 'file://%s' "$abs";; *) rel_to_latest "$abs";; esac; }

# CSS nur für Skript-Sektion
collect_css_for_script_section(){
  local cfg="$1" sec="$SCRIPT_ID"
  pairs_for "$sec" "$cfg" \
  | resolve_batch "$cfg" check \
  | awk -F'\t' 'NF==3 && $3=="OK"{print $2}' \
  | awk '/\.css($|\?)/' | awk '!seen[$0]++'
}

# JS nur für Skript-Sektion (optional, wenn JS-Config existiert & OK)
collect_js_for_script_section(){
  local cfg="$1" sec="$SCRIPT_ID"
  [ -f "$cfg" ] || return 0
  # Wenn JSON_CHK_JS gesetzt & OK, sonst abbrechen
  if [ -n "$JSON_CHK_JS" ] && ! printf '%s\n' "$JSON_CHK_JS" | head -n1 | grep -q '^OK$'; then
    return 0
  fi
  pairs_for "$sec" "$cfg" \
  | resolve_batch "$cfg" check \
  | awk -F'\t' 'NF==3 && $3=="OK"{print $2}' \
  | awk '/\.(m?js)($|\?)/' | awk '!seen[$0]++'
}

insert_block_between_marks(){
  # $1=html, $2=START-Marker, $3=END-Marker, $4=blockfile, $5=fallback_before (Regex wie </head>)
  local html="$1" start="$2" end="$3" blockfile="$4" fallback_pat="$5"
  local out="$(mktemp)"; local in_mark=0 had_mark=0 inserted=0
  while IFS= read -r line; do
    if [[ "$line" == *"$start"* ]]; then had_mark=1; in_mark=1; cat "$blockfile" >> "$out"; continue; fi
    if (( in_mark )); then [[ "$line" == *"$end"* ]] && in_mark=0 && printf '%s\n' "$line" >> "$out" && continue; else :; fi
    if [[ "$line" =~ $fallback_pat ]] && (( had_mark == 0 )) && (( inserted == 0 )); then cat "$blockfile" >> "$out"; inserted=1; fi
    printf '%s\n' "$line" >> "$out"
  done < "$html"
  mv -f -- "$out" "$html"
}

# Build CSS-Block
CSS_BLOCK="$(mktemp)"; : > "$CSS_BLOCK"
{
  echo '<!-- CSS-LINKS START (auto) -->'
  while IFS= read -r abs; do [ -n "$abs" ] || continue; printf '<link rel="stylesheet" href="%s">\n' "$(html_escape "$(href_for "$abs")")"; done < <(collect_css_for_script_section "$CFG_CSS")
  printf '<link rel="stylesheet" href="%s">\n' "$(html_escape "$(href_for "$SCRIPT_CSS")")"
  echo '<!-- CSS-LINKS END (auto) -->'
} >> "$CSS_BLOCK"

# Build JS-Block (nur wenn JS verfügbar)
JS_BLOCK="$(mktemp)"; : > "$JS_BLOCK"
{
  echo '<!-- JS-SCRIPTS START (auto) -->'
  if [ -f "$CFG_JS" ] && { [ -z "$JSON_CHK_JS" ] || printf '%s\n' "$JSON_CHK_JS" | head -n1 | grep -q '^OK$'; }; then
    while IFS= read -r abs; do [ -n "$abs" ] || continue; printf '<script defer src="%s"></script>\n' "$(html_escape "$(href_for "$abs")")"; done < <(collect_js_for_script_section "$CFG_JS")
  fi
  printf '<script defer src="%s"></script>\n' "$(html_escape "$(href_for "$SCRIPT_JS")")"
  echo '<!-- JS-SCRIPTS END (auto) -->'
} >> "$JS_BLOCK"

# Injektion in <head>
insert_block_between_marks "$LATEST_HTML" "<!-- CSS-LINKS START (auto) -->" "<!-- CSS-LINKS END (auto) -->" "$CSS_BLOCK" "</head>"
insert_block_between_marks "$LATEST_HTML" "<!-- JS-SCRIPTS START (auto) -->" "<!-- JS-SCRIPTS END (auto) -->" "$JS_BLOCK" "</head>"
rm -f "$CSS_BLOCK" "$JS_BLOCK"

# >>> Migration (falls alte Dateien noch container-xxl o.ä. haben)
python3 - "$LATEST_HTML" <<'PY'
import sys,re,io
p=sys.argv[1]
try:
    s=io.open(p,'r',encoding='utf-8').read()
except: sys.exit(0)
orig=s
s=re.sub(r'class="([^"]*\b)container-xxl\b','class="\\1container-fluid',s)
if not re.search(r'<html[^>]*data-bs-theme=', s):
    s=re.sub(r'<html(?![^>]*data-bs-theme)([^>]*)>', r'<html data-bs-theme="dark"\\1>', s, count=1)
if s!=orig:
    io.open(p,'w',encoding='utf-8').write(s)
PY

# ===== RUN HTML/JSON =====
RUN_ID="$(TZ=Europe/Berlin date +%Y%m%d-%H%M%S)"
TS_ISO="$(TZ=Europe/Berlin date +%FT%T%z)"
RUN_HTML="$(mktemp)"; TMP_ENTRIES="$(mktemp)"; : >"$TMP_ENTRIES"

printf '<details class="run card mb-3 border-secondary-subtle"><summary class="card-header py-2 px-3 fw-semibold">Run-ID: %s</summary>\n' "$RUN_ID" >> "$RUN_HTML"

total_ok=0; total_err=0

[ $WITH_NOISE -eq 1 ] && echo

for sec in "${SECS[@]}"; do
  RAW_PAIRS=(); while IFS= read -r line; do [ -n "$line" ] || continue; [ "$(printf '%s' "$line" | awk -F'\t' '{print NF}')" -eq 2 ] && RAW_PAIRS+=("$line"); done < <(pairs_for "$sec" "$CFG_CSS")
  RES_CHK=();  while IFS= read -r l; do [ -n "$l" ] && RES_CHK+=("$l");  done < <(printf '%s\n' "${RAW_PAIRS[@]}" | resolve_batch "$CFG_CSS" check)

  {
    printf '<details class="section card mb-3 border-secondary-subtle"><summary class="card-header py-2 px-3 fw-semibold">Sektion: %s</summary>\n' "$(html_escape "$sec")"
    printf '<div class="card-body p-0">\n'
    printf '<p class="small text-body-secondary px-3 pt-2 mb-2">RAW-Paare: %s — RES-Check: %s</p>\n' "${#RAW_PAIRS[@]}" "${#RES_CHK[@]}"
    printf '<div class="table-responsive">\n'
    printf '<table class="audit table table-dark table-striped table-hover table-sm align-middle mb-0">'
    printf '<thead class="table-secondary"><tr>'
    printf '<th class="th-col-1">Section</th>'
    printf '<th class="th-col-2">Label</th>'
    printf '<th class="th-col-3">Resolved Path</th>'
    printf '<th class="th-col-4">Status</th>'
    printf '</tr></thead><tbody>\n'
  } >> "$RUN_HTML"

  sec_ok=0; sec_err=0
  for l in "${RES_CHK[@]}"; do
    label="${l%%$'\t'*}"; rem="${l#*$'\t'}"; resolved="${rem%%$'\t'*}"; st="${rem#*$'\t'}"
    [ -n "$label" ] || continue
    if [ "$st" = "OK" ]; then badge='<span class="badge text-bg-success">OK</span>'; sec_ok=$((sec_ok+1)); else badge='<span class="badge text-bg-danger">ERR</span>'; sec_err=$((sec_err+1)); fi
    {
      printf '<tr>'
      printf '<td class="td-col-1">%s</td>'              "$(html_escape "$sec")"
      printf '<td class="td-col-2">%s</td>'              "$(html_escape "$label")"
      printf '<td class="td-col-3"><code class="text-warning-emphasis">%s</code></td>' "$(html_escape "$resolved")"
      printf '<td class="td-col-4 text-center">%s</td>' "$badge"
      printf '</tr>\n'
    } >> "$RUN_HTML"

    jq -n --arg run_id "$RUN_ID" --arg ts "$TS_ISO" --arg section "$sec" \
          --arg label "$label" --arg resolved "$resolved" --arg status "$st" \
          '{run_id:$run_id, ts:$ts, section:$section, label:$label, resolved:$resolved, status:$status}' \
          >> "$TMP_ENTRIES"
  done
  total_ok=$((total_ok+sec_ok)); total_err=$((total_err+sec_err))

  {
    echo '</tbody></table></div>'
    echo '</div>'
    echo '</details>'
  } >> "$RUN_HTML"
done

{
  echo '<details class="details-list card mb-3 border-secondary-subtle"><summary class="card-header py-2 px-3 fw-semibold">Summary</summary>'
  echo '<ul class="list-group list-group-flush">'
  printf '<li class="list-group-item d-flex justify-content-between align-items-center">Total OK <span class="badge rounded-pill text-bg-success">%s</span></li>\n' "$total_ok"
  printf '<li class="list-group-item d-flex justify-content-between align-items-center">Total ERR <span class="badge rounded-pill text-bg-danger">%s</span></li>\n' "$total_err"
  printf '<li class="list-group-item d-flex justify-content-between align-items-center">Total <span class="badge rounded-pill text-bg-primary">%s</span></li>\n' "$((total_ok+total_err))"
  echo '</ul>'
  echo '</details>'
  echo '</details>'
} >> "$RUN_HTML"

# Append HTML
cat "$RUN_HTML" >> "$LATEST_HTML"

# Optional minify
if [ "$OPT_MINIFY" = "yes" ]; then
  if ! command -v "$MIN_BIN" >/dev/null 2>&1; then
    echo "$(fxR '✖') Minifier '$MIN_BIN' nicht gefunden (PATH)."; exit 11
  fi
  MIN_TMP="$(mktemp)"
  "$MIN_BIN" "${MIN_ARGS_ARR[@]}" -o "$MIN_TMP" "$LATEST_HTML" || { echo "$(fxR '✖') Minify fehlgeschlagen."; exit 11; }
  mv -f -- "$MIN_TMP" "$LATEST_HTML"
fi

# JSONL append + latest.jsonl
mkdir -p "$AUD_BASE/$YEAR_NOW" || true
jq -s --arg run_id "$RUN_ID" --arg ts "$TS_ISO" --arg cfg "$CFG_CSS" \
      --arg script_path "$SHELLS_DIR/${SCRIPT_ID}.sh" \
      --argjson total_ok "$total_ok" --argjson total_err "$total_err" \
      '{run_id:$run_id, ts:$ts, config:$cfg, script:$script_path,
        summary:{total_ok:$total_ok, total_err:$total_err, total:($total_ok+$total_err)},
        entries: .}' "$TMP_ENTRIES" >> "$MONTHLY_JSON"
cp -f -- "$MONTHLY_JSON" "$LATEST_JSON" 2>/dev/null || true

# Cleanup
rm -f "$RUN_HTML" "$TMP_ENTRIES" "$PY_RESOLVER"

# Schlusszeile
printf "%s  Gesamt: %s OK, %s ERR\n" "$(fxBold 'Summary')" "$total_ok" "$total_err"
exit 0
