#!/usr/bin/env bash
# _backups_migrate_layout.sh — Reorganize ~/bin/backups/* nach Schema
# v0.3.0  (neu: Reports via _reports_core → ~/bin/reports/backups_migrate_layout/)
set -euo pipefail
IFS=$'\n\t'; LC_ALL=C; LANG=C

SCRIPT_VERSION="v0.3.0"

APPLY=0; REPACK=0; VERBOSE=0; QUIET=0; DEBUG=0
ROOT="${HOME}/bin/backups"

for a in "$@"; do
  case "$a" in
    --apply) APPLY=1;;
    --repack) REPACK=1;;
    --root=*) ROOT="${a#*=}";;
    --verbose) VERBOSE=1;;
    --quiet) QUIET=1; VERBOSE=0;;
    --debug) DEBUG=1;;
    --help|-h) echo "Usage: backups_migrate_layout [--apply] [--repack] [--verbose|--quiet] [--debug] [--root=<path>]"; exit 0;;
    *) echo "Unknown arg: $a"; exit 64;;
  esac
done

BIN_DIR="${HOME}/bin"
DBG_DIR="${HOME}/bin/debug/backups_migrate_layout"; mkdir -p "$DBG_DIR" "$ROOT"
TRACE_FILE="${DBG_DIR}/trace_$(date +%Y%m%d_%H%M%S).txt"
if (( DEBUG )); then set -x; exec 9> "$TRACE_FILE"; BASH_XTRACEFD=9; fi

