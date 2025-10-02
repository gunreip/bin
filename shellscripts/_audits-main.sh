#!/usr/bin/env bash
# _audits-main.sh — zentrale Audits-TOC
SCRIPT_VERSION="v0.44.1"

set -euo pipefail
set -o errtrace
IFS=$'\n\t'; LC_ALL=C; umask 022

REPO_ROOT="${HOME}/code/bin"
RUN_LOG="${REPO_ROOT}/shellscripts/.einspieler.txt"
SCRIPT_ID="_audits-main"
OPT_CFG="${REPO_ROOT}/shellscripts/lib/.script-options.conf.json"

DEBUG_DIR="${REPO_ROOT}/shellscripts/debugs/${SCRIPT_ID}"
TRASH_DIR="${REPO_ROOT}/trash/backups/${SCRIPT_ID}"
mkdir -p "${DEBUG_DIR}" "${TRASH_DIR}"

_run_ts(){ date +"%Y-%m-%dT%H%M%S%z"; }
run_log(){ printf "[%s] RUN %s\n" "$(_run_ts)" "$*" >> "${RUN_LOG}"; }
trap 'run_log "ERR line=${LINENO} status=$? cmd=${BASH_COMMAND}"' ERR
trap 'run_log "END status=$?"' EXIT

# --- CLI ---------------------------------------------------------------------
THEME="dark"            # dark|light|none
ASSET_ORDER="js-first"  # js-first|css-first
LINK_MODE="relative"    # relative|absolute
COLOR_MODE="auto"       # auto|always|never
CONTEXT="bin"
DEBUG_LEVEL_CLI=""

CLI_SET_THEME="no"
CLI_SET_COLOR="no"

declare -A CLI_OVR=()
for arg in "$@"; do
  case "$arg" in
    --link-mode=absolute) LINK_MODE="absolute" ;;
    --link-mode=relative) LINK_MODE="relative" ;;
    --context=*)          CONTEXT="${arg#*=}" ;;
    --theme=*)            THEME="${arg#*=}"; CLI_SET_THEME="yes" ;;
    --asset-order=*)      ASSET_ORDER="${arg#*=}" ;;
    --color=*)            COLOR_MODE="${arg#*=}"; CLI_SET_COLOR="yes" ;;
    --color-mode=*)       COLOR_MODE="${arg#*=}"; CLI_SET_COLOR="yes" ;;
    --debug=*)            DEBUG_LEVEL_CLI="${arg#*=}" ;;
    --with-*=*)           k="${arg%%=*}"; k="${k#--with-}"; v="${arg#*=}"; CLI_OVR["$k"]="$v" ;;
    --with-*)             k="${arg#--with-}"; CLI_OVR["$k"]="yes" ;;
    --help) echo "Flags: --context=<name> --theme=dark|light|none --asset-order=js-first|css-first --link-mode=relative|absolute --color|--color-mode=auto|always|never --with-<flag>=yes|no --debug=dbg|trace|xtrace|all --version"; exit 0 ;;
    --version) echo "${SCRIPT_VERSION}"; exit 0 ;;
  esac
done
case "$THEME" in dark|light|none) : ;; *) echo "ERROR: invalid --theme=$THEME"; exit 2;; esac
case "$ASSET_ORDER" in js-first|css-first) : ;; *) echo "ERROR: invalid --asset-order=$ASSET_ORDER"; exit 2;; esac
case "$COLOR_MODE" in auto|always|never) : ;; *) echo "ERROR: invalid --color/--color-mode=$COLOR_MODE"; exit 2;; esac

# --- Farben & Logs -----------------------------------------------------------
if [ "${COLOR_MODE}" = "never" ] || [ -n "${NO_COLOR:-}" ]; then DO_COLOR=0
elif [ "${COLOR_MODE}" = "always" ]; then DO_COLOR=1
else if [ -t 2 ]; then DO_COLOR=1; else DO_COLOR=0; fi; fi

# Material-Farben (Truecolor)
C_RESET=$'\e[0m'
C_CFG=$'\e[38;2;79;195;247m'
C_CSS=$'\e[38;2;77;208;225m'
C_JS=$'\e[38;2;171;71;188m'
C_OK=$'\e[38;2;102;187;106m'
C_ERR=$'\e[38;2;239;83;80m'
C_WARN=$'\e[38;2;255;112;67m'
C_DEF=$'\e[38;2;255;255;128m'
C_SCAN=$'\e[38;2;41;182;246m'
C_HTML=$'\e[38;2;129;199;132m'
C_JSONL=$'\e[38;2;255;213;79m'
C_THEME=$'\e[38;2;149;117;205m'
C_INFO=$'\e[38;2;144;164;174m'

