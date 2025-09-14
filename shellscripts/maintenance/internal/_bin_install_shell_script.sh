#!/usr/bin/env bash
# _bin_install_shell_script.sh – installiert/aktualisiert ein Shell-Skript nach ~/bin mit Log + Backup
# Version: 0.1.0
# Nutzung:
#   _bin_install_shell_script.sh --source /pfad/neu.sh --target ~/bin/datei.sh [--no-backup] [--mode 0755] [--dry-run]

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_NAME="$(basename "$0")"
SCRIPT_VERSION="0.1.0"
run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
ORIG_CWD="$(pwd)"

# Parts
source "${HOME}/bin/parts/log_core.part" || { echo "[ERROR] log_core.part fehlt"; exit 2; }
source "${HOME}/bin/parts/install_update.part" || { echo "[ERROR] install_update.part fehlt"; exit 2; }

# Args
ORIG_ARGS=("$@"); lc_set_opts "$@"
SRC="" ; DST="" ; DO_BACKUP=1 ; DRY_RUN=0 ; MODE="0755"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) echo "$SCRIPT_VERSION"; exit 0 ;;
    --source) SRC="${2:-}"; shift 2 || { echo "[ERROR] --source benötigt Pfad" >&2; exit 2; } ;;
    --target) DST="${2:-}"; shift 2 || { echo "[ERROR] --target benötigt Pfad (in ~/bin)" >&2; exit 2; } ;;
    --no-backup) DO_BACKUP=0; shift ;;
    --mode) MODE="${2:-0755}"; shift 2 || { echo "[ERROR] --mode benötigt z. B. 0755" >&2; exit 2; } ;;
    --dry-run) DRY_RUN=1; shift ;;
    --) shift; break ;;
    *) echo "[ERROR] Unbekannte Option: $1" >&2; exit 2 ;;
  esac
done

# Kontexte
PROJECT_ROOT=""; if root="$(lc_find_project_root "$ORIG_CWD")"; then PROJECT_ROOT="$root"; fi
CTX_NAMES=()
if [[ -n "$PROJECT_ROOT" ]]; then lc_init_ctx "PRIMARY" "$PROJECT_ROOT" "$run_id" "$SCRIPT_NAME" "$SCRIPT_VERSION" "$ORIG_CWD" "install-shell-script" && CTX_NAMES+=( "PRIMARY" ); fi
lc_init_ctx "BIN" "${HOME}/bin" "$run_id" "$SCRIPT_NAME" "$SCRIPT_VERSION" "$ORIG_CWD" "install-shell-script" && CTX_NAMES+=( "BIN" )
((${#CTX_NAMES[@]})) || { echo "[ERROR] Kein Log-Kontext"; exit 2; }

# Plausis
[[ -n "$SRC" && -f "$SRC" ]] || { lc_log_event_all ERROR "install" "precheck" "args" "error" 0 2 "Quelle&nbsp;fehlt/ungültig" "install" "SRC:&nbsp;$SRC"; lc_finalize; exit 2; }
[[ -n "$DST" ]] || { lc_log_event_all ERROR "install" "precheck" "args" "error" 0 2 "Ziel&nbsp;fehlt" "install" ""; lc_finalize; exit 2; }
case "$DST" in "$HOME/bin/"* ) : ;; * ) lc_log_event_all ERROR "install" "precheck" "args" "error" 0 2 "Ziel&nbsp;muss&nbsp;unter&nbsp;~/bin&nbsp;liegen" "install" "DST:&nbsp;$DST"; lc_finalize; exit 2 ;; esac
mkdir -p "${HOME}/bin/backups" || true

# Version/Größe
extract_ver(){ local f="$1" v=""
  v="$(grep -E '^(SCRIPT_VERSION="[^"]+"|VERSION="[^"]+"|# Version:[[:space:]]*[0-9]+\.[0-9]+\.[0-9]+)' "$f" 2>/dev/null | head -n1 || true)"
  v="${v#SCRIPT_VERSION=\"}"; v="${v#VERSION=\"}"; v="${v%\"}"; v="${v#\# Version: }"
  printf "%s" "$v"
}
OLD_EXISTS=0; [[ -f "$DST" ]] && OLD_EXISTS=1
OLD_VER=""; NEW_VER=""; OLD_BYTES=0; NEW_BYTES=0
[[ $OLD_EXISTS -eq 1 ]] && OLD_VER="$(extract_ver "$DST")" || true
NEW_VER="$(extract_ver "$SRC")" || true
[[ $OLD_EXISTS -eq 1 ]] && OLD_BYTES="$(stat -c%s "$DST" 2>/dev/null || echo 0)" || true
NEW_BYTES_SRC="$(stat -c%s "$SRC" 2>/dev/null || echo 0)"

# Dry-run
if [[ $DRY_RUN -eq 1 ]]; then
  local_reason="install-new"; [[ $OLD_EXISTS -eq 1 ]] && local_reason="install-update"
  note="Prüfung:&nbsp;würde&nbsp;installieren"
  msg="SRC:&nbsp;$SRC; DST:&nbsp;$DST; Backup:&nbsp;$([[ $DO_BACKUP -eq 1 ]] && echo an || echo aus); Bytes(alt→neu):&nbsp;${OLD_BYTES}&nbsp;→&nbsp;${NEW_BYTES_SRC}; Version:&nbsp;${OLD_VER:-?}&nbsp;→&nbsp;${NEW_VER:-?}"
  lc_log_event_all INFO "install" "plan" "$local_reason" "ok" 0 0 "$note" "install,dry-run" "$msg"
  lc_finalize; echo "DRY-RUN: ${SRC} -> ${DST}"; exit 0
fi

# Backup
if [[ $OLD_EXISTS -eq 1 && $DO_BACKUP -eq 1 ]]; then
  ts_bak="$(date -u +%Y%m%dT%H%M%SZ)"; BAK="${HOME}/bin/backups/$(basename "$DST").bak-${ts_bak}"
  if cp -p -- "$DST" "$BAK"; then
    lc_log_event_all INFO "install" "backup" "install-update" "ok" 0 0 "Backup:&nbsp;erstellt" "install,backup" "Ziel→Backup:&nbsp;$BAK"
  else
    lc_log_event_all WARN "install" "backup" "install-update" "warn" 0 0 "Backup:&nbsp;fehlt" "install,backup" "cp&nbsp;fehlgeschlagen"
  fi
fi

# Kopieren
start_ns="$(date +%s%N 2>/dev/null || echo 0)"
if cp -p -- "$SRC" "$DST" && chmod "$MODE" "$DST"; then
  dur=0; [[ "$start_ns" != 0 ]] && dur=$(( ( $(date +%s%N) - start_ns ) / 1000000 ))
  NEW_BYTES="$(stat -c%s "$DST" 2>/dev/null || echo 0)"
  reason="install-new"; [[ $OLD_EXISTS -eq 1 ]] && reason="install-update"
  iu_log_version_bump "${OLD_VER}" "${NEW_VER}" "${DST}" "${OLD_BYTES}" "${NEW_BYTES}" "${dur}" "${reason}"
  lc_finalize; echo "OK: ${SRC} -> ${DST} (${MODE})"; exit 0
else
  lc_log_event_all ERROR "install" "apply" "io" "error" 0 1 "Fehler:&nbsp;Kopieren/Modus" "install" "SRC:&nbsp;$SRC; DST:&nbsp;$DST"
  lc_finalize; echo "[ERROR] Install fehlgeschlagen" >&2; exit 1
fi
