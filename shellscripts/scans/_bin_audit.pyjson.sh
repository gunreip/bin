#!/usr/bin/env bash
# =====================================================================
# bin_audit — Übersicht ~/bin als MD + JSON
# Script-ID: bin_audit
# Version:   v0.9.26
# Datum:     2025-09-12
# TZ:        Europe/Berlin
#
# CHANGELOG
# v0.9.26 (2025-09-12)
#   - MD-Rendering komplett auf `tree -J` + eingebettetes Python3 umgestellt.
#   - Korrekte rekursive Datei-Counts; keine leeren <tt></tt>; Icon hinter Name.
# v0.9.25 (2025-09-12)  Entfernt ANSI (-A); Parser gefixt; Icon-Position.
# v0.9.24 (2025-09-12)  Parser/Counts stabilisiert; Icon hinter Name.
# v0.9.23 (2025-09-11)  UTF-8-Fix; --dir-icon; rekursive Counts (Default).
# v0.9.22 (2025-09-11)  --files-scope={direct,recursive}; Linien in <tt>.
# v0.9.21 (2025-09-11)  latest.* immer aus frischen Buffern (kein Drift).
# v0.9.20 (2025-09-11)  Indent-only/CRLF gefiltert; Inline-Code + *(files:N)*.
# v0.9.19 (2025-09-11)  Kein globaler ```; Inline-Code + Kursiv-Zähler.
# v0.9.18 (2025-09-11)  JSON via `tree -J --noreport` (Fallback: tree_lines).
# v0.9.17–0.9.07       Diverse Stabilitäts-/Format-Fixes.
#
# shellcheck disable=
#
# =====================================================================

set -euo pipefail
IFS=$'\n\t'

SCRIPT_ID="bin_audit"
SCRIPT_VERSION="v0.9.26"
BIN_DIR="${HOME}/bin"
ROOT_SHELL="${BIN_DIR}/shellscripts"

# --- Gatekeeper ---
if [[ "$(pwd -P)" != "$HOME/bin" ]]; then
  echo "Dieses Skript muss aus <tt>~/bin</tt> gestartet werden. Aktuell: \`$(pwd -P)\`" >&2
  exit 2
fi

# --- Flags ---
PRUNE_TRASH=0; QUIET=0; DEBUG=0
UNICODE="yes"; MAX_DEPTH=3; EXCLUDE_LIST=""
SHOW_FILES=0
NO_CORE=0; SELFCHECK=0; STEPS=1
FILES_SCOPE="recursive"               # direct|recursive
DIR_ICON=$'📁\ufe0f'                   # hinter Name

for a in "$@"; do
  case "$a" in
    --prune-trash) PRUNE_TRASH=1;;
    --quiet|-q)    QUIET=1;;
    --debug)       DEBUG=1;;
    --unicode=no)  UNICODE="no";;
    --max-depth=*) MAX_DEPTH="${a#*=}";;
    --exclude=*)   EXCLUDE_LIST="${a#*=}";;
    --show-files)  SHOW_FILES=1;;
    --no-core)     NO_CORE=1;;
    --selfcheck)   SELFCHECK=1;;
    --steps=0|--steps=1|--steps=2) STEPS="${a#*=}";;
    --dir-icon=*)  DIR_ICON="${a#*=}";;
    --files-scope=direct)    FILES_SCOPE="direct";;
    --files-scope=recursive) FILES_SCOPE="recursive";;
    --help|-h)
      cat <<'HLP'
Usage: bin_audit [--quiet|-q] [--debug] [--unicode=no]
                 [--max-depth=N] [--exclude=PATH1,PATH2,...]
                 [--show-files] [--no-core] [--selfcheck]
                 [--steps=0|1|2] [--dir-icon=📁] [--files-scope=direct|recursive]
Beschreibung:
- Strukturblick auf ~/bin. MD nutzt `tree -J` + Python-Renderer (stabile Unicode-Linien).
- Icon steht hinter dem Ordnernamen:  `name` 📁 *(files: N)*.
- N ist standardmäßig **rekursiv**; mit --files-scope=direct nur direkte Dateien.
- Reports: ~/bin/reports/bin_audit/{latest.md,latest.json} (Rotation=5).
HLP
      exit 0;;
    *) echo "Unknown arg: $a"; exit 64;;
  esac
done

# --- Locale ---
if [[ "$UNICODE" == "yes" ]]; then export LC_ALL=C.UTF-8 LANG=C.UTF-8; else export LC_ALL=C LANG=C; fi

# --- Trace ---
DBG_DIR="${BIN_DIR}/debug/bin_audits"; mkdir -p "$DBG_DIR"
TRACE_FILE="${DBG_DIR}/trace_$(date +%Y%m%d_%H%M%S).txt"
(( DEBUG )) && { set -x; exec 9> "$TRACE_FILE"; BASH_XTRACEFD=9; }

