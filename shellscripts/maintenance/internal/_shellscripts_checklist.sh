#!/usr/bin/env bash
# _shellscripts_checklist.sh — Liste aller Shellskripte + Symlink-Status
# v0.6.0  (neu: Reports via _reports_core → ~/bin/reports/shellscripts_checklist/)
set -euo pipefail
IFS=$'\n\t'; LC_ALL=C; LANG=C

SCRIPT_VERSION="v0.6.0"

BIN_DIR="${HOME}/bin"
ROOT_SHELL="${BIN_DIR}/shellscripts"
TOP="$BIN_DIR"   # Symlink-Ebene

sp(){ local p="${1:-}"; [[ -z "$p" ]] && { printf '%s' ""; return; }; case "$p" in "$HOME"*) printf '~%s' "${p#"$HOME"}";; *) printf '%s' "$p";; esac; }
normalize_id(){ local n="$1"; n="${n%.sh}"; while [[ "$n" == _* || "$n" == .* ]]; do n="${n#_}"; n="${n#.}"; done; printf '%s' "$n"; }

declare -A FILES_BY_ID
declare -A VERSION_BY_PATH
declare -A STATE_BY_PATH

# 1) Alle Skripte einsammeln + Version/State
while IFS= read -r -d '' f; do
  base="$(basename -- "$f")"
  id="$(normalize_id "$base")"
  FILES_BY_ID["$id"]+="$f"$'\n'
  # Version (first match of SCRIPT_VERSION="vX.Y.Z")
  v="$(grep -Eo 'SCRIPT_VERSION="v[^"]+"' "$f" 2>/dev/null | head -n1 | sed -E 's/.*"(v[^"]+)".*/\1/')" || true
  VERSION_BY_PATH["$f"]="${v:-n/a}"
  # State (SCRIPT_STATE=1|0), default 0
  s="$(grep -Eo '^SCRIPT_STATE=[01]' "$f" 2>/dev/null | head -n1 | cut -d= -f2)" || true
  [[ -z "$s" ]] && s=0
  STATE_BY_PATH["$f"]="$s"
done < <(find "$ROOT_SHELL" -type f -name '*.sh' -print0 2>/dev/null)

# 2) Symlink-Mapping (Top-Level)
declare -A LINK_TARGET_BY_NAME
while IFS= read -r -d '' L; do
  name="$(basename -- "$L")"
  tgt="$(readlink -f -- "$L" 2>/dev/null || true)"
  LINK_TARGET_BY_NAME["$name"]="$tgt"
done < <(find "$TOP" -maxdepth 1 -mindepth 1 -type l -print0 2>/dev/null)

# 3) Tabelle bauen (sortiert nach Script-Name)
build_md(){
  echo "# shellscripts_checklist"
  echo
  echo "| Script-Name | Script-Path | Version | state | Symlink in \`~/bin/\` | guilty |"
  echo "|---|---|---|---|---|---|"
  for id in $(printf '%s\n' "${!FILES_BY_ID[@]}" | LC_ALL=C sort); do
    paths="${FILES_BY_ID[$id]}"
    IFS=$'\n' read -r -d '' -a arr <<<"$(printf '%s\0' $paths)"
    # Script-Name = id + ".sh" (repräsentativ)
    script_name="${id}.sh"
    # Script-Path = alle Pfade mit <br />
    path_cells=""
    ver_display="n/a"
    state_display="0"
    for p in "${arr[@]}"; do
      [[ -z "$p" ]] && continue
      path_cells+="$(sp "$p")<br />"
      [[ "${VERSION_BY_PATH[$p]:-}" != "" ]] && ver_display="${VERSION_BY_PATH[$p]}"
      [[ "${STATE_BY_PATH[$p]:-}" != "" ]] && state_display="${STATE_BY_PATH[$p]}"
    done
    path_cells="${path_cells%<br />}"
    # Symlink-Name = id ohne .sh
    link_name="$id"
    link_target="${LINK_TARGET_BY_NAME[$link_name]:-}"
    # guilty: ✅ ok, ⚠️ warning (zeigt woanders hin), ❌ fehlt
    if [[ -n "$link_target" ]]; then
      # ok wenn eines der Pfade der Target ist
      guilty="⚠️"
      for p in "${arr[@]}"; do
        [[ -z "$p" ]] && continue
        if [[ "$link_target" == "$(readlink -f -- "$p")" ]]; then
          guilty="✅"; break
        fi
      done
    else
      guilty="❌"
    fi
    printf '| `%s` | %s | %s | %s | `%s` | %s |\n' "$script_name" "$path_cells" "$ver_display" "$state_display" "$link_name" "$guilty"
  done
}

build_json(){
  printf '{\n  "items": [\n'
  local first=1
  for id in $(printf '%s\n' "${!FILES_BY_ID[@]}" | LC_ALL=C sort); do
    paths="${FILES_BY_ID[$id]}"
    IFS=$'\n' read -r -d '' -a arr <<<"$(printf '%s\0' $paths)"
    link_name="$id"
    link_target="${LINK_TARGET_BY_NAME[$link_name]:-}"
    ver_display="n/a"; state_display="0"
    for p in "${arr[@]}"; do
      [[ -z "$p" ]] && continue
      [[ "${VERSION_BY_PATH[$p]:-}" != "" ]] && ver_display="${VERSION_BY_PATH[$p]}"
      [[ "${STATE_BY_PATH[$p]:-}" != "" ]] && state_display="${STATE_BY_PATH[$p]}"
    done
    guilty="missing"
    if [[ -n "$link_target" ]]; then
      guilty="warning"
      for p in "${arr[@]}"; do
        [[ -z "$p" ]] && continue
        if [[ "$link_target" == "$(readlink -f -- "$p")" ]]; then
          guilty="ok"; break
        fi
      done
    fi
    # JSON-Objekt schreiben
    [[ $first -eq 0 ]] && printf ',\n'; first=0
    printf '    {"id":"%s","script_name":"%s","paths":[' "$id" "${id}.sh"
    for i in "${!arr[@]}"; do
      p="${arr[$i]}"; [[ -z "$p" ]] && continue
      printf '%s' "\"$(sp "$p")\""
      [[ $i -lt $((${#arr[@]}-1)) ]] && printf ','
    done
    printf '],"version":"%s","state":%s,"symlink":"%s","guilty":"%s"}' "$ver_display" "$state_display" "$link_name" "$guilty"
  done
  printf '\n  ]\n}\n'
}

# ── Reports via _reports_core ───────────────────────────────────────────────
source "$HOME/bin/shellscripts/maintenance/internal/_reports_core.sh"
reports_init "shellscripts_checklist" "${HOME}/bin/reports" 5
reports_write_md   "$(build_md)"
reports_write_json "$(build_json)"
reports_rotate
reports_paths_echo

exit 0
