#!/usr/bin/env bash
# git-branch-prune-local.sh
# Version: v0.4.1
set -euo pipefail; IFS=$'\n\t'

SCRIPT_ID="git-branch-prune-local"
PUBLIC_CMD="$(basename "$0")"
VERSION="v0.4.1"

HOME_BIN="$HOME/code/bin"
SHELLS_DIR_DEFAULT="$HOME_BIN/shellscripts"
STRUCT_CONF="$HOME_BIN/.structure.conf.json"

# --- helpers ---
short_path(){ printf '%s\n' "${1/#$HOME/~}"; }
expand_placeholders(){
  local s="$1"
  s="${s//\$\{HOME\}/$HOME}"; s="${s//\$HOME/$HOME}"
  s="${s//\$\{bin_root\}/$HOME_BIN}"
  s="${s//\$\{shellscripts_root\}/$SHELLS_DIR_DEFAULT}"
  s="${s//\$\{script_id\}/$SCRIPT_ID}"
  printf '%s' "$s"
}
json_str(){ # best-effort JSON lookup
  if command -v jq >/dev/null 2>&1; then jq -r "try ($2|tostring) catch empty" "$1" 2>/dev/null || true; return; fi
  perl -0777 -e '
    use strict; use warnings; local $/; my ($f,$k)=@ARGV; my $j=do{open my $h,"<",$f or exit 0; local $/; <$h>};
    sub esc{$_=shift;s/([[\]{}()^$.|?*+\\])/\\$1/g;$_}
    my @ks=split(/\./,$k); my $rx="";
    for(my $i=0;$i<@ks;$i++){ my $kk=esc($ks[$i]); $rx.=($i<$#ks? "\"$kk\"\\s*:\\s*\\{.*?":"\"$kk\"\\s*:\\s*(?:\"(.*?)\"|([0-9]+(?:\\.[0-9]+)*))"); }
    $j =~ /$rx/s and print(defined $1 && $1 ne "" ? $1 : (defined $2 ? $2 : ""));' "$1" "$2" 2>/dev/null || true
}
attach_script_dir(){ # $1=raw_from_config $2=expanded_path $3=script_id
  case "${1:-}" in *'${script_id}'*) printf '%s\n' "$2"; return;; esac
  case "$2" in */"$3") printf '%s\n' "$2";; *) printf '%s/%s\n' "$2" "$3";; esac
}
semicolon_code_list(){ local out="" it; for it in "$@"; do [ -n "$it" ] || continue; [ -n "$out" ] && out+="; "; out+="<code>$it</code>"; done; printf '%s' "$out"; }
semicolon_rel_paths(){ local out="" it; for it in "$@"; do [ -n "$it" ] || continue; [ -n "$out" ] && out+="; "; out+="<code>${it/#$HOME/~}</code>"; done; printf '%s' "$out"; }

# --- roots (config) ---
AUDIT_ROOT="$SHELLS_DIR_DEFAULT/audits"
RUN_ROOT="$SHELLS_DIR_DEFAULT/runs"
DEBUG_ROOT="$SHELLS_DIR_DEFAULT/debugs"
BACKUP_ROOT="$SHELLS_DIR_DEFAULT/backups"
TRASH_ROOT="$SHELLS_DIR_DEFAULT/trash"
HTML_INLINE="pure"
MINIFY_HTML="yes"
RUN_ID_FMT="%Y%m%d-%H%M%S"
CREATED_FMT="%Y-%m-%d %H:%M:%S"
STRUCT_VERSION="—"; STRUCT_MTIME="—"
raw_audits=""; raw_runs=""; raw_debugs=""; raw_backups=""; raw_trash=""