# --- Helpers ---
s_main(){ (( QUIET==0 && STEPS>=1 )) && echo "$1"; }
s_sub(){  (( QUIET==0 && STEPS>=2 )) && echo "  - $1"; }
sp(){ case "${1:-}" in "$HOME"*) printf '~%s' "${1#"$HOME"}";; *) printf '%s' "${1:-}";; esac; }
timestamp="$(date +%Y-%m-%dT%H:%M:%S%z)"; stamp_human="$(date +%Y-%m-%d\ %H:%M:%S\ %Z)"

safe_count(){ local dir="${1:-}"; shift || true; [[ -z "$dir" ]] && { printf '0'; return; }
  local out; out="$({ find "$dir" "$@" -printf '.' 2>/dev/null | wc -c | awk '{print $1}'; } 2>/dev/null)" || out=0
  [[ -z "$out" ]] && out=0; printf '%s' "$out"; }

# [1/4] Metriken
s_main "[1/4] Metriken sammeln …"
s_sub "Shellscripts zählen …"; scripts_total=0
[[ -d "$ROOT_SHELL" ]] && scripts_total="$(safe_count "$ROOT_SHELL" -type f -name '*.sh')"
s_sub "Top-Level-Symlinks zählen …"; symlinks_top="$(safe_count "$BIN_DIR" -maxdepth 1 -mindepth 1 -type l)"
s_sub "Broken Symlinks einsammeln …"
BROKEN=(); mapfile -d '' BROKEN < <(find "$BIN_DIR" -type l ! -exec test -e {} \; -print0 2>/dev/null || true) || true
broken_count="${#BROKEN[@]}"

# [2/4] Baum vorbereiten
s_main "[2/4] Baum vorbereiten …"
command -v tree >/dev/null || { echo "❌ 'tree' fehlt (sudo apt-get install -y tree)"; exit 3; }
TREE_ARGS=( "-L" "$MAX_DEPTH" )
(( SHOW_FILES==0 )) && TREE_ARGS+=( "-d" )

# [3/4] Reports bauen
s_main "[3/4] Reports bauen …"
MD_TMP="/tmp/.bin_audit.md"; JSON_TMP="/tmp/.bin_audit.json"

# 3a) JSON aus tree
s_sub "JSON holen …"
JSON_TREE="$(tree -J --noreport "${TREE_ARGS[@]}" "$BIN_DIR" 2>/dev/null || true)"
[[ -z "$JSON_TREE" ]] && { echo "❌ tree -J lieferte nichts."; exit 4; }

# 3b) Counts vorbereiten (direkt) + in Python rekursiv aggregieren
s_sub "Datei-Counts erfassen …"
COUNTS_MAP="$(mktemp)"
find "$BIN_DIR" -type f -printf '%h\n' 2>/dev/null | sort | uniq -c | awk '{c=$1; $1=""; sub(/^ /,""); printf "%s\t%s\n",$0,c}' > "$COUNTS_MAP" || true

# 3c) JSON-Datei schreiben (für spätere Tools)
{
  printf '{\n'
  printf '  "timestamp": "%s",\n' "$timestamp"
  printf '  "root": %s,\n' "\"$(sp "$BIN_DIR")\""
  printf '  "metrics": {"scripts_total": %s, "symlinks_top": %s, "broken_links": %s},\n' "$scripts_total" "$symlinks_top" "$broken_count"
  printf '  "files_scope": "%s",\n' "$FILES_SCOPE"
  printf '  "tree_json": %s\n' "$JSON_TREE"
  printf '}\n'
} > "$JSON_TMP"

# 3d) Markdown aus JSON via Python rendern
s_sub "Markdown rendern …"
TREE_MD="$(python3 - "$JSON_TMP" "$COUNTS_MAP" "$BIN_DIR" "$DIR_ICON" "$FILES_SCOPE" "$SHOW_FILES" <<'PY'
import json, os, sys
json_path, counts_path, root, icon, files_scope, show_files = sys.argv[1:]
show_files = int(show_files)
# Counts (direct) laden
direct = {}
with open(counts_path, 'r', encoding='utf-8') as f:
    for line in f:
        line=line.rstrip('\n')
        if not line: continue
        p, c = line.split('\t',1)
        direct[p] = direct.get(p, 0) + int(c)
# rekursiv aggregieren
agg = {}
for p,c in direct.items():
    cur = p
    while True:
        agg[cur] = agg.get(cur,0) + c
        if cur == root: break
        nxt = os.path.dirname(cur)
        if nxt == cur or not nxt: break
        cur = nxt

def basename(p): 
    return os.path.basename(p.rstrip('/')) or p

