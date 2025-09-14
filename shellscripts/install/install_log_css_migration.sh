#!/usr/bin/env bash
# install_log_css_migration.sh — migrate to single central CSS + HTML <link> injection
# Version: v1.0.1
set -euo pipefail
IFS=$'\n\t'

CSS_NAME="shell_script_styles.logs.css"
CENTRAL_CSS_DIR="$HOME/.wiki/css"
CENTRAL_CSS_PATH="$CENTRAL_CSS_DIR/$CSS_NAME"

PROJECT=""
ALLOW_PROJECT_OVERRIDE=1
DEPRECATE_WIKI_SYNC=1
DRY_RUN=0
VERBOSE=1

usage() {
  cat <<'HLP'
install_log_css_migration.sh [--project=/path/to/project] [--no-project-override] [--keep-wiki-sync] [--dry-run] [--quiet]
  - creates central CSS (~/.wiki/css/shell_script_styles.logs.css)
  - optional: project override (<project>/.wiki/css/...)
  - wraps log_render_html(.sh) to inject <link rel="stylesheet" ...>
  - moves legacy scattered copies to a backup, deprecates wiki_sync_css.sh
HLP
}

log() { [ "$VERBOSE" -eq 1 ] && printf '%s\n' "$*"; }
run() { if [ "$DRY_RUN" -eq 1 ]; then echo "[DRY] $*"; else eval "$*"; fi; }

# parse args
while [ $# -gt 0 ]; do
  case "$1" in
    --project=*) PROJECT="${1#*=}";;
    --no-project-override) ALLOW_PROJECT_OVERRIDE=0;;
    --keep-wiki-sync) DEPRECATE_WIKI_SYNC=0;;
    --dry-run) DRY_RUN=1;;
    --quiet) VERBOSE=0;;
    --help|-h) usage; exit 0;;
    *) echo "Unknown option: $1"; usage; exit 64;;
  esac
  shift
done

# autodetect project if .env present in CWD
if [ -z "$PROJECT" ] && [ -f ".env" ]; then
  PROJECT="$(pwd)"
fi

STAMP="$(date +%Y%m%d_%H%M%S)"
BAK_ROOT="$HOME/bin/backups/css_migration/$STAMP"
run "mkdir -p \"$BAK_ROOT\""

log "Migration v1.0.1"
log "CENTRAL:  $CENTRAL_CSS_PATH"
[ -n "$PROJECT" ] && log "PROJECT:  $PROJECT"
[ "$ALLOW_PROJECT_OVERRIDE" -eq 1 ] && log "Override: allowed" || log "Override: disabled"
[ "$DEPRECATE_WIKI_SYNC" -eq 1 ] && log "wiki_sync_css: deprecate" || log "wiki_sync_css: keep"
[ "$DRY_RUN" -eq 1 ] && log "MODE: dry-run"

# step 1: central CSS
run "mkdir -p \"$CENTRAL_CSS_DIR\""
SOURCE_ORIGIN="$HOME/bin/css-origin/shell_script_styles.origin.logs.css"
if [ -f "$SOURCE_ORIGIN" ]; then
  log "Copy source: $SOURCE_ORIGIN -> $CENTRAL_CSS_PATH"
  run "cp -a \"$SOURCE_ORIGIN\" \"$CENTRAL_CSS_PATH\""
elif [ -f "$CENTRAL_CSS_PATH" ]; then
  log "Central CSS already present: $CENTRAL_CSS_PATH"
else
  log "No source found, writing minimal CSS (with dark/light + print)"
  run "tee \"$CENTRAL_CSS_PATH\" >/dev/null <<'CSS'
