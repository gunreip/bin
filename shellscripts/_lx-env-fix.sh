#!/usr/bin/env bash
# _lx-env-<check|fix> — HTML-only Audit (APPEND je Run), shared unter _lx_env
# Version: v0.7.2
set -Eeuo pipefail; IFS=$'\n\t'
[ -z "${BASH_VERSION:-}" ] && exec /usr/bin/env bash "$0" "$@"
trap 'rc=$?; echo "ERROR: ${BASH_SOURCE##*/}:${LINENO}: exit $rc while running: ${BASH_COMMAND:-<none>}"; exit $rc' ERR

SELF_PATH(){ readlink -f "$0" 2>/dev/null || printf "%s" "$0"; }
SELF_BASE="$(basename "$(SELF_PATH)")"
case "$SELF_BASE" in
  _lx-env-check.sh|_lx-env-check) SCRIPT_ID="_lx-env-check"; RUN_CLASS="env-check";;
  _lx-env-fix.sh|_lx-env-fix)     SCRIPT_ID="_lx-env-fix";   RUN_CLASS="env-fix";;
  *) SCRIPT_ID="$SELF_BASE"; RUN_CLASS="env-unknown";;
esac
VERSION="v0.7.2"
SHARED_ID="_lx_env"

usage(){ cat <<USAGE
$SCRIPT_ID $VERSION
Erzeugt/aktualisiert gemeinsames HTML-Audit: audits/_lx_env/latest.html (Append je Run)
Optionen: --minify-html=no | --quiet | --help | --version
USAGE
}
MINIFY="yes"; QUIET="no"
for arg in "$@"; do case "$arg" in
  --help) usage; exit 0;;
  --version) echo "$VERSION"; exit 0;;
  --minify-html=no) MINIFY="no";;
  --quiet) QUIET="yes";;
  *) echo "Unbekannte Option: $arg"; usage; exit 2;;
esac; done