LABELW=8; SEP=2; ARROW_COL="${LOG_ARROW_COL:-64}"
log_tag(){
  local tag="$1"; shift; local msg="$*"; local col="$C_INFO" use=1
  case "$tag" in
    CFG) col="$C_CFG";; CSS) col="$C_CSS";; JS) col="$C_JS";; OK) col="$C_OK";;
    ERR) col="$C_ERR";; WARN) col="$C_WARN";; DEFAULT) col="$C_DEF";;
    SCAN) col="$C_SCAN";; HTML) col="$C_HTML";; JSONL) col="$C_JSONL";; THEME) col="$C_THEME";;
    ORDER|ARGS) use=0;;
  esac
  printf -v tpad "%-8s" "${tag}:"
  if [ "$DO_COLOR" -eq 1 ] && [ "$use" -eq 1 ]; then
    printf "%b%s%b%*s%s\n" "$col" "$tpad" "$C_RESET" "$SEP" "" "$msg" >&2
  else
    printf "%s%*s%s\n" "$tpad" "$SEP" "" "$msg" >&2
  fi
  run_log "${tag} ${msg}"
}
log_arrow(){ local tag="$1"; shift; local left="$1"; shift; local right="$*"
  local labelgap=$((LABELW + SEP)); local mincol=$(( ${#left} + labelgap + 4 ))
  local padcol=$ARROW_COL; [ $padcol -lt $mincol ] && padcol=$mincol
  local spaces=$(( padcol - (labelgap + ${#left}) )); [ $spaces -lt 1 ] && spaces=1
  local pad="$(printf '%*s' "$spaces" "")"
  log_tag "$tag" "${left}${pad}-> ${right}"
}

# --- Gatekeeper & Deps -------------------------------------------------------
REQ_CTX="${REPO_ROOT}"
if [ "$(pwd -P)" != "$REQ_CTX" ]; then
  echo "Gatekeeper: Bitte aus ${REQ_CTX} starten." >&2
  exit 2
fi
need(){ command -v "$1" >/dev/null 2>&1 || { log_tag ERR "'$1' not found"; exit 5; }; }
need jq; need python3; need nl; need sed

# --- Utils -------------------------------------------------------------------
normalize_bool(){ case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in yes|true|1) echo "yes";; no|false|0|"") echo "no";; *) echo "no";; esac; }

rotate_files_by_count(){ local d="$1" g="$2" keep_max="${3:-10}" min_keep="${4:-2}"
  [ -d "$d" ] || return 0
  mapfile -t files < <(ls -1t "$d"/$g 2>/dev/null || true)
  local n="${#files[@]}"; [ "$n" -le "$keep_max" ] && return 0
  local idx=$keep_max; while [ "$idx" -lt "$n" ]; do rm -f -- "${files[$idx]}" 2>/dev/null || true; idx=$((idx+1)); done
}

# Merker für aktuelle xtrace-Datei
DEBUG_FILE_XTRACE=""

enable_xtrace(){ local lvl="$1" d="$2" keep="${3:-10}" mkeep="${4:-2}"
  case "$lvl" in xtrace|all)
    mkdir -p "$d"; rotate_files_by_count "$d" "${SCRIPT_ID}.xtrace.*.log" "$keep" "$mkeep"
    local ts; ts="$(date +%Y%m%d-%H%M%S)"; local f="${d}/${SCRIPT_ID}.xtrace.${ts}.log"
    export PS4='+ ${EPOCHREALTIME-} pid:$BASHPID line:${LINENO} ${FUNCNAME:+func:${FUNCNAME[0]}} >>> '
    exec 9>"$f"; export BASH_XTRACEFD=9; set -o xtrace
    DEBUG_FILE_XTRACE="$f"; export DEBUG_FILE_XTRACE
    log_tag JSONL "xtrace → ${f}"
  ;; esac
}

abspath(){ [ -z "${1-}" ] && { echo ""; return 0; }; python3 - "$1" <<'PY' 2>/dev/null || true
import os,sys;p=sys.argv[1];print(os.path.abspath(os.path.expanduser(os.path.expandvars(p))))
PY
}
rel_href(){ [ -z "${1-}" ] || [ -z "${2-}" ] && { echo ""; return 0; }; python3 - "$1" "$2" <<'PY' 2>/dev/null || true
import os,sys;print(os.path.relpath(sys.argv[1], sys.argv[2]))
PY
}

# Kürzt $HOME → ~ und HTML-escaped
pretty_path_html(){
  local p="$1"
  if [ -z "$p" ]; then echo ""; return 0; fi
  local hp="${HOME}/"
  if [[ "$p" == "$hp"* ]]; then p="~/${p#$hp}"; fi
  p="${p//&/\&amp;}"; p="${p//</\&lt;}"; p="${p//>/\&gt;}"
  printf '<tt class="path-to-debug">%s</tt>' "$p"
}

# neueste Datei eines Typs (dbg|trace|xtrace) finden
latest_file(){
  local d="$1" sid="$2" typ="$3"
  mapfile -t files < <(ls -1t "$d"/${sid}.${typ}.*.log 2>/dev/null || true)
  if [ "${#files[@]}" -gt 0 ]; then
    printf '%s' "${files[0]}"
  else
    printf ''
  fi
}

# --- Options-Config ----------------------------------------------------------
[ -f "$OPT_CFG" ] || { log_tag ERR "Options-Config fehlt: $OPT_CFG"; exit 8; }
OPTS_JSON="$(python3 - "$OPT_CFG" "$SCRIPT_ID" <<'PY'
import sys, json, pathlib
cfg, sid = pathlib.Path(sys.argv[1]), sys.argv[2]
doc = json.loads(cfg.read_text(encoding="utf-8"))
defaults = doc.get("defaults") or {}
scripts  = doc.get("scripts")  or {}
merged = dict(defaults)
if isinstance(scripts.get(sid,{}).get("defaults"), dict):
  merged.update(scripts[sid]["defaults"])
print(json.dumps(merged, ensure_ascii=False))
PY
)" || { log_tag ERR "Options-Config unlesbar"; exit 8; }

CFG_THEME="$(     printf '%s' "$OPTS_JSON" | jq -r '.theme       // "dark"')"
CFG_LINK_MODE="$( printf '%s' "$OPTS_JSON" | jq -r '.link_mode   // "relative"')"
CFG_DEBUG="$(      printf '%s' "$OPTS_JSON" | jq -r '.debug       // ""')"
WITH_NOISE="$(     normalize_bool "$(printf '%s' "$OPTS_JSON" | jq -r '.with_noise   // "no"')" )"
WITH_OPTIONS="$(   normalize_bool "$(printf '%s' "$OPTS_JSON" | jq -r '.with_options // "no"')" )"
WITH_CFG_CSS="$(   normalize_bool "$(printf '%s' "$OPTS_JSON" | jq -r '.with_config_css // "no"')" )"
WITH_CFG_JS="$(    normalize_bool "$(printf '%s' "$OPTS_JSON" | jq -r '.with_config_js  // "no"')" )"
WITH_ASSETS="$(    normalize_bool "$(printf '%s' "$OPTS_JSON" | jq -r '.with_assets    // "no"')" )"
WITH_SCANS="$(     normalize_bool "$(printf '%s' "$OPTS_JSON" | jq -r '.with_scans     // "no"')" )"
WITH_PAGES="$(     normalize_bool "$(printf '%s' "$OPTS_JSON" | jq -r '.with_pages     // "no"')" )"
WITH_RESULT="$(    normalize_bool "$(printf '%s' "$OPTS_JSON" | jq -r '.with_result    // "yes"')" )"

[ "$LINK_MODE" = "relative" ] && LINK_MODE="$CFG_LINK_MODE"
DEBUG_LEVEL="${DEBUG_LEVEL_CLI:-$CFG_DEBUG}"

DBG_KEEP="$(printf '%s' "$OPTS_JSON" | jq -r '.debug_keep // 10')"
DBG_MIN_KEEP="$(printf '%s' "$OPTS_JSON" | jq -r '.debug_min_keep // 2')"
case "$DEBUG_LEVEL" in xtrace|all) enable_xtrace "$DEBUG_LEVEL" "$DEBUG_DIR" "$DBG_KEEP" "$DBG_MIN_KEEP" ;; esac

if [ "$WITH_NOISE" = "no" ]; then
  WITH_OPTIONS="no"; WITH_CFG_CSS="no"; WITH_CFG_JS="no"; WITH_ASSETS="no"; WITH_SCANS="no"; WITH_PAGES="no"
fi

# --- Pfade -------------------------------------------------------------------
AUDITS_ROOT="${REPO_ROOT}/shellscripts/audits"
HTML_OUT="${AUDITS_ROOT}/audits-main.html"
SCRIPT_DIR="${AUDITS_ROOT}/${SCRIPT_ID}"
mkdir -p "${AUDITS_ROOT}" "${SCRIPT_DIR}"

CSS_CFG="${REPO_ROOT}/templates/css/.css.conf.json"
JS_CFG="${REPO_ROOT}/templates/js/.js.conf.json"

assert_valid_json(){ local cfg="$1" label="$2" code="${3:-55}"
  if ! jq -e . "$cfg" >/dev/null 2>&1; then log_tag ERR "${label} config invalid JSON: ${cfg}"; exit "$code"; fi
  if [ "$WITH_OPTIONS" = "yes" ]; then log_tag OK "${label} CFG valid: $(basename "$cfg")"; fi
}
assert_valid_json "$CSS_CFG" CSS 41
assert_valid_json "$JS_CFG"  JS  42

cfg_expand(){ local cfg="$1" raw="$2"
  [ -n "$raw" ] || { echo ""; return 0; }
  python3 - "$cfg" "$raw" <<'PY' 2>/dev/null || true
import os, sys, json, re
cfg, raw = sys.argv[1], sys.argv[2]
d = json.load(open(cfg,'r',encoding='utf-8'))
vars = dict((d.get('vars') or {}).items())
def ex(s): return os.path.abspath(os.path.expanduser(os.path.expandvars(str(s))))
for _ in range(8):
  changed=False
  for k,v in list(vars.items()):
    vv = re.sub(r'\${([A-Za-z_]\w*)}', lambda m: vars.get(m.group(1), os.environ.get(m.group(1), m.group(0))), str(v))
    vv = re.sub(r'\$([A-Za-z_]\w*)',   lambda m: vars.get(m.group(1), os.environ.get(m.group(1), m.group(0))), vv)
    vv_ex = ex(vv)
    if vv_ex != vars[k]: vars[k]=vv_ex; changed=True
  if not changed: break
s = str(raw)
s = re.sub(r'\${([A-Za-z_]\w*)}', lambda m: vars.get(m.group(1), os.environ.get(m.group(1), m.group(0))), s)
s = re.sub(r'\$([A-Za-z_]\w*)',   lambda m: vars.get(m.group(1), os.environ.get(m.group(1), m.group(0))), s)
print(ex(s))
PY
}
rel_href(){ [ -z "${1-}" ] || [ -z "${2-}" ] && { echo ""; return 0; }; python3 - "$1" "$2" <<'PY'
import os,sys;print(os.path.relpath(sys.argv[1], sys.argv[2]))
PY
}

declare -a CSS_HREFS JS_HREFS; CSS_HREFS=(); JS_HREFS=()
add_css(){ local h="$1"; [ -z "$h" ] && return 0; for x in "${CSS_HREFS[@]}"; do [ "$x" = "$h" ] && return 0; done; CSS_HREFS+=("$h"); }
add_js(){  local h="$1"; [ -z "$h" ] && return 0; for x in "${JS_HREFS[@]}";  do [ "$x" = "$h" ] && return 0; done; JS_HREFS+=("$h"); }

load_css_from_conf(){
  local href abs raw
  raw="$(jq -r --arg sid "${SCRIPT_ID}" '.audits[$sid].bootstrap? // empty' "${CSS_CFG}")"
  if [ -n "$raw" ]; then
    abs="$(cfg_expand "${CSS_CFG}" "$raw")"
    if [ "$WITH_OPTIONS" = "yes" ]; then log_arrow CFG "audits[${SCRIPT_ID}].bootstrap=${raw}" "${abs}"; fi
    if [ -n "$abs" ] && [ -f "$abs" ]; then
      href="$abs"; if [ "${LINK_MODE}" != "absolute" ]; then href="$(rel_href "$abs" "$(dirname "${HTML_OUT}")")"; fi
      add_css "$href"; if [ "$WITH_ASSETS" = "yes" ]; then log_tag CSS "BOOTSTRAP(sektion) verlinkt → ${href}"; fi
    else
      if [ "$WITH_ASSETS" = "yes" ]; then log_tag WARN "BOOTSTRAP(sektion) fehlt → ${raw}"; fi
    fi
  fi

  raw="$(jq -r '.vars.css_default? // empty' "${CSS_CFG}")"
  if [ -n "$raw" ]; then
    abs="$(cfg_expand "${CSS_CFG}" "$raw")"
    if [ "$WITH_OPTIONS" = "yes" ]; then log_arrow CFG "vars.css_default=${raw}" "${abs}"; fi
    if [ -n "$abs" ] && [ -f "$abs" ]; then
      href="$abs"; if [ "${LINK_MODE}" != "absolute" ]; then href="$(rel_href "$abs" "$(dirname "${HTML_OUT}")")"; fi
      add_css "$href"; if [ "$WITH_ASSETS" = "yes" ]; then log_tag DEFAULT "DEFAULT verlinkt → ${href}"; fi
    else
      if [ "$WITH_ASSETS" = "yes" ]; then log_tag WARN "DEFAULT fehlt → ${raw}"; fi
    fi
  fi

  case "$THEME" in
    dark)  raw="$(jq -r --arg sid "${SCRIPT_ID}" '.audits[$sid].css_audits_dark? // empty' "${CSS_CFG}")"; [ -z "$raw" ] && raw="$(jq -r '.vars.css_audits_dark? // empty' "${CSS_CFG}")" ;;
    light) raw="$(jq -r --arg sid "${SCRIPT_ID}" '.audits[$sid].css_audits_light? // empty' "${CSS_CFG}")"; [ -z "$raw" ] && raw="$(jq -r '.vars.css_audits_light? // empty' "${CSS_CFG}")" ;;
    none)  raw="";;
  esac
  if [ -n "$raw" ]; then
    abs="$(cfg_expand "${CSS_CFG}" "$raw")"
    if [ "$WITH_OPTIONS" = "yes" ]; then log_arrow THEME "THEME(${THEME})=${raw}" "${abs}"; fi
    if [ -n "$abs" ] && [ -f "$abs" ]; then
      href="$abs"; if [ "${LINK_MODE}" != "absolute" ]; then href="$(rel_href "$abs" "$(dirname "${HTML_OUT}")")"; fi
      add_css "$href"; if [ "$WITH_ASSETS" = "yes" ]; then log_tag CSS "THEME(${THEME}) verlinkt → ${href}"; fi
    else
      if [ "$WITH_ASSETS" = "yes" ]; then log_tag WARN "THEME(${THEME}) fehlt → ${raw}"; fi
    fi
  fi
}

