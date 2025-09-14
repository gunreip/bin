#!/usr/bin/env bash
# =====================================================================
# bin_audit — Übersicht ~/bin als MD + JSON
# Script-ID: bin_audit
# Version:   v0.9.32
# Datum:     2025-09-12
# Uhrzeit:   12:34:56
# TZ:        Europe/Berlin
#
# CHANGELOG
# v0.9.33 (2025-09-12) ✅
#   - Changelog-Persist fix (alte Versionseinträge bleiben vollständig erhalten).
#   - „Folders total“ bereits in den Metriken.
#
# v0.9.32 (2025-09-12) ✅
#   - FIX: Vollständiger, nicht komprimierter Changelog wiederhergestellt.
#   - NEU: „Folders total“ (Gesamtzahl Ordner) in Metriken (mit Excludes).
# v0.9.31 (2025-09-12) ❓
#   - Vereinfachung auf Kern-Optionen; Zählungen via `Python`/`os.walk`.
#   - `latest.*` aus `/tmp`, Backups mit Timestamp, Rotation=5.
# v0.9.30 (2025-09-12) ❓
#   - (Zwischenschritt) Export-/Print-Utility; später wieder entfernt.
# v0.9.29 (2025-09-12) ❓
#   - Komplett ohne `find`: Counts via `Python`/`os.walk`; Top-Level-Ordner (Summary).
# v0.9.28 (2025-09-12) ❓
#   - Dynamische find-Optionen; Hänger-Fix in `\[1/4]`.
# v0.9.27 (2025-09-12) ❓
#   - Timeouts; Renderer über `tree -J` + `Python`; Icon hinter Name; rekursive Counts.
# v0.9.26 (2025-09-12) ❓
#   - MD-Rendering komplett auf `tree -J` + `Python` umgestellt; korrekte Counts.
# v0.9.25 (2025-09-12) ❓
#   - Entfernt: `tree -A` (`ANSI`); Parser auf `ASCII`→`Unicode`; Icon-Position gefixt.
# v0.9.24 (2025-09-12) ❓
#   - Parser stabilisiert; keine leeren `<tt></tt>`; Counts repariert.
# v0.9.23 (2025-09-11) ❓
#   - `UTF-8`-Handling (`C.UTF-8`), `--dir-icon`, rekursive Counts Default.
# v0.9.22 (2025-09-11) ❓
#   - `--files-scope=[direct|recursive]`; Linien im `<tt>`.
# v0.9.21 (2025-09-11) ❓
#   - `latest.*` immer aus frischen Buffern (keine Abweichungen).
# v0.9.20 (2025-09-11) ❓
#   - `CRLF`/Indent-Filter; Inline-Code + *(files: N)*.
# v0.9.19 (2025-09-11) ❓
#   - Kein globaler ```-Block; Inline-Code + Kursiv-Zähler.
# v0.9.18 (2025-09-11) ❓
#   - `JSON` via `tree -J --noreport` (Fallback: `tree_lines`).
# v0.9.17 (2025-09-11) ❓
#   - MD: Basenames, Ordner-Icon, *(files: N)*; `JSON`-Baum.
# v0.9.16 (2025-09-11) ❓
#   - Icons nur bei Verzeichnissen; (files: N) je Ordner (direkt).
# v0.9.15 (2025-09-11) ❓
#   - Icon-Stabilität; `JSON`-Dirs-Top; `ASCII`-Backticks.
# v0.9.14 (2025-09-11) ❓
#   - Ordner-Icon integriert.
# v0.9.13 (2025-09-11) ❓
#   - Unicode-Baumlinien per Postprocessing.
# v0.9.12 (2025-09-11) ❓
#   - Steps-Logger; Changelog mit Datum.
# v0.9.11 (2025-09-11) ❓
#   - Tree-only Rendering; Trace-Rotation; `latest.*` als Dateien.
# v0.9.10 (2025-09-11) ❓
#   - safe Counts; Fix `unbound var`; weitere Rotation.
# v0.9.09 (2025-09-11) ❓
#   - Array-Längen-Fix; Header ergänzt.
# v0.9.08 (2025-09-11) ❓
#   - `safe_count()`; `pipefail`-sicher.
# v0.9.07 (2025-09-11) ❓
#   - `--steps=0|1|2`; Core-Fallback; Installer/Backup.
#
# shellcheck disable=
#
# =====================================================================

