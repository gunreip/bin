#!/usr/bin/env bash
# backup_prune_weekly.sh — Restic Retention (7d,4w,12m) + Check
# Version: v0.3.0
set -euo pipefail
DRY=0; FORMAT="md"; REPO_OVERRIDE=""; VERSION="v0.3.0"

usage(){ cat <<'HLP'
backup_prune_weekly — Restic "forget --prune" + "check"
USAGE
  backup_prune_weekly [--dry-run] [--format md|txt] [--repo <path>] [--help] [--version]
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

if [[ -f "/home/gunreip/bin/proj_logger.sh" ]]; then source "/home/gunreip/bin/proj_logger.sh"; fi
if ! type -t log_init >/dev/null 2>&1; then
  log_init(){ :; }; log_section(){ :; }; log_info(){ echo "[INFO] $*"; }
  log_warn(){ echo "[WARN] $*" >&2; }; log_error(){ echo "[ERROR] $*" >&2; }
  log_file(){ :; }
fi

export PROJ_LOG_FORMAT="$FORMAT"
export PROJ_LOG_PREFIX="$PWD|backup_prune"
log_init 2>/dev/null || true
log_section "Prune"; log_info "Version: $VERSION"; log_info "Dry-Run: $DRY"

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

if (( ! DRY )); then command -v restic >/dev/null 2>&1 || { log_error "restic nicht gefunden"; exit 3; }; fi

if (( DRY )); then
  log_dry "RESTIC_PASSWORD_FILE='$PASSFILE' restic -r '$REPO' forget --prune --keep-daily 7 --keep-weekly 4 --keep-monthly 12 --tag tafw"
  log_dry "RESTIC_PASSWORD_FILE='$PASSFILE' restic -r '$REPO' check --read-data-subset=1%"
else
  RESTIC_PASSWORD_FILE="$PASSFILE" restic -r "$REPO" forget --prune --keep-daily 7 --keep-weekly 4 --keep-monthly 12 --tag tafw     || log_warn "forget/prune meldete Warnungen/Fehler"
  RESTIC_PASSWORD_FILE="$PASSFILE" restic -r "$REPO" check --read-data-subset=1%     || log_warn "check meldete Warnungen/Fehler"
fi

lf=""; if type -t log_file >/dev/null 2>&1; then lf="$(log_file || true)"; fi
printf "Logfile: %s\n" "${lf}"
exit 0
