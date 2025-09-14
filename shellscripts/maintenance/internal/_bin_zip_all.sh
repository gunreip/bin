#!/usr/bin/env bash
# _bin_zip_all.sh – Zippt Shell-Skripte aus ~/bin (optional nach Kategorie) und loggt
# Version: 0.5.0

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_NAME="$(basename "$0")"
SCRIPT_VERSION="0.5.0"
run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
ORIG_CWD="$(pwd)"

# Parts
source "${HOME}/bin/parts/log_core.part" || { echo "[ERROR] log_core.part fehlt"; exit 2; }
source "${HOME}/bin/parts/install_update.part" || { echo "[ERROR] install_update.part fehlt"; exit 2; }

# ---- Args ----
ORIG_ARGS=("$@"); lc_set_opts "$@"
DRY_RUN=0; CATEGORY=""; BUMP_KIND=""; WIPE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) echo "$SCRIPT_VERSION"; exit 0 ;;
    --bump-patch) BUMP_KIND="patch"; shift ;;
    --bump-minor) BUMP_KIND="minor"; shift ;;
    --bump-major) BUMP_KIND="major"; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --wipe-today) WIPE=1; shift ;; # nur dev
    --category) CATEGORY="${2:-}"; shift 2 || { echo "[ERROR] --category braucht Wert" >&2; exit 2; } ;;
    --) shift; break ;;
    *) break ;;
  esac
done

# ---- Projekt/Log-Kontexte ----
PROJECT_ROOT=""; if root="$(lc_find_project_root "$ORIG_CWD")"; then PROJECT_ROOT="$root"; fi
CTX_NAMES=()
RUN_REASON="zip-all"; [[ -n "$BUMP_KIND" ]] && RUN_REASON="version-bump:${BUMP_KIND}"

# PRIMARY (Projekt) + BIN
if [[ -n "$PROJECT_ROOT" ]]; then lc_init_ctx "PRIMARY" "$PROJECT_ROOT" "$run_id" "$SCRIPT_NAME" "$SCRIPT_VERSION" "$ORIG_CWD" "$RUN_REASON" && CTX_NAMES+=( "PRIMARY" ); fi
lc_init_ctx "BIN" "${HOME}/bin" "$run_id" "$SCRIPT_NAME" "$SCRIPT_VERSION" "$ORIG_CWD" "$RUN_REASON" && CTX_NAMES+=( "BIN" )
((${#CTX_NAMES[@]})) || { echo "[ERROR] Kein Log-Kontext"; exit 2; }

# ---- Bump-Helper ----
bump(){ local kind="$1" M m p; IFS=. read -r M m p <<<"$SCRIPT_VERSION"
  case "$kind" in patch) p=$((p+1));; minor) m=$((m+1)); p=0;; major) M=$((M+1)); m=0; p=0;; esac
  local new="${M}.${m}.${p}"
  sed -E -i "s/^(SCRIPT_VERSION=\")([0-9]+\.[0-9]+\.[0-9]+)(\")/\1${new}\3/" "$0"
  sed -E -i "s/^(# Version:\s*)([0-9]+\.[0-9]+\.[0-9]+)/\1${new}/" "$0"
  SCRIPT_VERSION="$new"; echo "$SCRIPT_VERSION"
}

# ---- Version-Bump Modus ----
if [[ -n "$BUMP_KIND" ]]; then
  OLD_VERSION="$SCRIPT_VERSION"
  FILE_SELF="${HOME}/bin/_bin_zip_all.sh"
  OLD_BYTES="$(stat -c%s "$FILE_SELF" 2>/dev/null || echo 0)"
  start_ns="$(date +%s%N 2>/dev/null || echo 0)"
  if NEW_VERSION="$(bump "$BUMP_KIND")"; then
    SCRIPT_VERSION="$NEW_VERSION"
    NEW_BYTES="$(stat -c%s "$FILE_SELF" 2>/dev/null || echo 0)"
    dur=0; [[ "$start_ns" != 0 ]] && dur=$(( ( $(date +%s%N) - start_ns ) / 1000000 ))
    iu_log_version_bump "$OLD_VERSION" "$NEW_VERSION" "$FILE_SELF" "$OLD_BYTES" "$NEW_BYTES" "$dur" "version-bump:${BUMP_KIND}"
    lc_finalize; echo "$NEW_VERSION"; exit 0
  else
    lc_log_event_all ERROR "install" "update" "version-bump:${BUMP_KIND}" "error" 0 1 "Fehler:&nbsp;Version&nbsp;unverändert" "bin,install,update,version" "Self-edit fehlgeschlagen"
    lc_finalize; exit 1
  fi