if [ -f "$STRUCT_CONF" ]; then
  v_shell_raw="$(json_str "$STRUCT_CONF" ".vars.shellscripts_root" || true)"
  if [ -n "${v_shell_raw:-}" ]; then
    SHELLS_DIR_DEFAULT="$(expand_placeholders "$v_shell_raw")"
    AUDIT_ROOT="$SHELLS_DIR_DEFAULT/audits"
    RUN_ROOT="$SHELLS_DIR_DEFAULT/runs"
    DEBUG_ROOT="$SHELLS_DIR_DEFAULT/debugs"
    BACKUP_ROOT="$SHELLS_DIR_DEFAULT/backups"
    TRASH_ROOT="$SHELLS_DIR_DEFAULT/trash"
  fi
  raw_audits="$( json_str "$STRUCT_CONF" ".jobs.audits"  || true)"; [ -n "${raw_audits:-}"  ] && AUDIT_ROOT="$(expand_placeholders "$raw_audits")"
  raw_runs="$(   json_str "$STRUCT_CONF" ".jobs.runs"    || true)"; [ -n "${raw_runs:-}"    ] && RUN_ROOT="$(expand_placeholders "$raw_runs")"
  raw_debugs="$( json_str "$STRUCT_CONF" ".jobs.debugs"  || true)"; [ -n "${raw_debugs:-}"  ] && DEBUG_ROOT="$(expand_placeholders "$raw_debugs")"
  raw_backups="$(json_str "$STRUCT_CONF" ".jobs.backups" || true)"; [ -n "${raw_backups:-}" ] && BACKUP_ROOT="$(expand_placeholders "$raw_backups")"
  raw_trash="$(  json_str "$STRUCT_CONF" ".jobs.trash"   || true)"; [ -n "${raw_trash:-}"   ] && TRASH_ROOT="$(expand_placeholders "$raw_trash")"
  val="$(json_str "$STRUCT_CONF" ".html.inline" || true)";  [ -n "${val:-}" ] && HTML_INLINE="$val"
  val="$(json_str "$STRUCT_CONF" ".html.minify" || true)";  [ -n "${val:-}" ] && MINIFY_HTML="$val"
  STRUCT_VERSION="$(json_str "$STRUCT_CONF" ".version" || true)"; [ -z "${STRUCT_VERSION:-}" ] && STRUCT_VERSION="—"
  STRUCT_MTIME="$(date -r "$STRUCT_CONF" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || stat -c %y "$STRUCT_CONF" 2>/dev/null | cut -d'.' -f1 || echo '—')"
fi

AUDIT_DIR="$( attach_script_dir "$raw_audits"  "$AUDIT_ROOT"  "$SCRIPT_ID" )"
RUN_DIR="$(   attach_script_dir "$raw_runs"    "$RUN_ROOT"    "$SCRIPT_ID" )"
DEBUG_DIR="$( attach_script_dir "$raw_debugs"  "$DEBUG_ROOT"  "$SCRIPT_ID" )"
BACKUP_DIR="$(attach_script_dir "$raw_backups" "$BACKUP_ROOT" "$SCRIPT_ID" )"
TRASH_DIR="$( attach_script_dir "$raw_trash"   "$TRASH_ROOT"  "$SCRIPT_ID" )"

CSS_FILE="$AUDIT_DIR/${SCRIPT_ID}.css"
MD_FILE="$AUDIT_DIR/latest.md"
HTML_FILE="$AUDIT_DIR/latest.html"
mkdir -p "$AUDIT_DIR" "$RUN_DIR" "$DEBUG_DIR" "$BACKUP_DIR" "$TRASH_DIR"

# --- Gatekeeper ---
PWD_P="$(pwd -P)"; REPO_ROOT=""
die(){ echo "$1"; exit "${2:-2}"; }
command -v git >/dev/null 2>&1 || die "Fehler: git nicht gefunden (benötigt)"
if [ "$PWD_P" = "$HOME_BIN" ]; then
  [ -d "$HOME_BIN/.git" ] || die "Gatekeeper: $(short_path "$HOME_BIN") ist kein Git-Repo."
  REPO_ROOT="$HOME_BIN"
else
  if git rev-parse --is-inside-work-tree >/div/null 2>&1; then
    REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"; [ -n "$REPO_ROOT" ] || die "Gatekeeper: Konnte Repo-Root nicht ermitteln."
    [ -f "$REPO_ROOT/.env" ] || die "Gatekeeper: .env fehlt im Repo-Root."
  else die "Gatekeeper: Kein Git-Repo."; fi
