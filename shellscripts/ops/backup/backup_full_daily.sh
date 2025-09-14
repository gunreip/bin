#!/usr/bin/env bash
# backup_full_daily.sh — Laravel-Spatie-Backup + Restic-Push ins iCloud-Repo
# Version: v0.4.0
set -euo pipefail
DRY=0; FORMAT="md"; REPO_OVERRIDE=""; fatal=0
VERSION="v0.4.0"

usage(){ cat <<'HLP'
backup_full_daily — Spatie-Backup + Restic nach iCloud/Backups/<project>/restic
USAGE
  backup_full_daily [--dry-run] [--format md|txt] [--repo <path>] [--help] [--version]
HLP
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY=1; shift;;
    --format)  FORMAT="$2"; shift 2;;
    --repo)    REPO_OVERRIDE="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    --version) echo "$VERSION"; exit 0;;
    *) echo "Unbekannter Parameter: $1"; usage; exit 1;;
  esac
done

[[ -f .env ]] || { echo "Fehler: .env fehlt (im Projekt-Root ausführen)"; exit 2; }

# Logger (Fallbacks, falls nicht vorhanden)
if [[ -f "/home/gunreip/bin/proj_logger.sh" ]]; then source "/home/gunreip/bin/proj_logger.sh"; fi
if ! type -t log_init >/dev/null 2>&1; then
  log_init(){ :; }; log_section(){ :; }; log_info(){ echo "[INFO] $*"; }
  log_warn(){ echo "[WARN] $*" >&2; }; log_error(){ echo "[ERROR] $*" >&2; }
  log_file(){ :; }
fi

export PROJ_LOG_FORMAT="$FORMAT"
export PROJ_LOG_PREFIX="$PWD|backup_full_daily"
log_init 2>/dev/null || true
log_section "Full Daily"
log_info "Version: $VERSION"; log_info "Dry-Run: $DRY"

PROJECT_NAME="$PWD"
detect_repo() {
  # 1) explizite Overrides
  if [[ -n "${REPO_OVERRIDE:-}" ]]; then printf "%s\n" "$REPO_OVERRIDE"; return 0; fi
  if [[ -n "${BACKUP_REPO:-}" && -d "${BACKUP_REPO}" ]]; then printf "%s\n" "$BACKUP_REPO"; return 0; fi

  # 2) iCloud bevorzugt: Backups/<project>/restic
  local u cand base preferred legacy
  for u in "${USERNAME:-}" "${USER:-}"; do
    [[ -n "$u" ]] || continue
    for cand in "/mnt/c/Users/$u/iCloudDrive" "/mnt/c/Users/$u/iCloud Drive"; do
      if [[ -d "$cand" ]]; then
        base="$cand/Backups/${PROJECT_NAME}/restic"
        legacy="$cand/${PROJECT_NAME}_restic"
        # wenn Legacy existiert, erst Legacy nutzen (nicht einfach ignorieren)
        if [[ -d "$legacy" ]]; then printf "%s\n" "$legacy"; return 0; fi
        printf "%s\n" "$base"; return 0
      fi
    done
  done

  # 3) Heuristik: erster „echter“ Nutzer
  for d in /mnt/c/Users/*; do
    bn="${d##*/}"
    [[ -d "$d" && "$bn" != "Public" && "$bn" != "Default" && "$bn" != "Default User" ]] || continue
    for cand in "$d/iCloudDrive" "$d/iCloud Drive"; do
      if [[ -d "$cand" ]]; then
        base="$cand/Backups/${PROJECT_NAME}/restic"
        legacy="$cand/${PROJECT_NAME}_restic"
        if [[ -d "$legacy" ]]; then printf "%s\n" "$legacy"; return 0; fi
        printf "%s\n" "$base"; return 0
      fi
    done
  done

  # 4) Projekt-lokal
  printf "%s\n" "$PWD/.backups/restic"
}
REPO="$(detect_repo)"
PASSFILE="$HOME/.config/restic/pass"
log_info "Restic-Repo: $REPO"

if (( ! DRY )); then
  command -v php >/dev/null 2>&1    || { log_error "php nicht gefunden"; exit 3; }
  command -v restic >/dev/null 2>&1 || { log_error "restic nicht gefunden (sudo apt install restic)"; exit 4; }
fi

# Passwortdatei
if (( DRY )); then
  [[ -f "$PASSFILE" ]] || log_dry "mkdir -p '$HOME/.config/restic' && umask 077 && echo '<starkes-passwort>' > '$PASSFILE'"
else
  if [[ ! -f "$PASSFILE" ]]; then
    mkdir -p "$HOME/.config/restic"; umask 077
    echo "please-change-me-$(date +%s)" > "$PASSFILE"
    log_warn "PASSFILE neu angelegt: $PASSFILE — bitte Passwort ändern!"
  fi
fi

# Repo vorbereiten
if (( DRY )); then
  log_dry "mkdir -p '$REPO'"
  log_dry "RESTIC_PASSWORD_FILE='$PASSFILE' restic -r '$REPO' snapshots || restic init"
else
  mkdir -p "$REPO"
  if ! RESTIC_PASSWORD_FILE="$PASSFILE" restic -r "$REPO" snapshots >/dev/null 2>&1; then
    if RESTIC_PASSWORD_FILE="$PASSFILE" restic -r "$REPO" init; then
      log_info "Restic-Repo initialisiert"
    else
      log_error "Restic-Repo konnte nicht initialisiert werden"; fatal=1
    fi
  fi
fi

# 1) Spatie
log_section "Spatie"
if (( DRY )); then
  log_dry "php artisan backup:run"
else
  if php artisan backup:run; then log_info "Spatie-Backup OK"; else log_error "artisan backup:run fehlgeschlagen"; fatal=1; fi
fi

# 2) Restic Backup
log_section "Restic Backup"
INCLUDE=( ".env" "storage/app/laravel-backups" ".backups/db" )
for p in "${INCLUDE[@]}"; do
  if (( DRY )); then
    log_dry "RESTIC_PASSWORD_FILE='$PASSFILE' restic -r '$REPO' backup '$p' --tag tafw --host wsl"
  else
    RESTIC_PASSWORD_FILE="$PASSFILE" restic -r "$REPO" backup "$p" --tag tafw --host wsl || log_warn "Warnung beim Backup: $p"
  fi
done

# 3) Short verify
log_section "Verify"
if (( DRY )); then
  log_dry "RESTIC_PASSWORD_FILE='$PASSFILE' restic -r '$REPO' snapshots --last"
else
  RESTIC_PASSWORD_FILE="$PASSFILE" restic -r "$REPO" snapshots --last >/dev/null 2>&1 || log_warn "Snapshots-Anzeige meldete Warnungen"
fi

lf=""; if type -t log_file >/dev/null 2>&1; then lf="$(log_file || true)"; fi
printf "Logfile: %s\n" "${lf}"
(( fatal == 0 )) && exit 0 || exit 10
