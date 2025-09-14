#!/usr/bin/env bash
# _bin_symlinks_refresh.sh — pflegt ~/bin/*.sh + Symlink ohne Extension (relativ)
# Version: 0.6.2
# Changelog:
# - 0.6.1: "last.*" & "last.log" als echte Dateien (kein Symlink); DEBUG stark erweitert mit Schrittzähler & KV-Dumps
# - 0.6.0: ERR-Trap entfernt; Report immer
# - 0.5.1: nullglob-Loops; kein set -e
set -o pipefail  # bewusst kein -e

VERSION="0.6.2"
SCRIPT_NAME="_bin_symlinks_refresh"

usage(){ cat <<'EOF'
_bin_symlinks_refresh — pflegt Symlinks für alle ~/bin/*.sh
Usage:
  _bin_symlinks_refresh [--dry-run] [--dir <~/bin>] [--pattern <glob>]
                        [--remove-orphans] [--format md|txt|json]
                        [--out <file>] [--color auto|always|never]
                        [--debug|--no-debug] [--debug-level 1|2|3]
                        [--no-fail] [--write-last|--no-write-last] [--version]

Exit-Codes (Bitmaske): 0=OK, +1=Konflikte, +2=Orphans, +4=Operation-Errors
EOF
}

# ----- Defaults / Args -----
DRY_RUN=0
BIN_DIR="$HOME/bin"
PATTERN="*.sh"
REMOVE_ORPHANS=0
FORMAT="md"
OUTFILE=""
COLOR_MODE="auto"
NO_FAIL=0
WRITE_LAST=1
DEBUG=0
DEBUG_LEVEL=2   # 1=basic, 2=detail, 3=sehr detailiert

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --dir) BIN_DIR="${2:-}"; shift ;;
    --pattern) PATTERN="${2:-}"; shift ;;
    --remove-orphans) REMOVE_ORPHANS=1 ;;
    --format) FORMAT="${2:-}"; shift ;;
    --out) OUTFILE="${2:-}"; shift ;;
    --color) COLOR_MODE="${2:-auto}"; shift ;;
    --no-fail) NO_FAIL=1 ;;
    --write-last) WRITE_LAST=1 ;;
    --no-write-last) WRITE_LAST=0 ;;
    --debug) DEBUG=1 ;;
    --no-debug) DEBUG=0 ;;
    --debug-level) DEBUG_LEVEL="${2:-2}"; shift ;;
    --version) echo "$VERSION"; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2 ;;
  esac; shift
done

# ----- Colors -----
setup_colors(){ local use=0
  case "$COLOR_MODE" in always) use=1;; never) use=0;; auto) [[ -t 1 ]] && use=1 || use=0;; esac
  if [[ $use -eq 1 ]]; then BOLD=$'\e[1m'; DIM=$'\e[2m'; RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; BLUE=$'\e[34m'; RESET=$'\e[0m'
  else BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; RESET=""; fi
}; setup_colors

# ----- Paths / Logs (unter ~/bin/.wiki) -----
[[ -d "$BIN_DIR" ]] || { echo "${RED}[ERROR]${RESET} BIN_DIR nicht gefunden: $BIN_DIR" >&2; exit 2; }
RUN_ROOT="$BIN_DIR/.wiki/bin_symlinks"; mkdir -p "$RUN_ROOT"
find "$RUN_ROOT" -type f -mtime +30 -delete 2>/dev/null || true

ts(){ date +"%Y-%m-%d %H:%M:%S%z"; }
RUN_TS="$(date +%F_%H%M%S)"
RUN_LOG="$RUN_ROOT/_run_${RUN_TS}.log"

DBG_STEP=0
dbg(){ [[ $DEBUG -eq 1 ]] && { DBG_STEP=$((DBG_STEP+1)); printf "%s[DBG#%03d]%s %s\n" "$DIM" "$DBG_STEP" "$RESET" "$*" >&2; printf "[%s] DBG#%03d %s\n" "$(ts)" "$DBG_STEP" "$*" >> "$RUN_LOG"; }; }
info(){ printf "%s[INFO]%s %s\n" "$BOLD" "$RESET" "$*" >&2; printf "[%s] INFO %s\n" "$(ts)" "$*" >> "$RUN_LOG"; }
err(){  printf "%s[ERROR]%s %s\n" "$RED"  "$RESET" "$*" >&2; printf "[%s] ERROR %s\n" "$(ts)" "$*" >> "$RUN_LOG"; }

dbg "START ${SCRIPT_NAME} v${VERSION}"
dbg "args DRY_RUN=$DRY_RUN BIN_DIR=$BIN_DIR PATTERN='$PATTERN' REMOVE_ORPHANS=$REMOVE_ORPHANS FORMAT=$FORMAT OUT='${OUTFILE:-}' COLOR=$COLOR_MODE DEBUG=$DEBUG LEVEL=$DEBUG_LEVEL NO_FAIL=$NO_FAIL WRITE_LAST=$WRITE_LAST"

# ----- Data / Counters -----
declare -a CREATED UPDATED PERM_CHANGED SKIPPED CONFLICTS ORPHANS REMOVED ERRORS
count_created=0; count_updated=0; count_perm=0; count_skipped=0; count_conf=0; count_orph=0; count_removed=0; count_err=0

# ----- Safe Ops -----
safe_chmod(){ local mode="$1" path="$2"
  if [[ $DRY_RUN -eq 1 ]]; then dbg "chmod mode=$mode path='$path' (dry)"; return; fi
  if chmod "$mode" "$path"; then dbg "chmod OK mode=$mode path='$path'"; else ERRORS+=("chmod $mode $path"); ((count_err++)); err "chmod FAIL mode=$mode path='$path'"; fi
}
safe_ln(){ if [[ $DRY_RUN -eq 1 ]]; then dbg "ln $* (dry)"; return; fi
  if ln "$@"; then dbg "ln OK args='$*'"; else ERRORS+=("ln $*"); ((count_err++)); err "ln FAIL args='$*'"; fi
}
safe_rm(){ local t="$1"
  if [[ $DRY_RUN -eq 1 ]]; then dbg "rm -f '$t' (dry)"; return; fi
  if rm -f "$t"; then dbg "rm OK target='$t'"; else ERRORS+=("rm $t"); ((count_err++)); err "rm FAIL target='$t'"; fi
}

link_refresh(){ local base="$1" # ohne .sh
  ( cd "$BIN_DIR" || exit 0
    local target="${base}.sh"
    if [[ ! -f "$target" ]]; then [[ $DEBUG_LEVEL -ge 2 ]] && dbg "skip base='$base' reason=no_target"; exit 0; fi
    if [[ -L "$base" ]]; then
      local cur; cur="$(readlink "$base" || true)"
      if [[ "$cur" == "$target" ]]; then
        SKIPPED+=("$base -> $cur"); ((count_skipped++))
        [[ $DEBUG_LEVEL -ge 2 ]] && dbg "keep_link base='$base' cur='$cur'"
      else
        UPDATED+=("$base: $cur -> $target"); ((count_updated++))
        [[ $DEBUG_LEVEL -ge 2 ]] && dbg "update_link base='$base' from='$cur' to='$target'"
        safe_ln -sfn "$target" "$base"
      fi
    elif [[ -e "$base" ]]; then
      CONFLICTS+=("$base (existiert, kein Symlink)"); ((count_conf++))
      err "conflict base='$base' reason=file_blocks"
    else
      CREATED+=("$base -> $target"); ((count_created++))
      [[ $DEBUG_LEVEL -ge 2 ]] && dbg "create_link base='$base' to='$target'"
      safe_ln -s "$target" "$base"
    fi
  )
}

# ----- Iteration (nullglob) -----
shopt -s nullglob
dbg "scan files pattern='$PATTERN' dir='$BIN_DIR'"

for f in "$BIN_DIR"/$PATTERN; do
  [[ -f "$f" ]] || continue
  bn="$(basename "$f")"; base="${bn%.sh}"
  perm="$(stat -c '%a' "$f" 2>/dev/null || echo "")"
  [[ $DEBUG_LEVEL -ge 2 ]] && dbg "file bn='$bn' base='$base' perm='$perm' want='755'"
  if [[ "$perm" != "755" ]]; then
    PERM_CHANGED+=("$bn: $perm -> 755"); ((count_perm++))
    safe_chmod 755 "$f"
  fi
  link_refresh "$base"
done

dbg "scan orphans dir='$BIN_DIR'"
for lnk in "$BIN_DIR"/*; do
  [[ -L "$lnk" ]] || continue
  name="$(basename "$lnk")"; base="$name"
  if [[ -f "$BIN_DIR/${base}.sh" ]]; then
    [[ $DEBUG_LEVEL -ge 3 ]] && dbg "not_orphan link='$name' has_target='${base}.sh'"
    continue
  fi
  ORPHANS+=("$name (kein ${base}.sh)"); ((count_orph++))
  info "orphan link='$name'"
  [[ $REMOVE_ORPHANS -eq 1 ]] && { REMOVED+=("$name"); ((count_removed++)); safe_rm "$lnk"; }
done
shopt -u nullglob

# ----- Report -----
json_escape(){ sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
arr_to_json(){ local n="$1"; eval "local a=(\"\${${n}[@]-}\")"; local first=1; printf '['
  for it in "${a[@]}"; do [[ $first -eq 0 ]] && printf ','; first=0; printf '"%s"' "$(printf '%s' "$it" | json_escape)"; done; printf ']'; }

to_md(){ cat <<EOF
# ${SCRIPT_NAME} v${VERSION}
Zeit: $(ts)
BIN_DIR: $BIN_DIR
Dry-Run: $([[ $DRY_RUN -eq 1 ]] && echo "YES" || echo "NO")
Debug: $([[ $DEBUG -eq 1 ]] && echo "YES" || echo "NO") (level=${DEBUG_LEVEL})

| Kategorie | Anzahl |
|---|---:|
| Neu erstellt | $count_created |
| Aktualisiert | $count_updated |
| Rechte geändert (->755) | $count_perm |
| Übersprungen | $count_skipped |
| Konflikte (Datei blockiert) | $count_conf |
| Orphans gefunden | $count_orph |
| Orphans entfernt | $count_removed |
| Operation-Errors | $count_err |
EOF
[[ ${#CONFLICTS[@]:-0} -gt 0 ]] && { echo -e "\n## Konflikte"; printf '%s\n' "${CONFLICTS[@]}" | sed 's/^/- /'; }
[[ ${#ORPHANS[@]:-0} -gt 0 ]] && { echo -e "\n## Orphans"; printf '%s\n' "${ORPHANS[@]}" | sed 's/^/- /'; }
[[ ${#CREATED[@]:-0} -gt 0 ]] && { echo -e "\n## Neu erstellt"; printf '%s\n' "${CREATED[@]}" | sed 's/^/- /'; }
[[ ${#UPDATED[@]:-0} -gt 0 ]] && { echo -e "\n## Aktualisiert"; printf '%s\n' "${UPDATED[@]}" | sed 's/^/- /'; }
[[ ${#PERM_CHANGED[@]:-0} -gt 0 ]] && { echo -e "\n## Rechte geändert"; printf '%s\n' "${PERM_CHANGED[@]}" | sed 's/^/- /'; }
[[ ${#REMOVED[@]:-0} -gt 0 ]] && { echo -e "\n## Entfernt"; printf '%s\n' "${REMOVED[@]}" | sed 's/^/- /'; }
[[ ${#ERRORS[@]:-0} -gt 0 ]] && { echo -e "\n## Operation-Errors"; printf '%s\n' "${ERRORS[@]}" | sed 's/^/- /'; }
}
to_txt(){ echo "script=$SCRIPT_NAME version=$VERSION time=$(ts) bin=$BIN_DIR dry_run=$DRY_RUN debug=$DEBUG level=$DEBUG_LEVEL"
  printf "created=%d updated=%d perm_changed=%d skipped=%d conflicts=%d orphans=%d removed=%d errors=%d\n" \
    "$count_created" "$count_updated" "$count_perm" "$count_skipped" "$count_conf" "$count_orph" "$count_removed" "$count_err"
  printf 'CONFLICTS: %s\n' "${CONFLICTS[*]:-}"
  printf 'ORPHANS:   %s\n' "${ORPHANS[*]:-}"
  printf 'CREATED:   %s\n' "${CREATED[*]:-}"
  printf 'UPDATED:   %s\n' "${UPDATED[*]:-}"
  printf 'PERMCHG:   %s\n' "${PERM_CHANGED[*]:-}"
  printf 'REMOVED:   %s\n' "${REMOVED[*]:-}"
  printf 'ERRORS:    %s\n' "${ERRORS[*]:-}"
}
to_json(){ printf '{'
  printf '"script":"%s","version":"%s","time":"%s","bin":"%s","dry_run":%s,"debug":%s,"debug_level":%s,' \
    "$SCRIPT_NAME" "$VERSION" "$(ts)" "$BIN_DIR" $([[ $DRY_RUN -eq 1 ]] && echo true || echo false) $([[ $DEBUG -eq 1 ]] && echo true || echo false) "$DEBUG_LEVEL"
  printf '"counts":{"created":%d,"updated":%d,"perm_changed":%d,"skipped":%d,"conflicts":%d,"orphans":%d,"removed":%d,"errors":%d},' \
    "$count_created" "$count_updated" "$count_perm" "$count_skipped" "$count_conf" "$count_orph" "$count_removed" "$count_err"
  printf '"lists":{"conflicts":'; arr_to_json CONFLICTS
  printf ',"orphans":'; arr_to_json ORPHANS
  printf ',"created":'; arr_to_json CREATED
  printf ',"updated":'; arr_to_json UPDATED
  printf ',"perm_changed":'; arr_to_json PERM_CHANGED
  printf ',"removed":'; arr_to_json REMOVED
  printf ',"errors":'; arr_to_json ERRORS
  printf '}}'; }

# ----- Console Header -----
echo -e "${BOLD}${BLUE}${SCRIPT_NAME}${RESET} v${VERSION}  bin=${BOLD}${BIN_DIR}${RESET}  dry-run=${BOLD}$([[ $DRY_RUN -eq 1 ]] && echo YES || echo NO)${RESET}  debug=${BOLD}$([[ $DEBUG -eq 1 ]] && echo YES || echo NO)${RESET}(lvl=${DEBUG_LEVEL})"
printf "%sHinweis:%s Reports & Logs -> %s\n" "$DIM" "$RESET" "$RUN_ROOT" >&2

# ----- Build & Write Report (IMMER) -----
case "$FORMAT" in
  md) CONTENT="$(to_md)";; txt) CONTENT="$(to_txt)";; json) CONTENT="$(to_json)";; *) err "bad --format"; CONTENT="";;
esac

STAMP_PATH="$RUN_ROOT/${RUN_TS}_bin_symlinks.${FORMAT}"
printf "%s\n" "$CONTENT" > "$STAMP_PATH"; info "Report: $STAMP_PATH"

# last.* & last.log als echte Dateien (kein Symlink)
if [[ $WRITE_LAST -eq 1 ]]; then
  cp -f "$STAMP_PATH" "$RUN_ROOT/last.${FORMAT}"
  cp -f "$RUN_LOG"   "$RUN_ROOT/last.log"
  info "last files aktualisiert: last.${FORMAT}, last.log"
fi

# optional zusätzlich OUTFILE schreiben
[[ -n "$OUTFILE" ]] && { printf "%s\n" "$CONTENT" > "$OUTFILE"; info "Report (out): $OUTFILE"; }

# ----- Exit codes -----
EXIT=0
(( count_conf > 0 )) && EXIT=$((EXIT | 1))
(( count_orph > 0 )) && EXIT=$((EXIT | 2))
(( count_err  > 0 )) && EXIT=$((EXIT | 4))
[[ $NO_FAIL -eq 1 ]] && EXIT=0
dbg "EXIT=$EXIT"
exit $EXIT