load_js_from_conf(){
  local href abs raw
  raw="$(jq -r '.vars.js_default? // empty' "${JS_CFG}")"
  if [ -n "$raw" ]; then
    abs="$(cfg_expand "${JS_CFG}" "$raw")"
    if [ "$WITH_CFG_JS" = "yes" ]; then log_arrow CFG "vars.js_default=${raw}" "${abs}"; fi
    if [ -n "$abs" ] && [ -f "$abs" ]; then
      href="$abs"; if [ "${LINK_MODE}" != "absolute" ]; then href="$(rel_href "$abs" "$(dirname "${HTML_OUT}")")"; fi
      add_js "$href"; if [ "$WITH_ASSETS" = "yes" ]; then log_tag JS "DEFAULT verlinkt → ${href}"; fi
    else
      if [ "$WITH_ASSETS" = "yes" ]; then log_tag WARN "JS SECTION fehlt → ${raw}"; fi
    fi
  fi

  while IFS= read -r raw; do
    [ -z "$raw" ] && continue
    abs="$(cfg_expand "${JS_CFG}" "$raw")"
    if [ -n "$abs" ] && [ -f "$abs" ]; then
      href="$abs"; if [ "${LINK_MODE}" != "absolute" ]; then href="$(rel_href "$abs" "$(dirname "${HTML_OUT}")")"; fi
      add_js "$href"; if [ "$WITH_ASSETS" = "yes" ]; then log_tag JS "SECTION verlinkt → ${href}"; fi
    else
      if [ "$WITH_ASSETS" = "yes" ]; then log_tag WARN "JS SECTION fehlt → ${raw}"; fi
    fi
  done < <(jq -r --arg sid "${SCRIPT_ID}" '.audits[$sid].files? // empty | .[]? // empty' "${JS_CFG}" 2>/dev/null || true)
}