fi
[ "$PWD_P" = "$REPO_ROOT" ] || die "Gatekeeper: Bitte aus Repo-Root starten: $(short_path "$REPO_ROOT")"

# --- CLI ---
RAW_ARGS=("$@")
TARGETS=("main"); MIN_AGE_DAYS=7
APPLY="no"; FORCE_DELETE="no"; DRY_RUN="yes"
DBG_MODE="off"  # dbg|trace|xtrace
EXTRA_PROTECTS=()

for arg in "${RAW_ARGS[@]}"; do
  case "$arg" in
    --help) echo "$SCRIPT_ID $VERSION"; exit 0;;
    --version) echo "$VERSION"; exit 0;;
    --only-merged-to=*) IFS=',' read -r -a TARGETS <<<"${arg#*=}";;
    --min-age-days=*) MIN_AGE_DAYS="${arg#*=}";;
    --protect=*) IFS=',' read -r -a EXTRA_PROTECTS <<<"${arg#*=}";;
    --apply) APPLY="yes"; DRY_RUN="no";;
    --force-delete) FORCE_DELETE="yes";;
    --dry-run) DRY_RUN="yes"; APPLY="no";;
    --html-inline=keep|--html-inline=pure) HTML_INLINE="${arg#*=}";;
    --minify-html=yes|--minify-html=no) MINIFY_HTML="${arg#*=}";;
    --debug=dbg|--debug=trace|--debug=xtrace) DBG_MODE="${arg#*=}";;
    *) echo "Unbekannte Option: $arg"; exit 3;;
  esac
done
[ "$APPLY" = "yes" ] || FORCE_DELETE="no"

# --- Debug ---
ts_run="$(date +"$RUN_ID_FMT")"
DBG_FILE=""; TRACE_FILE=""; XTRACE_FILE=""
dbg(){ :; }
case "$DBG_MODE" in
  dbg)
    mkdir -p "$DEBUG_DIR"
    DBG_FILE="$DEBUG_DIR/${SCRIPT_ID}.dbg.$ts_run"
    exec 7> "$DBG_FILE" || true
    dbg(){ printf '%(%F %T)T DBG %s\n' -1 "$*" >&7; }
    ;;
  trace)
    mkdir -p "$DEBUG_DIR"
    TRACE_FILE="$DEBUG_DIR/${SCRIPT_ID}.trace.$ts_run"
    exec 8> "$TRACE_FILE" || true
    trap 'printf "%(%F %T)T TRACE %s:%d: %s\n" -1 "${BASH_SOURCE##*/}" "$LINENO" "$BASH_COMMAND" >&8' DEBUG
    ;;
  xtrace)
    mkdir -p "$DEBUG_DIR"
    XTRACE_FILE="$DEBUG_DIR/${SCRIPT_ID}.xtrace.$ts_run"
    exec 9> "$XTRACE_FILE" || true
    export BASH_XTRACEFD=9
    export PS4='+ ${BASH_SOURCE##*/}:${LINENO}: ${FUNCNAME[0]:-main}() '
    set -x
    ;;
esac

# --- Daten sammeln ---
dbg "Start collection"
current_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
mapfile -t all_branches < <(git for-each-ref --format='%(refname:short)' refs/heads | LC_ALL=C sort)
declare -A age_unix=()
for b in "${all_branches[@]}"; do
  u="$(git for-each-ref --format='%(refname:short) %(committerdate:unix)' "refs/heads/$b" | awk '{print $2}' | tail -1)"
  age_unix["$b"]="${u:-0}"
done

declare -A merged=(); targets_ok=()
if [ "${#TARGETS[@]}" -eq 1 ] && [ "${TARGETS[0]}" = "main" ] && ! git show-ref --verify --quiet refs/heads/main; then
  if git show-ref --verify --quiet refs/heads/master; then
    TARGETS=("master"); echo "Hinweis: 'main' fehlt, nutze Fallback 'master'."
  fi