/* shell_script_styles.logs.css — v1.0.0 (base + dark/light + print) */
:root{
  --bg:#ffffff; --fg:#111111; --muted:#666; --border:#ddd; --accent:#2b6cb0;
  --mono: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, Liberation Mono, Courier New, monospace;
}
@media (prefers-color-scheme: dark){
  :root{ --bg:#0f1115; --fg:#e5e7eb; --muted:#9aa0a6; --border:#2a2f3a; --accent:#7aa2f7; }
}
html,body{background:var(--bg);color:var(--fg);margin:0;padding:0;
  font:14px/1.5 system-ui,-apple-system,Segoe UI,Roboto,Ubuntu,Helvetica Neue,Arial,sans-serif;}
a{color:var(--accent);text-decoration:none} a:hover{text-decoration:underline}
code,pre{font-family:var(--mono)}
pre{background:rgba(127,127,127,.08);padding:.75rem;border:1px solid var(--border);border-radius:8px;overflow:auto}
table{border-collapse:collapse;width:100%;margin:1rem 0;border:1px solid var(--border)}
th,td{padding:.5rem .75rem;border-bottom:1px solid var(--border);vertical-align:top}
th{background:rgba(127,127,127,.08);text-align:left}
tbody tr:nth-child(even){background:rgba(127,127,127,.04)}
hr{border:0;border-top:1px solid var(--border);margin:1rem 0}
.small{color:var(--muted);font-size:.9em}
.badge{display:inline-block;padding:.1rem .4rem;border-radius:.5rem;border:1px solid var(--border);background:rgba(127,127,127,.08)}
@media print{
  html,body{background:#fff;color:#000}
  a{text-decoration:underline}
  pre{page-break-inside:avoid}
  table{page-break-inside:auto}
  tr,td{page-break-inside:avoid;page-break-after:auto}
}
CSS"
fi
run "chmod 0644 \"$CENTRAL_CSS_PATH\""

# step 2: optional project override
PROJECT_CSS_PATH=""
if [ "$ALLOW_PROJECT_OVERRIDE" -eq 1 ] && [ -n "$PROJECT" ]; then
  PROJECT_CSS_DIR="$PROJECT/.wiki/css"
  PROJECT_CSS_PATH="$PROJECT_CSS_DIR/$CSS_NAME"
  run "mkdir -p \"$PROJECT_CSS_DIR\""
  if [ ! -f "$PROJECT_CSS_PATH" ]; then
    log "Create project override: $PROJECT_CSS_PATH"
    run "cp -a \"$CENTRAL_CSS_PATH\" \"$PROJECT_CSS_PATH\""
  else
    log "Project override already present: $PROJECT_CSS_PATH"
  fi
fi

# step 3: move legacy scattered copies
log "Search & move legacy copies (.shell_script_styles.logs.css) to backup"
if [ -n "$PROJECT" ]; then
  run "find \"$PROJECT\" -type f -name '.shell_script_styles.logs.css' -print -exec mv -v {} \"$BAK_ROOT\"/ \\; || true"
fi
run "find \"$HOME/bin\" -type f -path \"$HOME/bin/.wiki/logs/.shell_script_styles.logs.css\" -print -exec mv -v {} \"$BAK_ROOT\"/ \\; || true"

# step 4: deprecate wiki_sync_css
if [ "$DEPRECATE_WIKI_SYNC" -eq 1 ]; then
  for CAND in "$HOME/bin/wiki_sync_css.sh" "$HOME/bin/wiki_sync_css"; do
    if [ -f "$CAND" ]; then
      NEW="$CAND.deprecated.$STAMP"
      log "Deprecate: $CAND -> $NEW"
      run "mv -v \"$CAND\" \"$NEW\""
    fi
  done
fi

# step 5: install wrapper for log_render_html(.sh)
install_wrapper_for() {
  local target="$1"
  local base="$(basename -- "$target")"
  if [ -f "$target" ] && [ -x "$target" ]; then
    local bak="$target.orig.$STAMP"
    log "Wrap: $base (backup: $(basename -- "$bak"))"
    run "mv -v \"$target\" \"$bak\""
    run "tee \"$target\" >/dev/null <<'WRAP'"
#!/usr/bin/env bash
# log_render_html (wrapped) — injects CSS <link> after rendering
set -euo pipefail
IFS=$'\n\t'

# 1) call original with all args
shopt -s nullglob
ORIG_CANDIDATES=( "${BASH_SOURCE[0]}".orig.* )
shopt -u nullglob
if [ "${#ORIG_CANDIDATES[@]}" -eq 0 ]; then
  echo "Original script not found: ${BASH_SOURCE[0]}.orig.*" >&2
  exit 3
fi
ORIG_PATH="${ORIG_CANDIDATES[0]}"
"$ORIG_PATH" "$@" || true

# 2) resolve CSS path (env -> project override -> central)
CSS_NAME="shell_script_styles.logs.css"
CENTRAL="$HOME/.wiki/css/$CSS_NAME"
PROJECT_CSS=""
if [ -f ".env" ] && [ -f ".wiki/css/$CSS_NAME" ]; then
  PROJECT_CSS="$(pwd)/.wiki/css/$CSS_NAME"
fi
CSS_PATH="${LOG_CSS_PATH:-${PROJECT_CSS:-$CENTRAL}}"
if [ ! -f "$CSS_PATH" ]; then
  echo "CSS not found: $CSS_PATH" >&2
  exit 0
fi

# 3) find fresh HTMLs (prefer .wiki/logs, last 10 min)
HTMLS=()
if [ -d ".wiki/logs" ]; then
  while IFS= read -r f; do HTMLS+=("$f"); done < <(find ".wiki/logs" -maxdepth 1 -type f -name '*.html' -mmin -10 -print 2>/dev/null || true)
fi
if [ "${#HTMLS[@]}" -eq 0 ]; then
  while IFS= read -r f; do HTMLS+=("$f"); done < <(find . -maxdepth 1 -type f -name '*.html' -mmin -10 -print 2>/dev/null || true)
fi
[ "${#HTMLS[@]}" -eq 0 ] && exit 0

# 4) choose CSS URL: relative for project logs, else file://
make_css_url() {
  local html="$1" css="$2"
  case "$html" in
    */.wiki/logs/*.html)
      if [ "$css" = "$(pwd)/.wiki/css/$CSS_NAME" ]; then
        echo "../css/$CSS_NAME"; return 0
      fi
      ;;
  esac
  echo "file://$css"
}

STAMP="$(date +%Y%m%d%H%M)"
for h in "${HTMLS[@]}"; do
  [ -f "$h" ] || continue
  if grep -q "$CSS_NAME" "$h" 2>/dev/null; then
    continue
  fi
  CSS_URL="$(make_css_url "$h" "$CSS_PATH")"
  LINK="<link rel=\"stylesheet\" href=\"${CSS_URL}?v=${STAMP}\" />"
  # try insert after <head> (lowercase); if not, at top
  if grep -q '<head' "$h"; then
    # replace first <head> occurrence only
    sed -i '0,/<head[[:space:]>]/ s//&\
  '"$LINK"'/' "$h" || true
  else
    sed -i '1s/^/'"$LINK"'\n/' "$h" || true
  fi
  echo "Injected CSS link into: $h"
done
exit 0
WRAP
    "
    run "chmod +x \"$target\""
  fi
}

for C in "$HOME/bin/log_render_html.sh" "$HOME/bin/log_render_html"; do
  install_wrapper_for "$C"
done

log "Done."
log "Central CSS: $CENTRAL_CSS_PATH"
[ -n "${PROJECT_CSS_PATH:-}" ] && log "Project CSS: $PROJECT_CSS_PATH"
log "Backups:     $BAK_ROOT"