set -euo pipefail
IFS=$'\n\t'

SCRIPT_ID="bin_audit"
SCRIPT_VERSION="v0.9.32"
BIN_DIR="${HOME}/bin"
ROOT_SHELL="${BIN_DIR}/shellscripts"

# -------- Optionen (nur Kern) --------
QUIET=0; UNICODE="yes"; MAX_DEPTH=3; EXCLUDE_LIST=""
SHOW_FILES=0; STEPS=1
FILES_SCOPE="recursive"   # direct|recursive

for a in "$@"; do
  case "$a" in
    --quiet|-q)    QUIET=1;;
    --unicode=no)  UNICODE="no";;
    --max-depth=*) MAX_DEPTH="${a#*=}";;
    --exclude=*)   EXCLUDE_LIST="${a#*=}";;
    --show-files)  SHOW_FILES=1;;
    --steps=0|--steps=1|--steps=2) STEPS="${a#*=}";;
    --files-scope=direct)    FILES_SCOPE="direct";;
    --files-scope=recursive) FILES_SCOPE="recursive";;
    --help|-h)
      cat <<'HLP'
Usage: bin_audit [--quiet|-q] [--unicode=no] [--max-depth=N]
                 [--exclude=PATH1,PATH2,...] [--show-files]
                 [--steps=0|1|2] [--files-scope=direct|recursive]
Beschreibung:
- Struktur via `tree -J` + Python-Renderer (Unicode-Linien stabil).
- Ordner: `basename` 📁 *(files: N)* — Icon hinter Name.
- `--files-scope=direct` zählt nur **direkte** Dateien; Default `recursive` zählt **Unterbaum**.
- Reports → ~/bin/reports/bin_audit/{latest.md,latest.json} (+ Backups, Rotation=5).
- „Folders total“ = Gesamtzahl Ordner im gescannten Baum (mit Excludes/Depth).
HLP
      exit 0;;
    *) echo "Unknown arg: $a"; exit 64;;
  esac
done

# Gatekeeper
if [[ "$(pwd -P)" != "$HOME/bin" ]]; then
  echo "Dieses Skript muss aus <tt>~/bin</tt> gestartet werden. Aktuell: \`$(pwd -P)\`" >&2
  exit 2
fi

# Locale
if [[ "$UNICODE" == "yes" ]]; then export LC_ALL=C.UTF-8 LANG=C.UTF-8; else export LC_ALL=C LANG=C; fi

# Helpers
s_main(){ (( QUIET==0 && STEPS>=1 )) && echo "$1"; }
s_sub(){  (( QUIET==0 && STEPS>=2 )) && echo "  - $1"; }
sp(){ case "${1:-}" in "$HOME"*) printf '~%s' "${1#"$HOME"}";; *) printf '%s' "${1:-}";; esac; }
timestamp_iso="$(date +%Y-%m-%dT%H:%M:%S%z)"
stamp_human="$(date +%Y-%m-%d\ %H:%M:%S\ %Z)"

# [1/4]
s_main "[1/4] Metriken sammeln …"

# [2/4]
s_main "[2/4] Baum vorbereiten …"
command -v tree >/dev/null 2>&1 || { echo "❌ 'tree' fehlt (sudo apt-get install -y tree)"; exit 3; }
TREE_ARGS=( "-L" "$MAX_DEPTH" )
(( SHOW_FILES==0 )) && TREE_ARGS+=( "-d" )
if [[ -n "$EXCLUDE_LIST" ]]; then
  IFS=, read -r -a _ex <<< "$EXCLUDE_LIST"
  pat=""; for x in "${_ex[@]}"; do [[ -z "$x" ]] && continue; pat="${pat:+$pat|}$x"; done
  [[ -n "$pat" ]] && TREE_ARGS+=( "-I" "$pat" )