fi
for t in "${TARGETS[@]}"; do
  if git show-ref --verify --quiet "refs/heads/$t"; then
    targets_ok+=("$t")
    while IFS= read -r m; do merged["$m"]=1; done < <(git branch --merged "$t" --format='%(refname:short)' | sed 's/^\* //')
  else
    echo "WARN: Target-Branch '$t' existiert nicht – ignoriert."
  fi
done

builtin_protect_exact=( "$current_branch" "HEAD" "main" "master" "develop" )
builtin_protect_globs=( "release/*" "hotfix/*" "wip/*" "prod*" "staging*" )
file_protect_globs=()
if [ -f "$REPO_ROOT/.git-prune-protect" ]; then
  while IFS= read -r ln; do
    ln="${ln%%#*}"; ln="$(printf "%s" "$ln" | tr -d '\r' | sed 's/^[ \t]*//; s/[ \t]*$//')"
    [ -n "$ln" ] && file_protect_globs+=("$ln")
  done < "$REPO_ROOT/.git-prune-protect"
fi
is_protected(){
  local b="$1" e p
  for e in "${builtin_protect_exact[@]}"; do [ "$b" = "$e" ] && return 0; done
  for p in "${builtin_protect_globs[@]}" "${EXTRA_PROTECTS[@]}" "${file_protect_globs[@]}"; do case "$b" in $p) return 0;; esac; done
  return 1
}

now="$(date +%s)"; min_age_sec=$(( MIN_AGE_DAYS * 86400 ))
declare -a cand=()
for b in "${all_branches[@]}"; do
  [ -n "${merged[$b]:-}" ] || continue
  age=$(( now - ${age_unix[$b]:-0} ))
  [ "$age" -ge "$min_age_sec" ] && cand+=("$b")
done

declare -a would_delete=() deleted=() kept_protected=() kept_recent=() kept_unmerged=() errors=()
found_total="${#all_branches[@]}"; eligible_total=0
declare -A recent_map=() unmerged_map=()
for b in "${all_branches[@]}"; do
  [ -z "${merged[$b]:-}" ] && unmerged_map["$b"]=1
  age=$(( now - ${age_unix[$b]:-0} ))
  [ "$age" -lt "$min_age_sec" ] && recent_map["$b"]=1
done

repo_name="$(basename "$REPO_ROOT")"
TRASH_RUN_DIR="$TRASH_DIR/$repo_name/$ts_run"
trash_paths=()

dbg "Classify branches"
for b in "${cand[@]}"; do
  if is_protected "$b"; then kept_protected+=("$b"); continue; fi
  eligible_total=$((eligible_total+1))
  if [ "$DRY_RUN" = "yes" ]; then
    would_delete+=("$b")
  else
    mkdir -p "$TRASH_RUN_DIR"
    bundle="$TRASH_RUN_DIR/${b}.bundle"
    if git bundle create "$bundle" "$b" >/dev/null 2>&1; then
      if [ "$FORCE_DELETE" = "yes" ]; then git branch -D -- "$b" >/dev/null 2>&1 || errors+=("$b")
      else git branch -d -- "$b" >/dev/null 2>&1 || errors+=("$b"); fi
      [ -f "$bundle" ] && trash_paths+=("$bundle") || errors+=("$b")
    else
      errors+=("$b")
    fi
  fi
done

for b in "${all_branches[@]}"; do
  if [ -n "${recent_map[$b]:-}" ] && [ -z "${merged[$b]:-}" ]; then
    kept_unmerged+=("$b")
  elif [ -n "${recent_map[$b]:-}" ]; then
    kept_recent+=("$b")
  elif [ -z "${merged[$b]:-}" ]; then
    kept_unmerged+=("$b")
  fi
done

# --- Audit schreiben ---
mkdir -p "$AUDIT_DIR"
[ -f "$MD_FILE" ] || : > "$MD_FILE"
month="$(date +%Y-%m)"
grep -q "^## $month" "$MD_FILE" || printf '## %s\n\n' "$month" >> "$MD_FILE"