[ "$WITH_OPTIONS" = "yes" ] && log_tag ARGS "theme=${THEME} link_mode=${LINK_MODE} context=${CONTEXT} asset_order=${ASSET_ORDER} color_mode=${COLOR_MODE}"
load_css_from_conf
load_js_from_conf

# eigene Assets
MAIN_CSS="${SCRIPT_DIR}/${SCRIPT_ID}.css"; [ -f "$MAIN_CSS" ] || : > "$MAIN_CSS"
MAIN_JS="${SCRIPT_DIR}/${SCRIPT_ID}.js";  [ -f "$MAIN_JS" ]  || : > "$MAIN_JS"
MAIN_CSS_HREF="$(rel_href "${MAIN_CSS}" "$(dirname "${HTML_OUT}")")"
MAIN_JS_HREF="$( rel_href "${MAIN_JS}"  "$(dirname "${HTML_OUT}")")"
[ "$WITH_OPTIONS" = "yes" ] && log_tag ORDER "asset-order=${ASSET_ORDER}"

# --- Kommentar & Status ------------------------------------------------------
safe_comment(){ local c="$1"; c="${c//$'\r'/}"; c="$(printf '%s' "$c" | head -n1)"
  if [ "$c" = '<span class="no-comment">Noch kein Kommentar!</span>' ] || [ "$c" = "<span class='no-comment'>Noch kein Kommentar!</span>" ]; then printf '%s' "$c"; return; fi
  c="$(printf '%s' "$c" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')"
  c="${c//&lt;code&gt;/<code>}"; c="${c//&lt;\/code&gt;/<\/code>}"; c="${c//&lt;tt&gt;/<tt>}"; c="${c//&lt;\/tt&gt;/<\/tt>}"; c="${c//&lt;br&gt;/<br/>}"
  printf '%s' "$c"
}
badge_for_status(){ case "${1:-ERR}" in OK) echo '<span class="badge text-bg-success">OK</span>';; WARN) echo '<span class="badge text-bg-warning">WARN</span>';; *) echo '<span class="badge text-bg-danger">ERR</span>';; esac; }
read_comment(){ local d="$1" f=""
  if   [ -f "${d}/comment-bin-tree.txt" ]; then f="${d}/comment-bin-tree.txt"
  elif [ -f "${d}/comment-bin.tree.txt" ]; then f="${d}/comment-bin.tree.txt"
  else echo "Kein Kommentar!"; return; fi
  local line; line="$(head -n1 "$f" 2>/dev/null || true)"; [ -n "$line" ] || line="Kein Kommentar!"; echo "${line}"
}
row_status(){ local f="$1"; if [ -r "$f" ] && [ -s "$f" ]; then echo OK; else echo ERR; fi; }