# Helpers
abspath(){ case "$1" in /*) printf '%s' "$1";; ~/*) printf '%s' "${HOME}/${1#~/}";; *) printf '%s' "${HOME}/${1#./}";; esac; }
relpath(){ if command -v realpath >/dev/null 2>&1; then realpath --relative-to="$2" "$1" 2>/dev/null || printf '%s' "$1"; else python3 - "$1" "$2" 2>/dev/null <<'PY' || printf '%s' "$1"
import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))
PY
  fi; }
html_escape(){ sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
print_path_br(){ local s="$1" IFS=':'; read -r -a parts <<< "$s"; local first=1 p
  for p in "${parts[@]}"; do [ $first -eq 1 ] && first=0 || printf '<br/>'; printf '%s' "$(printf '%s' "$p" | html_escape)"; done; }
contains_homebin(){ echo ":$1:" | grep -q ":$HOME/code/bin:"; }

# Pfade
ROOT="$HOME/code/bin"; SHELLS="$ROOT/shellscripts"
AUD_DIR="$SHELLS/audits/$SHARED_ID"; mkdir -p "$AUD_DIR"
CSS_FILE="$AUD_DIR/${SHARED_ID}.css"
HTML_FILE="$AUD_DIR/latest.html"
CFG="$HOME/code/bin/templates/css/.css.conf.json"

# Daten erheben (neutral)
PATH_CUR="${PATH:-}"
PATH_LOGIN="$(bash -lc 'printf "%s" "${PATH:-}"' </dev/null || true)"
PATH_INTER="$(bash -ic 'printf "%s" "${PATH:-}"' </dev/null || true)"

BASHRC="$HOME/.bashrc"; BPROF="$HOME/.bash_profile"; PROF="$HOME/.profile"
MARK_BEGIN='BEGIN lx-env include (.bashrc.d)'
has_bashrc_include="no"; grep -q "$MARK_BEGIN" "$BASHRC" 2>/dev/null && has_bashrc_include="yes"
bprof_sources="no"; [ -f "$BPROF" ] && grep -Eq '(^|\s)(\.|source)\s+\$?HOME/.bashrc' "$BPROF" && bprof_sources="yes"
prof_ok="no"; [ -f "$PROF" ] && { grep -q "$MARK_BEGIN" "$PROF" || grep -Eq '(^|\s)(\.|source)\s+\$?HOME/.bashrc' "$PROF"; } && prof_ok="yes"

scan_file(){ local f="$1"; [ -r "$f" ] || return 0
  awk -v mark="$MARK_BEGIN" '
    BEGIN{ include_ln=0 }
    /BEGIN lx-env include \(.bashrc.d\)/{ include_ln=NR }
    !/^[[:space:]]*#/ && /(^|[[:space:];])(export[[:space:]]+)?PATH[[:space:]]*=/
      { if ($0 !~ /\$PATH/) {
          post = (include_ln>0 && NR>include_ln) ? "nach-include" : "vor-include";
          print NR "\t" post "\t" $0
        }
      }' "$f" 2>/dev/null
}
declare -A forensic
add_forensic(){ local f="$1" lines="$2"; [ -n "$lines" ] || return 0; forensic["$f"]="${forensic[$f]:+$'\n'}$lines"; }
for f in "$BASHRC" "$BPROF" "$PROF" /etc/bash.bashrc /etc/profile; do [ -r "$f" ] && add_forensic "$f" "$(scan_file "$f")"; done
for f in /etc/profile.d/*.sh; do [ -r "$f" ] && add_forensic "$f" "$(scan_file "$f")"; done

SHE=0; CR=0
if [ -d "$SHELLS" ]; then
  while IFS= read -r -d '' f; do [ "$(head -1 "$f" 2>/dev/null)" = "#!/usr/bin/env bash" ] || SHE=$((SHE+1)); done < <(find "$SHELLS" -maxdepth 1 -type f -name '*.sh' -print0 2>/dev/null)
  while IFS= read -r -d '' f; do LC_ALL=C grep -q $'\r' "$f" && CR=$((CR+1)); done < <(find "$SHELLS" -maxdepth 1 -type f -name '*.sh' -print0 2>/dev/null)
fi

# Terminal-Short-Report
[ "$QUIET" = "yes" ] || echo "$SCRIPT_ID $VERSION"
printf "target(s): %s\n" "$ROOT"
printf "%-6s %-12s %s\n" "path:" "contains:" "$(contains_homebin "$PATH_CUR" && echo yes || echo no)"
printf "%-6s %-12s %s\n" "init:" "bashrc.d:" "$([ "$has_bashrc_include" = "yes" ] && echo ok || echo missing)"
printf "%-6s %-12s %s\n" ""      "bash_profile:" "$([ "$bprof_sources" = "yes" ] && echo sources || echo no)"
printf "%-6s %-12s %s\n" ""      "profile:" "$([ "$prof_ok" = "yes" ] && echo ok || echo missing)"

fw=0; for k in "${!forensic[@]}"; do [ -n "${forensic[$k]}" ] && fw=$((fw+1)); done
printf "%-6s %-12s %s\n" "find:" "overwriter:" "$fw file(s)"
printf "%-6s %-12s %s\n" "" "shebang-bad:" "$SHE"
printf "%-6s %-12s %s\n" "" "crlf-bad:" "$CR"

# CSS sicherstellen (nur _lx_env.css)
if [ -f "$CSS_FILE" ]; then
  echo "css:   kept:       $CSS_FILE (linked-ok)"
else
  cat > "$CSS_FILE" <<'CSS'
:root{--fg:#222;--bg:#fff;--muted:#666;--accent:#0a7;}
body{font-family:system-ui,Arial,sans-serif;color:var(--fg);background:var(--bg);line-height:1.55;margin:2rem;}
h1{margin:0 0 .25rem 0;font-weight:700}
h2{margin:.25rem 1rem 1rem 0;color:var(--muted);font-weight:500}
code,pre{font-family:ui-monospace,Menlo,Consolas,monospace}
table{border-collapse:collapse;width:100%;margin:1rem 0}
th,td{border:1px solid #ddd;padding:.45rem .6rem;text-align:left}
th{background:#f7f7f7}
details{margin:.35rem 0}
summary{cursor:pointer;color:var(--accent)}
CSS
  echo "css:   wrote:      $CSS_FILE"
fi

# Template-CSS aus .css.conf.json (nur audits._lx_env)
css_links_head(){
  [ -f "$CFG" ] || { echo "<!-- css.conf.json missing -->"; return 0; }
  command -v jq >/dev/null 2>&1 || { echo "<!-- jq missing -->"; return 0; }
  if ! jq -e '.audits["_lx_env"]' "$CFG" >/dev/null; then
    echo "<!-- css: audits._lx_env missing in config -->"; return 0;
  fi
  mapfile -t RAW < <(jq -r '.audits["_lx_env"].files[]?' "$CFG")
  for raw in "${RAW[@]}"; do
    [ -z "$raw" ] && continue
    expanded="$(printf '%s' "$raw" | envsubst)"
    abs="$(abspath "$expanded")"
    if [ ! -f "$abs" ]; then echo "<!-- missing: $abs -->"; continue; fi
    rel="$(relpath "$abs" "$AUD_DIR")"
    printf '  <link rel="stylesheet" href="%s" />\n' "$rel"
  done
}

# Run-Section
build_run_section(){
  local ts_id; ts_id="$(date +%Y%m%d-%H%M%S)"
  local path_ok bashrc_inc bprof prof she cr; local fw_loc="$fw"
  path_ok="$(contains_homebin "$PATH_CUR" && echo yes || echo no)"
  bashrc_inc="$([ "$has_bashrc_include" = "yes" ] && echo ok || echo missing)"
  bprof="$([ "$bprof_sources" = "yes" ] && echo yes || echo no)"
  prof="$([ "$prof_ok" = "yes" ] && echo ok || echo missing)"
  she="$SHE"; cr="$CR"

  echo "<details class=\"run $RUN_CLASS\"><summary>Run-Id: $ts_id</summary>"
  echo "  <table><thead><tr><th>Key</th><th>Value</th></tr></thead><tbody>"
  printf '    <tr><td>PATH enthält ~/code/bin</td><td><code>%s</code></td></tr>\n' "$path_ok"
  printf '    <tr><td>bashrc.d Include</td><td><code>%s</code></td></tr>\n' "$bashrc_inc"
  printf '    <tr><td>.bash_profile sourct .bashrc</td><td><code>%s</code></td></tr>\n' "$bprof"
  printf '    <tr><td>.profile OK</td><td><code>%s</code></td></tr>\n' "$prof"
  printf '    <tr><td>Overwriter-Dateien</td><td><code>%s</code></td></tr>\n' "$fw_loc"
  printf '    <tr><td>Shebang mismatched</td><td><code>%s</code></td></tr>\n' "$she"
  printf '    <tr><td>CRLF</td><td><code>%s</code></td></tr>\n' "$cr"
  echo "  </tbody></table>"

  echo '  <details class="summary"><summary>Summary</summary>'
  echo '    <details class="details-list"><summary>PATH-Ansichten</summary>'
  printf '      <details><summary>aktuelle Shell</summary><pre><code>'; print_path_br "$PATH_CUR"; printf '</code></pre></details>\n'
  printf '      <details><summary>Login-Shell (bash -l)</summary><pre><code>'; print_path_br "$PATH_LOGIN"; printf '</code></pre></details>\n'
  printf '      <details><summary>interaktive Shell (bash -i)</summary><pre><code>'; print_path_br "$PATH_INTER"; printf '</code></pre></details>\n'
  echo '    </details>'

  echo '    <details class="details-list"><summary>Forensik: PATH= ohne $PATH</summary>'
  local any="no"
  for file in "${!forensic[@]}"; do
    local lines="${forensic[$file]}"; [ -n "$lines" ] || continue; any="yes"
    local cnt; cnt="$(printf '%s\n' "$lines" | sed '/^$/d' | wc -l | tr -d ' ')"
    echo "      <details><summary>${file/#$HOME/~} — $cnt Fundstelle(n)</summary>"
    echo "      <ul>"
    while IFS=$'\t' read -r ln pos txt; do
      [ -n "${ln:-}" ] || continue
      local rhs rhs_stripped fix
      rhs="$(printf '%s\n' "$txt" | sed -E 's/.*PATH[[:space:]]*=[[:space:]]*//')"
      rhs_stripped="$(printf '%s' "$rhs" | sed -E 's/^[[:space:]]*["'"'"' ]?//; s/["'"'"'][[:space:]]*$//')"
      fix="PATH=\"$rhs_stripped:\$PATH\""
      printf '        <li><code>%s:</code> <code>%s</code><br/><em>fix:</em> <code>%s</code></li>\n' \
        "$ln" "$(printf '%s' "$txt" | html_escape)" "$(printf '%s' "$fix" | html_escape)"
    done <<< "$lines"
    echo "      </ul>"
    echo "      </details>"
  done
  [ "$any" = "no" ] && echo '      <details inert><summary>keine Fundstellen</summary></details>'
  echo '    </details>'  # /Forensik
  echo '  </details>'    # /summary
  echo '</details>'      # /run
}