fi

# [3/4]
s_main "[3/4] Reports bauen …"
MD_TMP="/tmp/.bin_audit.md"; JSON_TMP="/tmp/.bin_audit.json"; TREE_JSON="/tmp/.bin_audit.tree.json"
s_sub "tree -J --noreport $(sp "$BIN_DIR")"
tree -J --noreport "${TREE_ARGS[@]}" "$BIN_DIR" > "$TREE_JSON"

# Python-Renderer (Counts/MD/JSON)
PY_RENDERER=$(cat <<'PY'
import json, os, sys, io, fnmatch
tree_json_path, md_out, json_out, bin_dir, root_shell, files_scope, show_files_s, ts_iso, exclude_csv = sys.argv[1:]
show_files = int(show_files_s)
bin_dir = os.path.abspath(bin_dir)
ex_patterns = [p for p in (exclude_csv.split(",") if exclude_csv else []) if p]

with io.open(tree_json_path, 'r', encoding='utf-8') as f:
    tree_doc = json.load(f)
root = tree_doc[0]
root_path = os.path.abspath(root["name"])
root_name = os.path.basename(root_path.rstrip('/')) or root_path

# walk mit Excludes (wie tree -I) → wir ignorieren Dirs, deren *Basename* auf ein Muster passt
def prune_dirs(dirnames):
    if not ex_patterns: return dirnames
    keep = []
    for d in dirnames:
        if any(fnmatch.fnmatch(d, pat) for pat in ex_patterns):
            continue
        keep.append(d)
    return keep

direct, recur = {}, {}
dirset = set()

for d,dirs,files in os.walk(root_path, topdown=True, followlinks=False):
    dirset.add(d)
    dirs[:] = prune_dirs(dirs)
    direct[d] = len(files)

for d,c in direct.items():
    cur = d
    while True:
        recur[cur] = recur.get(cur,0) + c
        parent = os.path.dirname(cur)
        if parent == cur or not parent: break
        cur = parent

def dcount(p): return (direct if files_scope=='direct' else recur).get(p, 0)

# Folders total (exkl. Root)
folders_total = max(len(dirset) - 1, 0)

# restliche Metriken
def count_shellscripts(root_shell):
    total = 0
    if not root_shell or not os.path.isdir(root_shell): return 0
    for d,dirs,files in os.walk(root_shell, topdown=True, followlinks=False):
        dirs[:] = prune_dirs(dirs)
        total += sum(1 for f in files if f.endswith('.sh'))
    return total

def symlinks_top(dir_):
    try:
        names = [n for n in os.listdir(dir_) if n not in ex_patterns] if ex_patterns else os.listdir(dir_)
        return sum(1 for nm in names if os.path.islink(os.path.join(dir_, nm)))
    except Exception:
        return 0

def broken_links(dir_):
    b = 0
    for d,dirs,files in os.walk(dir_, topdown=True, followlinks=False):
        dirs[:] = prune_dirs(dirs)
        for nm in dirs + files:
            p = os.path.join(d, nm)
            try:
                if os.path.islink(p) and not os.path.exists(p):
                    b += 1
            except Exception:
                pass
    return b

scripts_total = count_shellscripts(os.path.abspath(root_shell))
symlinks = symlinks_top(root_path)
broken   = broken_links(root_path)

# Markdown
lines = []
icon = "📁"
lines.append(f"`{root_name}` {icon} *(files: {dcount(root_path)})*")

def render(node, abspath, prefix_flags):
    items = node.get("contents", [])
    if not show_files:
        items = [c for c in items if c.get("type") == "directory"]
    items.sort(key=lambda x: (x.get("type")!='directory', x.get("name","")))
    n = len(items)
    for i,ch in enumerate(items):
        last = (i == n-1)
        nm = ch.get("name","")
        p  = os.path.join(abspath, nm)
        pref = "".join(("│   " if more else "    ") for more in prefix_flags)
        conn = ("└── " if last else "├── ")
        if ch.get("type") == "directory":
            lines.append((f"<tt>{pref}{conn}</tt> " if pref or conn else "") + f"`{nm}` {icon} *(files: {dcount(p)})*")
            render(ch, p, prefix_flags + [not last])
        else:
            lines.append((f"<tt>{pref}{conn}</tt> " if pref or conn else "") + f"`{nm}`")

render(root, root_path, [])

# Top-Level Summary
top_summary = []
try:
    children = [n for n in os.listdir(root_path) if os.path.isdir(os.path.join(root_path, n))]
    children = [n for n in children if not any(fnmatch.fnmatch(n, pat) for pat in ex_patterns)]
    for nm in sorted(children):
        p = os.path.join(root_path, nm)
        top_summary.append((nm, dcount(p)))
except Exception:
    pass

# JSON out
doc = {
  "timestamp": ts_iso,
  "root": root_path,
  "files_scope": files_scope,
  "metrics": {
    "scripts_total": int(scripts_total),
    "symlinks_top": int(symlinks),
    "broken_links": int(broken),
    "folders_total": int(folders_total)
  },
  "tree_json": tree_doc
}
with io.open(json_out, 'w', encoding='utf-8') as f:
    json.dump(doc, f, ensure_ascii=False, indent=2)

# MD out
with io.open(md_out, 'w', encoding='utf-8') as f:
    f.write("# bin_audit Summary\n\n")
    f.write(f"- Zeitpunkt: {ts_iso}\n")
    f.write(f"- Root Shellscripts: `{os.path.abspath(root_shell)}`\n\n")
    f.write("| Metric | Value |\n|---|---:|\n")
    f.write(f"| Scripts total | {scripts_total} |\n")
    f.write(f"| Symlinks top | {symlinks} |\n")
    f.write(f"| Broken links | {broken} |\n")
    f.write(f"| Folders total | {folders_total} |\n\n")
    f.write("## Verzeichnisüberblick (tree)\n\n")
    f.write("\n".join(lines))
    f.write("\n\n## Top-Level-Ordner (Summary)\n\n")
    for nm,cnt in top_summary:
        f.write(f"- `{nm}` {icon} *(files: {cnt})*\n")
PY
)