# --- Debug (File(s) → Level → Zahl) -----------------------------------------
DEBUG_LABEL="none"; [ -n "${DEBUG_LEVEL:-}" ] && DEBUG_LABEL="$DEBUG_LEVEL"
case "$DEBUG_LABEL" in all) N_TYPES=3;; dbg|trace|xtrace) N_TYPES=1;; *) N_TYPES=0;; esac

build_files_html(){
  local out="" p
  case "$DEBUG_LABEL" in
    dbg)
      p="$(latest_file "${DEBUG_DIR}" "${SCRIPT_ID}" "dbg")"
      if [ -n "$p" ]; then pretty_path_html "$p"; else printf '<tt class="path-to-debug">—</tt>'; fi
    ;;
    trace)
      p="$(latest_file "${DEBUG_DIR}" "${SCRIPT_ID}" "trace")"
      if [ -n "$p" ]; then pretty_path_html "$p"; else printf '<tt class="path-to-debug">—</tt>'; fi
    ;;
    xtrace)
      if [ -n "${DEBUG_FILE_XTRACE:-}" ] && [ -f "${DEBUG_FILE_XTRACE}" ]; then
        pretty_path_html "${DEBUG_FILE_XTRACE}"
      else
        p="$(latest_file "${DEBUG_DIR}" "${SCRIPT_ID}" "xtrace")"
        if [ -n "$p" ]; then pretty_path_html "$p"; else printf '<tt class="path-to-debug">—</tt>'; fi
      fi
    ;;
    all)
      # vorhandene Dateien pro Typ (falls welche fehlen, zeigen wir nur die vorhandenen)
      p="$(latest_file "${DEBUG_DIR}" "${SCRIPT_ID}" "dbg")"
      if [ -n "$p" ]; then out+="$(pretty_path_html "$p")"; fi
      p="$(latest_file "${DEBUG_DIR}" "${SCRIPT_ID}" "trace")"
      if [ -n "$p" ]; then [ -n "$out" ] && out+=" + "; out+="$(pretty_path_html "$p")"; fi
      if [ -n "${DEBUG_FILE_XTRACE:-}" ] && [ -f "${DEBUG_FILE_XTRACE}" ]; then
        [ -n "$out" ] && out+=" + "; out+="$(pretty_path_html "${DEBUG_FILE_XTRACE}")"
      else
        p="$(latest_file "${DEBUG_DIR}" "${SCRIPT_ID}" "xtrace")"
        if [ -n "$p" ]; then [ -n "$out" ] && out+=" + "; out+="$(pretty_path_html "$p")"; fi
      fi
      if [ -n "$out" ]; then printf '%s' "$out"; else printf '<tt class="path-to-debug">—</tt>'; fi
    ;;
    *) printf '' ;;
  esac
}