# Run bauen
RUN_FILE="$AUD_DIR/.run.$$"; build_run_section > "$RUN_FILE"

# Erstschreibung/Append
if [ ! -s "$HTML_FILE" ]; then
  ts_h="$(date '+%Y-%m-%d %H:%M:%S %Z')"
  {
    echo '<!doctype html>'
    echo '<html lang="de"><head>'
    echo '  <meta charset="utf-8" />'
    echo '  <meta name="viewport" content="width=device-width, initial-scale=1" />'
    printf '  <title>Audit `%s` — %s</title>\n' "$SHARED_ID" "$ts_h"
    css_links_head
    printf '  <link rel="stylesheet" href="%s" />\n' "$(relpath "$CSS_FILE" "$AUD_DIR")"
    echo '</head><body>'
    printf '  <h1>Audit <code>%s</code> — %s</h1>\n' "$SHARED_ID" "$ts_h"
    printf '  <h2 id="%s-subheader">%s - %s</h2>\n' "$SHARED_ID" "$(SELF_PATH)" "$VERSION"
    cat "$RUN_FILE"
    echo '</body></html>'
  } > "$HTML_FILE"
  echo "html:  wrote:      $HTML_FILE"
else
  RUNFILE="$RUN_FILE" perl -0777 -i -pe 'BEGIN{ my $rf=$ENV{RUNFILE} or die "RUNFILE env missing";
    open my $fh,"<",$rf or die $!; local $/; our $RUN=<$fh>; } s{</body>}{$RUN</body>}s' "$HTML_FILE"
  echo "html:  appended:   $HTML_FILE"
fi
rm -f "$RUN_FILE"

# Runs zählen
if command -v grep >/dev/null 2>&1; then
  total="$(grep -o '<details class="run ' "$HTML_FILE" | wc -l | tr -d ' ')"
  printf "runs:  total:      %s\n" "$total"
fi

# optional minify
if [ "$MINIFY" = "yes" ] && command -v html-minifier-terser >/dev/null 2>&1; then
  html-minifier-terser --collapse-whitespace --remove-comments --minify-css true --minify-js true \
    -o "${HTML_FILE}.min" "$HTML_FILE" >/dev/null 2>&1 && mv -f "${HTML_FILE}.min" "$HTML_FILE" || true
fi

exit 0