def render(node, path, prefixFlags, out):
    # node: json dict; path: full path
    contents = node.get("contents", [])
    # filter files?
    if not show_files:
        contents = [c for c in contents if c.get("type") == "directory"]
    # sort by name
    contents.sort(key=lambda x: (x.get("type")!="directory", x.get("name","")))
    n = len(contents)
    for i,child in enumerate(contents):
        last = (i == n-1)
        pref = "".join(("│   " if more else "    ") for more in prefixFlags)
        connector = ("└── " if last else "├── ")
        pref_str = pref + connector
        nm = child.get("name","")
        cpath = os.path.join(path, nm)
        if child.get("type") == "directory":
            filesN = agg.get(cpath, 0)
            line = (f"<tt>{pref_str}</tt> " if pref_str else "") + f"`{nm}` {icon} *(files: {filesN})*"
            out.append(line)
            render(child, cpath, prefixFlags + [not last], out)
        else:
            line = (f"<tt>{pref_str}</tt> " if pref_str else "") + f"`{nm}`"
            out.append(line)

with open(json_path,'r',encoding='utf-8') as f:
    doc = json.load(f)
rootNode = doc["tree_json"][0]
rootPath = rootNode["name"]
# Root-Zeile
rootFiles = agg.get(rootPath, 0)
out = [ f"`{basename(rootPath)}` {icon} *(files: {rootFiles})*" ]
render(rootNode, rootPath, [], out)
print("\n".join(out))
PY
)"

# MD-Datei zusammensetzen
{
  echo "# bin_audit Summary"
  echo
  echo "- Zeitpunkt: ${stamp_human}"
  echo "- Root Shellscripts: \`$(sp "$ROOT_SHELL")\`"
  echo
  echo "| Metric | Value |"
  echo "|---|---:|"
  echo "| Scripts total | ${scripts_total} |"
  echo "| Symlinks top | ${symlinks_top} |"
  echo "| Broken links | ${broken_count} |"
  echo
  echo "## Verzeichnisüberblick (tree)"
  echo
  printf '%s\n' "$TREE_MD"
} > "$MD_TMP"

# [4/4] Reports schreiben
s_main "[4/4] Reports schreiben …"
REPORT_DIR="$HOME/bin/reports/$SCRIPT_ID"; mkdir -p "$REPORT_DIR"

write_with_core_subshell(){
  local md_file="$1" json_file="$2"
  bash -c '
    set -euo pipefail
    source "$HOME/bin/shellscripts/maintenance/internal/_reports_core.sh"
    reports_init "'"$SCRIPT_ID"'" "$HOME/bin/reports" 5
    reports_write_md   "$(cat "$1")"
    reports_write_json "$(cat "$2")"
    reports_rotate
  ' _ "$md_file" "$json_file"
}
write_fallback_plain(){
  local md_file="$1" json_file="$2" ts; ts="$(date +%Y%m%d_%H%M%S)"
  local md="$REPORT_DIR/latest.md" js="$REPORT_DIR/latest.json"
  [[ -f "$md" ]] && cp -f "$md" "$REPORT_DIR/${SCRIPT_ID}_$ts.md"
  [[ -f "$js" ]] && cp -f "$js" "$REPORT_DIR/${SCRIPT_ID}_$ts.json"
  mv -f "$md_file" "$md"; mv -f "$json_file" "$js"
  ls -1t "$REPORT_DIR"/${SCRIPT_ID}_*.md "$REPORT_DIR"/${SCRIPT_ID}_*.json 2>/dev/null | awk 'NR>5' | xargs -r rm -f || true
}

used_core=0
if (( NO_CORE==0 )) && [[ -f "$HOME/bin/shellscripts/maintenance/internal/_reports_core.sh" ]]; then
  if write_with_core_subshell "$MD_TMP" "$JSON_TMP"; then used_core=1; fi
fi
(( used_core==0 )) && write_fallback_plain "$MD_TMP" "$JSON_TMP"

# latest.* notfalls Symlink → Datei
for ext in md json; do
  f="$REPORT_DIR/latest.$ext"
  if [[ -L "$f" ]]; then
    t="$(readlink -f -- "$f" || true)"
    [[ -n "$t" && -f "$t" ]] && { tmp="$f.tmp.$$"; cp -f -- "$t" "$tmp" && mv -f -- "$tmp" "$f"; }
  fi
done
# Konsistenz: aus Buffern überschreiben
cp -f -- "$MD_TMP"   "$REPORT_DIR/latest.md"
cp -f -- "$JSON_TMP" "$REPORT_DIR/latest.json"

# Abschluss
if (( QUIET == 0 )); then
  echo "✅ bin_audit fertig: Scripts=${scripts_total}  SymlinksTop=${symlinks_top}  Broken=${broken_count}"
  echo "📝 MD:  $REPORT_DIR/latest.md"
  echo "🧾 JSON: $REPORT_DIR/latest.json"
fi