case "$DEBUG_LABEL" in
  dbg)    LVL_BDG='<span class="badge rounded-pill text-bg-secondary debug-info">dbg</span>' ;;
  trace)  LVL_BDG='<span class="badge rounded-pill text-bg-primary debug-info">trace</span>' ;;
  xtrace) LVL_BDG='<span class="badge rounded-pill text-bg-warning debug-info">xtrace</span>' ;;
  all)    LVL_BDG='<span class="badge rounded-pill text-bg-dark debug-info">all</span>' ;;
  *)      LVL_BDG='' ;;
esac
FILES_HTML="$(build_files_html)"

# --- Scan & HTML -------------------------------------------------------------
G_SCRIPTS=0; G_FOUND=0; G_MISS=0; G_DUP=0; G_SECTIONS=0

build_sections_html(){
  declare -A SEEN=() SECT_ROWS=() SECT_COUNT=(); declare -a SECT_ORDER=()
  local p_script p_ctx sid ctx latest href key category row status comment
  shopt -s nullglob
  for p_script in "${AUDITS_ROOT}"/*; do
    [ -d "${p_script}" ] || continue
    G_SCRIPTS=$((G_SCRIPTS+1))
    sid="$(basename "${p_script}")"
    category="${sid%%-*}"; [ -n "${category}" ] || category="${sid}"
    if [ -z "${SECT_COUNT[$category]+x}" ]; then SECT_COUNT["$category"]=0; SECT_ROWS["$category"]=""; SECT_ORDER+=("$category"); fi

    if [ -f "${p_script}/latest.html" ]; then
      latest="${p_script}/latest.html"; href="$(rel_href "${latest}" "$(dirname "${HTML_OUT}")")"
      key="$(readlink -f "${latest}" 2>/dev/null || echo "${latest}")"
      if [ -z "${SEEN[$key]+x}" ]; then
        SEEN[$key]=1; status="$(row_status "${latest}")"; comment="$(read_comment "${p_script}")"
        printf -v row '      <tr>\n        <td><tt>%s</tt></td>\n        <td><tt>kein</tt></td>\n        <td>Go to Page <a class="go-page" href="%s" title="Open %s"><tt>%s</tt><span class="link-icon" aria-hidden="true">🔗</span></a></td>\n        <td>%s</td>\n        <td class="text-center">%s</td>\n      </tr>\n' \
          "${sid}" "${href}" "${sid}" "${sid}" "$(safe_comment "${comment}")" "$(badge_for_status "${status}")"
        SECT_ROWS["$category"]+="${row}"; SECT_COUNT["$category"]=$(( SECT_COUNT["$category"] + 1 )); G_FOUND=$((G_FOUND+1))
      else G_DUP=$((G_DUP+1)); fi
    else G_MISS=$((G_MISS+1)); fi

    for p_ctx in "${p_script}"/*; do
      [ -d "${p_ctx}" ] || continue
      ctx="$(basename "${p_ctx}")"
      latest="${p_ctx}/latest.html"
      if [ -f "${latest}" ]; then
        href="$(rel_href "${latest}" "$(dirname "${HTML_OUT}")")"; key="$(readlink -f "${latest}" 2>/dev/null || echo "${latest}")"
        [ -n "${SEEN[$key]+x}" ] && { G_DUP=$((G_DUP+1)); continue; }
        SEEN[$key]=1; status="$(row_status "${latest}")"; comment="$(read_comment "${p_ctx}")"
        printf -v row '      <tr>\n        <td><tt>%s</tt></td>\n        <td><tt>%s</tt></td>\n        <td>Go to Page <a class="go-page" href="%s" title="Open %s/%s"><tt>%s</tt><span class="link-icon" aria-hidden="true">🔗</span></a></td>\n        <td>%s</td>\n        <td class="text-center">%s</td>\n      </tr>\n' \
          "${sid}" "${ctx}" "${href}" "${sid}" "${ctx}" "${sid}" "$(safe_comment "${comment}")" "$(badge_for_status "${status}")"
        SECT_ROWS["$category"]+="${row}"; SECT_COUNT["$category"]=$(( SECT_COUNT["$category"] + 1 )); G_FOUND=$((G_FOUND+1))
      else G_MISS=$((G_MISS+1)); fi
    done
  done
  shopt -u nullglob
  G_SECTIONS=${#SECT_ORDER[@]}

  local cat
  for cat in "${SECT_ORDER[@]}"; do
    printf '  <details class="toc-section card mb-3 border-secondary-subtle">\n'
    printf '    <summary class="card-header py-2 px-3 fw-semibold">Sektion: %s</summary>\n' "${cat}"
    printf '    <div class="card-body p-0">\n'
    printf '      <div class="table-responsive">\n'
    printf '        <table class="table table-dark table-striped table-hover table-sm align-middle mb-0 audit-toc"><thead class="table-secondary"><tr><th>Script-Name</th><th>Context</th><th>Link to Page …</th><th>Kommentar</th><th class="text-center">Status</th></tr></thead><tbody>\n'
    printf '%s' "${SECT_ROWS[$cat]}"
    printf '        </tbody></table>\n'
    printf '      </div>\n'
    printf '    </div>\n'
    printf '  </details>\n'
  done
}

# --- JSONL & HTML ------------------------------------------------------------
JSONL_DIR="${SCRIPT_DIR}/${CONTEXT}"; mkdir -p "${JSONL_DIR}"
JSONL_FILE="${JSONL_DIR}/latest.jsonl"; : > "${JSONL_FILE}"

NOW_HUMAN="$(date +"%d.%m.%Y %H:%M:%S")"
mkdir -p "$(dirname "${HTML_OUT}")"

open_html_head(){
  echo '<!doctype html>'
  if [ "$THEME" = "none" ]; then
    echo '<html lang="de"><head><meta charset="utf-8" /><meta name="viewport" content="width=device-width, initial-scale=1" />'
  else
    echo "<html lang=\"de\" data-bs-theme=\"${THEME}\"><head><meta charset=\"utf-8\" /><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\" />"
    if [ "$THEME" = "dark" ]; then echo '  <meta name="color-scheme" content="dark light" />'; else echo '  <meta name="color-scheme" content="light dark" />'; fi
  fi
  echo '  <title>Audits – Übersicht (TOC)</title>'
}

{
  open_html_head
  if [ "${ASSET_ORDER}" = "js-first" ]; then
    for href in "${JS_HREFS[@]}";  do printf '  <script src="%s" defer></script>\n' "$href"; done
    printf '  <script src="%s" defer></script>\n'  "${MAIN_JS_HREF}"
    for href in "${CSS_HREFS[@]}"; do printf '  <link rel="stylesheet" href="%s" />\n' "$href"; done
    printf '  <link rel="stylesheet" href="%s" />\n' "${MAIN_CSS_HREF}"
  else
    for href in "${CSS_HREFS[@]}"; do printf '  <link rel="stylesheet" href="%s" />\n' "$href"; done
    printf '  <link rel="stylesheet" href="%s" />\n' "${MAIN_CSS_HREF}"
    for href in "${JS_HREFS[@]}";  do printf '  <script src="%s" defer></script>\n' "$href"; done
    printf '  <script src="%s" defer></script>\n'  "${MAIN_JS_HREF}"
  fi

  echo '</head><body class="bg-body text-body"><div class="container-fluid py-3 px-3 px-md-4">'
  printf '  <h1 class="h4 fw-semibold text-body-emphasis mb-1">Audits – Übersicht - %s</h1>\n' "${NOW_HUMAN}"
  echo '  <p class="text-body-secondary">Gruppiert nach Kategorie (Präfix bis zum ersten Bindestrich im Skript-Namen).</p>'
  build_sections_html

  TOTAL_ALL=$(( G_FOUND + G_MISS ))

  # Debug-Item (File(s) → Level → Zahl)
  if [ "${N_TYPES:-0}" -gt 0 ]; then
    DBG_ITEM=$(printf '      <li class="list-group-item d-flex justify-content-between align-items-center">Debug <span><span class="debug-txt-files">File(s):</span> %s <span class="mx-2">&rarr;</span> %s <span class="mx-2">&rarr;</span> <span class="badge rounded-pill text-bg-info n-badge"><tt>%d</tt></span></span></li>\n' "$FILES_HTML" "${LVL_BDG}" "${N_TYPES}")
  else
    DBG_ITEM='      <li class="list-group-item d-flex justify-content-between align-items-center">Debug <span>Keine Debug-Ausgabe! <span class="no-debug">(Für Debug set <tt>--debug=dbg|trace|xtrace|all</tt>)</span> &nbsp; <span class="badge rounded-pill text-bg-info n-badge"><tt>0</tt></span></span></li>'
  fi

  echo '  <details class="toc-section card mb-3 border-secondary-subtle"><summary class="card-header py-2 px-3 fw-semibold">Summary</summary>'
  echo '    <ul class="list-group list-group-flush">'
  printf '      <li class="list-group-item d-flex justify-content-between align-items-center">Kategorien <span class="badge rounded-pill text-bg-primary">%d</span></li>\n' "${G_SECTIONS}"
  printf '      <li class="list-group-item d-flex justify-content-between align-items-center">Skripte total <span class="badge rounded-pill text-bg-secondary">%d</span></li>\n' "${G_SCRIPTS}"
  printf '      <li class="list-group-item d-flex justify-content-between align-items-center">Audits gefunden <span class="badge rounded-pill text-bg-success">%d</span></li>\n' "${G_FOUND}"
  printf '      <li class="list-group-item d-flex justify-content-between align-items-center">Audits fehlend <span class="badge rounded-pill text-bg-danger">%d</span></li>\n' "${G_MISS}"
  printf '      <li class="list-group-item d-flex justify-content-between align-items-center"><i>Gesamt (gefunden+fehlend)</i> <span class="badge rounded-pill text-bg-info">%d</span></li>\n' "${TOTAL_ALL}"
  printf '%s\n' "$DBG_ITEM"
  echo '    </ul>'
  echo '  </details>'

  echo '</div></body></html>'
} > "${HTML_OUT}"

# JSONL
JSONL_DIR="${SCRIPT_DIR}/${CONTEXT}"; mkdir -p "${JSONL_DIR}"
JSONL_FILE="${JSONL_DIR}/latest.jsonl"; : > "${JSONL_FILE}"
ts_iso="$(date -Iseconds)"
printf '{"ts":"%s","event":"summary","html_out":"%s","context":"%s","version":"%s","total_links":"%s"}\n' \
  "$ts_iso" "$HTML_OUT" "$CONTEXT" "$SCRIPT_VERSION" "$(grep -c '<tr>' "$HTML_OUT" || true)" >> "${JSONL_FILE}"

# Abschluss
log_arrow OK "HTML geschrieben" "${HTML_OUT}"
printf 'OK: %s\n' "${HTML_OUT}"
