#!/usr/bin/env bash
# backup_publish_latest.sh — spiegelt neueste DB-Dumps / Spatie-ZIPs nach iCloud/Backups/<project>/
# Version: v0.2.0
# Änderung: kein 'set -e' mehr, eigene Fehlersteuerung (fatal/strict-exit)
set -uo pipefail

DRY=0; FORMAT="md"; KEEP=7; VERSION="v0.2.0"; STRICT=0
fatal=0

usage(){ cat <<'HLP'
backup_publish_latest — Kopiert letzte N Artefakte in iCloud/Backups/<project>/db/hourly & app/spatie
USAGE
  backup_publish_latest [--dry-run] [--format md|txt] [--keep N] [--strict-exit] [--help] [--version]
HLP
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY=1; shift;;
    --format)  FORMAT="$2"; shift 2;;
    --keep)    KEEP="$2"; shift 2;;
    --strict-exit) STRICT=1; shift;;
    -h|--help) usage; exit 0;;
    --version) echo "$VERSION"; exit 0;;
    *) echo "Unbekannter Parameter: $1"; usage; exit 1;;
  esac
done

[[ -f .env ]] || { echo "Fehler: .env fehlt (im Projekt-Root ausführen)"; exit 2; }

# Logger (Fallbacks)
if [[ -f "$HOME/bin/proj_logger.sh" ]]; then source "$HOME/bin/proj_logger.sh"; fi
if ! type -t log_init >/dev/null 2>&1; then
  log_init(){ :; }; log_section(){ :; }; log_info(){ echo "[INFO] $*"; }
  log_warn(){ echo "[WARN] $*" >&2; }; log_error(){ echo "[ERROR] $*" >&2; }
  log_file(){ :; }; log_dry(){ echo "[DRY] $*"; }
fi

export PROJ_LOG_FORMAT="$FORMAT"
export PROJ_LOG_PREFIX="$(basename "$PWD")|publish_latest"
log_init 2>/dev/null || true
log_section "Publish Latest"
log_info "KEEP=$KEEP DRY_RUN=$DRY STRICT_EXIT=$STRICT"

PROJECT_NAME="$(basename "$PWD")"

# iCloud-Backups-Basis finden
find_base() {
  local u cand
  for u in "${USERNAME:-}" "${USER:-}"; do
    [[ -n "$u" ]] || continue
    for cand in "/mnt/c/Users/$u/iCloudDrive" "/mnt/c/Users/$u/iCloud Drive"; do
      [[ -d "$cand" ]] && { printf "%s\n" "$cand/Backups/${PROJECT_NAME}"; return 0; }
    done
  done
  for d in /mnt/c/Users/*; do
    bn="${d##*/}"
    [[ -d "$d" && "$bn" != "Public" && "$bn" != "Default" && "$bn" != "Default User" ]] || continue
    for cand in "$d/iCloudDrive" "$d/iCloud Drive"; do
      [[ -d "$cand" ]] && { printf "%s\n" "$cand/Backups/${PROJECT_NAME}"; return 0; }
    done
  done
  printf "%s\n" "$PWD/.backups/publish"
}
BASE="$(find_base)"
DST_DB="$BASE/db/hourly"
DST_APP="$BASE/app/spatie"
log_info "Zielbasis: $BASE"

# Helper: Kommandos tolerant ausführen
run() {
  if (( DRY )); then
    log_dry "$*"
    return 0
  fi
  # nicht mit 'set -e' abbrechen; RC abfangen
  bash -c "$*"
  rc=$?
  if (( rc != 0 )); then
    log_warn "Fehler (rc=$rc): $*"
    # nicht fatal, außer wir wollen strict
    (( STRICT )) && fatal=1
  fi
  return 0
}

# Ordner anlegen
run "mkdir -p '$DST_DB'"
run "mkdir -p '$DST_APP'"

# 1) DB: letzte N Dumps (leer? -> Hinweis)
log_section "DB Dumps"
dumps=()
# mapfile kann RC=1 liefern, wenn leer → tolerieren
mapfile -t dumps < <(ls -1t .backups/db/hourly/*.sql.gz 2>/dev/null | head -n "$KEEP" || true) || true
if (( ${#dumps[@]} == 0 )); then
  log_warn "Keine DB-Dumps gefunden in .backups/db/hourly/."
else
  for f in "${dumps[@]}"; do
    b="$(basename "$f")"
    run "cp -f '$f' '$DST_DB/$b'"
    [[ -f "$f.sha256" ]] && run "cp -f '$f.sha256' '$DST_DB/$b.sha256'"
    log_info "DB: $b -> $DST_DB/"
  done
  # Retention in Ziel (tolerant)
  db_all=(); mapfile -t db_all < <(ls -1t "$DST_DB"/*.sql.gz 2>/dev/null || true) || true
  idx=0; for f in "${db_all[@]}"; do
    ((idx++)); if (( idx > KEEP )); then run "rm -f '$f' '$f.sha256'"; fi
  done
fi

# 2) Spatie: letzte N ZIPs (leer? -> Hinweis)
log_section "Spatie ZIPs"
zips=()
mapfile -t zips < <(ls -1t storage/app/laravel-backups/*.zip 2>/dev/null | head -n "$KEEP" || true) || true
if (( ${#zips[@]} == 0 )); then
  log_warn "Keine Spatie-ZIPs gefunden in storage/app/laravel-backups/."
else
  for f in "${zips[@]}"; do
    b="$(basename "$f")"
    run "cp -f '$f' '$DST_APP/$b'"
    if command -v sha256sum >/dev/null 2>&1; then
      run "sha256sum '$DST_APP/$b' > '$DST_APP/$b.sha256'"
    fi
    log_info "APP: $b -> $DST_APP/"
  done
  # Retention in Ziel (tolerant)
  app_all=(); mapfile -t app_all < <(ls -1t "$DST_APP"/*.zip 2>/dev/null || true) || true
  idx=0; for f in "${app_all[@]}"; do
    ((idx++)); if (( idx > KEEP )); then run "rm -f '$f' '$f.sha256'"; fi
  done
fi

lf=""; if type -t log_file >/dev/null 2>&1; then lf="$(log_file || true)"; fi
printf "Logfile: %s\n" "${lf}"

# Exit-Policy
if (( STRICT )); then
  # in strict mode geben wir fatal zurück
  (( fatal == 0 )) && exit 0 || exit 1
else
  # standard: nie wegen Kleinigkeiten scheitern
  exit 0
fi