declare -a ACTIONS; ERROR_MSG=""
sp(){ local p="${1:-}"; [[ -z "$p" ]] && { printf '%s' ""; return; }; case "$p" in "$HOME"*) printf '~%s' "${p#"$HOME"}";; *) printf '%s' "$p";; esac; }
rel_root(){ local p="${1:-}"; [[ -z "$p" ]] && { printf '%s' ""; return; }; [[ "$p" == "$ROOT/"* ]] && printf '%s' "${p#"$ROOT/"}" || printf '%s' "$(sp "$p")"; }
log(){ [[ "$VERBOSE" -eq 1 ]] && printf '%s\n' "$*"; }
add_action(){ local a="$1" f="$2" t="$3" n="$4"; ACTIONS+=("$a"$'\t'"$f"$'\t'"$t"$'\t'"$n") || true; [[ "$VERBOSE" -eq 1 ]] && printf '• %s | %s → %s (%s)\n' "$a" "$(sp "$f")" "$(sp "$t")" "$n"; }
doit(){ if (( APPLY )); then eval "$*"; else :; fi; }   # Dry-Run → RC 0
normalize_id(){ local n="$1"; n="${n%.sh}"; while [[ "$n" == _* || "$n" == .* ]]; do n="${n#_}"; n="${n#.}"; done; printf '%s' "$n"; }
trim(){ local s="$1"; s="${s#"${s%%[!$' \t\r\n']*}"}"; s="${s%"${s##*[!$' \t\r\n']}" }"; printf '%s' "$s"; }

# ID→Kategorie (aus realen Skripten)
declare -A ID_CAT
while IFS= read -r -d '' fp; do
  base="$(basename -- "$fp")"; id="$(normalize_id "$base")"
  rel="${fp#$BIN_DIR/}"; catpath="$(dirname -- "$rel")"
  ID_CAT["$id"]="$catpath"
done < <(find "$BIN_DIR"/shellscripts/{install,scans,reports,ops,maintenance} -type f -name '*.sh' -print0 2>/dev/null || true)
ID_CAT["shellscripts_checklist"]="${ID_CAT["shellscripts_checklist"]:-shellscripts/maintenance/internal}"
ID_CAT["shellscripts_checklist_summary"]="${ID_CAT["shellscripts_checklist_summary"]:-shellscripts/maintenance/internal}"

# Legacy-Map
declare -A LEGACY=(
  [".checklist_shellscripts"]="shellscripts_checklist"
  [".checklist_shellscripts_summary"]="shellscripts_checklist_summary"
)

mkdir -p "$ROOT" "$ROOT/uncategorized"

# 1) Legacy-Ordner → Ziel
for old in "${!LEGACY[@]}"; do
  src="${ROOT}/${old}"; [[ -d "$src" ]] || continue
  id="${LEGACY[$old]}"; catpath="${ID_CAT[$id]:-shellscripts/maintenance/internal}"
  dst="${ROOT}/${catpath}/${id}"
  add_action "legacy_move" "$src" "$dst" "map:${old}→${id}"
  doit "mkdir -p \"$dst\""
  if (( REPACK )); then
    while IFS= read -r -d '' f; do
      # minimal repack (Version/TS heuristisch)
      base="$(basename -- "$f")"
      if [[ "$base" =~ \.v([0-9][0-9\.]*[0-9]([A-Za-z0-9._-]*)?)\.bak\.([0-9]{8}_[0-9]{6})$ ]]; then
        ver="v${BASH_REMATCH[1]}"; ts="${BASH_REMATCH[3]}"
      elif [[ "$base" =~ \.bak\.([0-9]{8}_[0-9]{6})$ ]]; then
        ver="v0.0.0-unknown"; ts="${BASH_REMATCH[1]}"
      else
        ver="v0.0.0-unknown"; ts="$(date -d @$(stat -c %Y "$f" 2>/dev/null || date +%s) +%Y%m%d_%H%M%S)"
      fi
      snap="${ROOT}/${catpath}/${id}/${ts}Z_${ver}"
      doit "mkdir -p \"$snap\""
      doit "cp -a \"$f\" \"$snap/$(basename -- "$f")\""
      doit "ln -sfn \"$(basename -- "$snap")\" \"${ROOT}/${catpath}/${id}/latest\""
    done < <(find "$src" -maxdepth 1 -type f -print0 2>/dev/null || true)
    while IFS= read -r -d '' d; do
      add_action "move_dir" "$d" "$ROOT/uncategorized/" "leftover"
      doit "mv -f \"$d\" \"$ROOT/uncategorized/\""
    done < <(find "$src" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null || true)
    doit "rmdir \"$src\" || true"
  else
    add_action "move_content" "$src/*" "$dst/" "no-repack"
    doit "bash -lc 'shopt -s dotglob nullglob; mkdir -p \"$dst\"; mv -f \"$src\"/* \"$dst\"/ 2>/dev/null || true'"
    doit "rmdir \"$src\" || true"
  fi
done

# 2) Top-Level-Fremdgut → uncategorized
valid_top="^(install|scans|reports|ops|maintenance|uncategorized)(/)?$"
while IFS= read -r -d '' item; do
  name="$(basename -- "$item")"
  [[ "$name" =~ $valid_top ]] && continue
  add_action "move_misc" "$item" "$ROOT/uncategorized/" "-"
  doit "mv -f \"$item\" \"$ROOT/uncategorized/\""
done < <(find "$ROOT" -mindepth 1 -maxdepth 1 -print0 2>/dev/null || true)

# ── Reports via _reports_core ───────────────────────────────────────────────
source "$HOME/bin/shellscripts/maintenance/internal/_reports_core.sh"
reports_init "backups_migrate_layout" "${HOME}/bin/reports" 5

stamp="$(date +%Y-%m-%d\ %H:%M:%S\ %Z)"
mode=$([[ $APPLY -eq 1 ]] && echo "APPLY" || echo "DRY")

# Markdown
{
  echo "# backups_migrate_layout Report"
  echo
  echo "- Zeitpunkt: ${stamp}"
  echo "- Modus: ${mode}"
  echo "- Root: \`$(sp "$ROOT")\`"
  echo
  echo "| Action | From \`~/bin/backups/\` | To \`~/bin/backups/\` | Note |"
  echo "|---|---|---|---|"
  if ((${#ACTIONS[@]})); then
    for row in "${ACTIONS[@]}"; do
      row="${row//\\t/$'\t'}"
      IFS=$'\t' read -r a f t n <<< "$row" || { a="$row"; f=""; t=""; n=""; }
      md_note="$n"
      if [[ "$a" == "legacy_move" && "$n" == map:*"→"* ]]; then
        tmp="${n#map:}"; old="${tmp%%→*}"; new="${tmp#*→}"
        md_note="**map-old:**&nbsp;\`$old\`&nbsp;→<br />**map-new:**&nbsp;\`$new\`"
      fi
      printf '| %s | `%s` | `%s` | %s |\n' "$a" "$(rel_root "$f")" "$(rel_root "$t")" "$md_note"
    done
  else
    echo "| (no changes) |  |  |  |"
  fi
} > /tmp/.bml.md

# JSON
{
  printf '{\n'
  printf '  "timestamp": "%s",\n' "$stamp"
  printf '  "mode": "%s",\n' "$mode"
  printf '  "root": "%s",\n' "$(sp "$ROOT")"
  printf '  "actions": [\n'
  if ((${#ACTIONS[@]})); then
    local i=0
    for row in "${ACTIONS[@]}"; do
      row="${row//\\t/$'\t'}"
      IFS=$'\t' read -r a f t n <<< "$row" || { a="$row"; f=""; t=""; n=""; }
      printf '    {"action":"%s","from":"%s","from_rel":"%s","to":"%s","to_rel":"%s","note":"%s"}' \
        "$a" "$(sp "$f")" "$(rel_root "$f")" "$(sp "$t")" "$(rel_root "$t")" "$n"
      (( i < ${#ACTIONS[@]}-1 )) && printf ','
      printf '\n'; ((i++))
    done
  fi
  printf '  ]\n}\n'
} > /tmp/.bml.json

reports_write_md   "$(cat /tmp/.bml.md)"
reports_write_json "$(cat /tmp/.bml.json)"
reports_rotate
reports_paths_echo
(( DEBUG )) && echo "📝 Trace: $(sp "$TRACE_FILE")"