python3 - <<PYEOF "$TREE_JSON" "$MD_TMP" "$JSON_TMP" "$BIN_DIR" "$ROOT_SHELL" "$FILES_SCOPE" "$SHOW_FILES" "$timestamp_iso" "${EXCLUDE_LIST:-}"
$PY_RENDERER
PYEOF

# [4/4] Schreiben (Temp → latest; Backups vorher), Rotation=5
s_main "[4/4] Reports schreiben …"
REPORT_DIR="$HOME/bin/reports/$SCRIPT_ID"; mkdir -p "$REPORT_DIR"
ts2="$(date +%Y%m%d_%H%M%S)"
[[ -f "$REPORT_DIR/latest.md"   ]] && cp -f -- "$REPORT_DIR/latest.md"   "$REPORT_DIR/${SCRIPT_ID}_$ts2.md"   || true
[[ -f "$REPORT_DIR/latest.json" ]] && cp -f -- "$REPORT_DIR/latest.json" "$REPORT_DIR/${SCRIPT_ID}_$ts2.json" || true
cp -f -- "$MD_TMP"   "$REPORT_DIR/latest.md"
cp -f -- "$JSON_TMP" "$REPORT_DIR/latest.json"
ls -1t "$REPORT_DIR"/${SCRIPT_ID}_*.md   2>/dev/null | awk 'NR>5' | xargs -r rm -f || true
ls -1t "$REPORT_DIR"/${SCRIPT_ID}_*.json 2>/dev/null | awk 'NR>5' | xargs -r rm -f || true

# Abschluss
if (( QUIET == 0 )); then
  echo "✅ bin_audit fertig."
  echo "📝 MD:  $REPORT_DIR/latest.md"
  echo "🧾 JSON: $REPORT_DIR/latest.json"
fi

exit 0