fi

# ---- Zip-Logik ----
command -v zip >/dev/null 2>&1 || { lc_log_event_all ERROR "zip" "precheck" "missing-cmd" "error" 0 127 "" "bin,zip" "zip nicht gefunden"; lc_finalize; exit 127; }

mapfile -d '' FILES < <(find "${HOME}/bin" -maxdepth 1 -type f -name '*.sh' -print0)
TOTAL="${#FILES[@]}"

TAGS="bin,zip"
OUT_BASENAME="bin_shellcommands.zip"
if [[ -n "$CATEGORY" ]]; then TAGS="${TAGS},category:${CATEGORY}"; OUT_BASENAME="bin_shellcommands.${CATEGORY}.zip"; fi
OUT_ZIP="${HOME}/bin/${OUT_BASENAME}"

FILTERED=()
if [[ -n "$CATEGORY" ]]; then
  for f in "${FILES[@]}"; do base="$(basename "$f")"; [[ "$base" =~ ^${CATEGORY}[-_].*\.sh$ ]] && FILTERED+=("$f"); done
else
  FILTERED=("${FILES[@]}")
fi

COUNT="${#FILTERED[@]}"
lc_log_event_all INFO "scan" "list" "collect" "ok" 0 0 "Kandidaten:&nbsp;${COUNT}/${TOTAL}" "$TAGS" ""

if (( COUNT == 0 )); then
  lc_log_event_all WARN "zip" "create" "no-files" "warn" 0 0 "Warn:&nbsp;0 Dateien für Kategorie&nbsp;${CATEGORY:-alle}" "$TAGS" ""
  lc_finalize; exit 0
fi

start_ns="$(date +%s%N 2>/dev/null || echo 0)"
if [[ $DRY_RUN -eq 1 ]]; then
  lc_log_event_all INFO "zip" "create" "dry-run" "ok" 0 0 "OK:&nbsp;${COUNT} Dateien → ${OUT_BASENAME}" "$TAGS,dry-run" "ZIP:&nbsp;${OUT_BASENAME}"
  lc_finalize; exit 0
fi

rm -f "$OUT_ZIP" || true
if zip -q -9 -j "$OUT_ZIP" "${FILTERED[@]}"; then
  dur=0; [[ "$start_ns" != 0 ]] && dur=$(( ( $(date +%s%N) - start_ns ) / 1000000 ))
  ZIP_HSIZE="$(du -h "$OUT_ZIP" 2>/dev/null | awk '{print $1}')"
  lc_log_event_all INFO "zip" "create" "apply" "ok" "$dur" 0 "OK:&nbsp;${COUNT} Dateien → ${OUT_BASENAME}" "$TAGS" "ZIP:&nbsp;${OUT_BASENAME}; Größe:&nbsp;${ZIP_HSIZE}"
else
  lc_log_event_all ERROR "zip" "create" "io" "error" 0 2 "Fehler:&nbsp;zip" "$TAGS" "zip fehlgeschlagen"
  lc_finalize; exit 2
fi

lc_log_event_all INFO "finish" "summary" "report" "ok" 5 0 "Fertig:&nbsp;${COUNT} Dateien" "summary" ""
lc_finalize
echo "OK: ${COUNT} Dateien -> ${OUT_ZIP}"