opts_cell(){
  local -a toks=() ; local a
  for a in "${RAW_ARGS[@]}"; do case "$a" in -*) toks+=("$a");; esac; done
  local n=${#toks[@]}
  if [ $n -le 0 ]; then printf '—'; return; fi
  local out="" i
  for i in "${!toks[@]}"; do
    [ "$i" -gt 0 ] && out+="<br/>"
    out+="\`$(printf '%s' "${toks[$i]}" | sed 's/--/--/g')\`"
  done
  printf '%s' "$out"
}

created_h="$(date +"$CREATED_FMT")"
repo_short="$(short_path "$REPO_ROOT")"
target_str="$(printf '%s' "$(IFS=,; echo "${targets_ok[*]:-${TARGETS[*]}}")")"
found="${#all_branches[@]}"; eligible="${eligible_total}"
if [ "$DRY_RUN" = "yes" ]; then del_or_would="${#would_delete[@]}"; else del_or_would="${#deleted[@]}"; fi
kept_pro="${#kept_protected[@]}"; kept_rec="${#kept_recent[@]}"; kept_unm="${#kept_unmerged[@]}"; err_cnt="${#errors[@]}"

{
  echo "<details class=\"run\"><summary>Run-Id: $ts_run</summary>"
  echo
  echo "| Script | Version | Created | Optionen | Repo | Target | Min-Age (d) | Found | Eligible | Deleted/Would | Kept-prot | Kept-recent | Kept-unmerged | Errors |"
  echo "|:------ |:-------:| ------: |:-------- |:---- |:------ | ----------: | ----: | -------: | ------------: | --------: | ----------: | ------------: | -----:|"
  echo "| \`$SCRIPT_ID\` | $VERSION | $created_h | $(opts_cell) | \`$repo_short\` | \`$target_str\` | $MIN_AGE_DAYS | $found | $eligible | $del_or_would | $kept_pro | $kept_rec | $kept_unm | $err_cnt |"
  echo
  echo "<details class=\"details-list\"><summary>Summary:</summary>"

  if [ "$DRY_RUN" = "yes" ]; then
    wcnt=${#would_delete[@]}
    echo "<details$([ $wcnt -gt 0 ] && printf ' class=\"relevant-would-delete\"' || printf ' inert')><summary>Would-Delete</summary>"
    [ $wcnt -gt 0 ] && echo "$(semicolon_code_list "${would_delete[@]}")"
    echo "</details>"
    echo "<details$([ $wcnt -gt 0 ] && printf ' class=\"relevant-trash\"' || printf ' inert')><summary>Would move to Trash (bundles)</summary>"
    if [ $wcnt -gt 0 ]; then
      mapfile -t __preview < <(for b in "${would_delete[@]}"; do printf '%s\n' "$TRASH_RUN_DIR/${b}.bundle"; done)
      [ ${#__preview[@]} -gt 0 ] && echo "$(semicolon_rel_paths "${__preview[@]}")"
    fi
    echo "</details>"
  else
    dcnt=${#deleted[@]}
    echo "<details$([ $dcnt -gt 0 ] && printf ' class=\"relevant-deleted\"' || printf ' inert')><summary>Deleted</summary>"
    [ $dcnt -gt 0 ] && echo "$(semicolon_code_list "${deleted[@]}")"
    echo "</details>"
    tcnt=${#trash_paths[@]}
    echo "<details$([ $tcnt -gt 0 ] && printf ' class=\"relevant-trash\"' || printf ' inert')><summary>Moved to Trash (bundles)</summary>"
    [ $tcnt -gt 0 ] && echo "$(semicolon_rel_paths "${trash_paths[@]}")"
    echo "</details>"
  fi

  echo "<details$([ $kept_pro -gt 0 ] && printf ' class=\"relevant-kept-protected\"' || printf ' inert')><summary>Kept (protected)</summary>"
  [ $kept_pro -gt 0 ] && echo "$(semicolon_code_list "${kept_protected[@]}")"
  echo "</details>"

  echo "<details$([ $kept_rec -gt 0 ] && printf ' class=\"relevant-kept-recent\"' || printf ' inert')><summary>Kept (recent)</summary>"
  [ $kept_rec -gt 0 ] && echo "$(semicolon_code_list "${kept_recent[@]}")"
  echo "</details>"

  echo "<details$([ $kept_unm -gt 0 ] && printf ' class=\"relevant-kept-unmerged\"' || printf ' inert')><summary>Kept (unmerged)</summary>"
  [ $kept_unm -gt 0 ] && echo "$(semicolon_code_list "${kept_unmerged[@]}")"
  echo "</details>"

  # Debugs (neu)
  if [ -n "${DBG_FILE:-}" ] || [ -n "${TRACE_FILE:-}" ] || [ -n "${XTRACE_FILE:-}" ]; then
    echo "<details class=\"relevant-debug\"><summary>Debugs</summary>"
    debug_list=()
    [ -n "${DBG_FILE:-}" ]   && debug_list+=("$DBG_FILE")
    [ -n "${TRACE_FILE:-}" ] && debug_list+=("$TRACE_FILE")
    [ -n "${XTRACE_FILE:-}" ] && debug_list+=("$XTRACE_FILE")
    echo "$(semicolon_rel_paths "${debug_list[@]}")"
    echo "</details>"
  else
    echo "<details inert><summary>Debugs</summary></details>"
  fi

  if [ -f "$STRUCT_CONF" ]; then
    echo "<details><summary>Structure-Config</summary>"
    echo "version: <code>$STRUCT_VERSION</code>; mtime: <code>$STRUCT_MTIME</code>"
    echo "</details>"
  fi
  echo "</details>"   # Summary
  echo "</details>"   # Run
  echo
} >> "$MD_FILE"

# --- HTML rendern ---
TITLE="Audit ${SCRIPT_ID} — $(date '+%Y-%m-%d %H:%M:%S %Z')"
PRELUDE="$AUDIT_DIR/.html-prelude.$$"; HTML_IN="$AUDIT_DIR/.html-input.$$"
{ echo "## $HOME_BIN/shellscripts/${SCRIPT_ID}.sh - ${VERSION} {#git-branch-prune-local-subheader}"; echo; } > "$PRELUDE"
cat "$PRELUDE" "$MD_FILE" > "$HTML_IN"
css_opt=(); [ -f "$CSS_FILE" ] && css_opt=(-c "$(basename "$CSS_FILE")")
html_existed=0; [ -f "$HTML_FILE" ] && html_existed=1
pandoc -s --from=gfm+attributes --to=html5 --metadata title="$TITLE" "${css_opt[@]}" --no-highlight -o "$HTML_FILE" "$HTML_IN"
rm -f "$PRELUDE" "$HTML_IN"

# Tabellen "pure" nur mit perl
HTML_MIN_NOTE=""
if [ "$HTML_INLINE" = "pure" ]; then
  if command -v perl >/dev/null 2>&1; then
    perl -0777 -i -pe 's{<(table|thead|tbody|tfoot|tr|t[hd])\b([^>]*?)>}{
      my ($tag,$attrs)=($1,$2); $attrs =~ s/\s+(?:id|class|style)="[^"]*"//gi; $attrs =~ s/\s+/ /g; $attrs =~ s/\s+$//;
      "<$tag".($attrs ne "" ? " $attrs" : "").">"}egix;' "$HTML_FILE"
  else
    HTML_MIN_NOTE="sanitize-skipped (no perl)"
  fi
fi

# HTML minify (optional)
if [ "${MINIFY_HTML}" = "yes" ]; then
  if command -v html-minifier-terser >/dev/null 2>&1; then
    if html-minifier-terser --collapse-whitespace --remove-comments --minify-css true --minify-js true -o "${HTML_FILE}.min" "$HTML_FILE" >/dev/null 2>&1; then
      mv -f "${HTML_FILE}.min" "$HTML_FILE"; HTML_MIN_NOTE="${HTML_MIN_NOTE:+$HTML_MIN_NOTE, }minified"
    else HTML_MIN_NOTE="${HTML_MIN_NOTE:+$HTML_MIN_NOTE, }minify-error"; rm -f "${HTML_FILE}.min" 2>/dev/null || true; fi
  elif command -v html-minifier >/dev/null 2>&1; then
    if html-minifier --collapse-whitespace --remove-comments --minify-css true --minify-js true -o "${HTML_FILE}.min" "$HTML_FILE" >/dev/null 2>&1; then
      mv -f "${HTML_FILE}.min" "$HTML_FILE"; HTML_MIN_NOTE="${HTML_MIN_NOTE:+$HTML_MIN_NOTE, }minified"
    else HTML_MIN_NOTE="${HTML_MIN_NOTE:+$HTML_MIN_NOTE, }minify-error"; rm -f "${HTML_FILE}.min" 2>/dev/null || true; fi
  else
    HTML_MIN_NOTE="${HTML_MIN_NOTE:+$HTML_MIN_NOTE, }minify-skipped (no tool)"
  fi
fi

# --- Terminal-Footer ---
struct_note="Ordner-Struktur: .structure.conf.json - nicht gefunden!"
if [ -f "$STRUCT_CONF" ]; then
  if [ "$STRUCT_VERSION" = "—" ]; then struct_note="Ordner-Struktur: .structure.conf.json - gelesen"
  else struct_note="Ordner-Struktur: .structure.conf.json - gelesen (v$STRUCT_VERSION)"; fi
fi
printf 'target(s): %s / %s\n' "$(short_path "$REPO_ROOT")" "$struct_note"
printf "%-6s %-11s %s\n" "scan:"  "found:"     "${#all_branches[@]}"
printf "%-6s %-11s %s\n" "cand:"  "eligible:"  "$eligible_total (merged + age)"
if [ "$DRY_RUN" = "yes" ]; then
  printf "%-6s %-11s %s\n" "apply:" "would:"    "${#would_delete[@]}"
  printf "%-6s %-11s %s\n" "trash:" "would:"    "${TRASH_DIR/#$HOME/~}/$repo_name/$ts_run (bundles)"
else
  printf "%-6s %-11s %s\n" "apply:" "deleted:"  "${#deleted[@]}"
  printf "%-6s %-11s %s\n" "trash:" "wrote:"    "${TRASH_DIR/#$HOME/~}/$repo_name/$ts_run (${#trash_paths[@]} bundle[s])"
fi
printf "%-6s %-11s %s\n" "md:"    "appended:"   "${MD_FILE/#$HOME/~}"
if [ $html_existed -eq 1 ]; then html_status="overwrote:"; else html_status="wrote:"; fi
printf "%-6s %-11s %s\n" "html:"  "$html_status" "${HTML_FILE/#$HOME/~}"
if [ -n "${HTML_MIN_NOTE:-}" ]; then printf "%-6s %-11s %s\n" "html-min:" "" "$HTML_MIN_NOTE"; fi
if [ -n "${DBG_FILE:-}" ];   then printf "%-6s %-11s %s\n" "dbg:"    "wrote:" "${DBG_FILE/#$HOME/~}"; fi
if [ -n "${TRACE_FILE:-}" ]; then printf "%-6s %-11s %s\n" "trace:"  "wrote:" "${TRACE_FILE/#$HOME/~}"; fi
if [ -n "${XTRACE_FILE:-}" ]; then printf "%-6s %-11s %s\n" "xtrace:" "wrote:" "${XTRACE_FILE/#$HOME/~}"; fi
if [ -f "$CSS_FILE" ]; then
  printf "%-6s %-11s %s\n" "css:" "linked-ok"   "${CSS_FILE/#$HOME/~}"
else
  printf "%-6s %-11s %s\n" "css:" "none"        "${CSS_FILE/#$HOME/~}"
fi

exit 0
