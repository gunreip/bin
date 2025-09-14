#!/usr/bin/env bash
set -euo pipefail

SCRIPT_VERSION="v1.0.1"

print_version() {
  printf "spatie_backup_setup.sh %s\n" "$SCRIPT_VERSION"
  exit 0
}

usage() {
  cat <<'USAGE'
Usage:
  spatie_backup_setup.sh [-p <project_path>] [--full] [--dry-run] [--version]

Options:
  -p <path>     Projektpfad (Default: aktuelles Verzeichnis)
  --full        Full-Backup (DB + Files); Standard ist DB-only
  --dry-run     Nur anzeigen, was gemacht würde
  --version     Version ausgeben
USAGE
  exit 1
}

PROJECT_PATH="$(pwd)"
MODE="db"        # "db" oder "full"
DRY_RUN=0

# Argumente parsen
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p)
      [[ $# -ge 2 ]] || { echo "Fehlender Wert für -p"; usage; }
      PROJECT_PATH="$2"; shift 2;;
    --full)
      MODE="full"; shift;;
    --dry-run)
      DRY_RUN=1; shift;;
    --version)
      print_version;;
    -h|--help)
      usage;;
    *)
      echo "Unbekannte Option: $1"; usage;;
  esac
done

# Hilfsfunktionen
log() { printf "%s\n" "$*"; }
run_cmd() {
  if [[ $DRY_RUN -eq 1 ]]; then
    printf "[dry-run] %q" "$1"; shift || true
    for arg in "$@"; do printf " %q" "$arg"; done
    printf "\n"
  else
    "$@"
  fi
}

req_file() {
  if [[ ! -f "$1" ]]; then
    echo "Fehlt: $1" >&2
    exit 2
  fi
}

# Pfade prüfen
if [[ ! -d "$PROJECT_PATH" ]]; then
  echo "Projektpfad nicht gefunden: $PROJECT_PATH" >&2
  exit 2
fi

cd "$PROJECT_PATH"

# php/artisan/composer prüfen
if ! command -v php >/dev/null 2>&1; then
  echo "php nicht gefunden (benötigt für Artisan)" >&2
  exit 2
fi
ARTISAN="$PROJECT_PATH/artisan"
if [[ ! -f "$ARTISAN" ]]; then
  echo "artisan nicht gefunden unter: $ARTISAN" >&2
  exit 2
fi

if command -v composer >/dev/null 2>&1; then
  COMPOSER=(composer)
elif [[ -f "$PROJECT_PATH/composer.phar" ]]; then
  COMPOSER=(php "$PROJECT_PATH/composer.phar")
else
  echo "composer nicht gefunden. Installiere Composer oder lege composer.phar ins Projekt." >&2
  exit 2
fi

# 1) spatie/laravel-backup installieren
log "→ Installiere spatie/laravel-backup (kann etwas dauern)…"
run_cmd "${COMPOSER[@]}" require spatie/laravel-backup --no-interaction --no-progress

# 2) backup-config veröffentlichen (nur falls fehlt)
if [[ ! -f "$PROJECT_PATH/config/backup.php" ]]; then
  log "→ Veröffentliche Konfiguration (backup.php)…"
  run_cmd php "$ARTISAN" vendor:publish --tag="backup-config" --force
else
  log "→ Konfiguration vorhanden: config/backup.php"
fi

# 3) Backup-Verzeichnis sicherstellen
BACKUP_DIR="$PROJECT_PATH/storage/app/laravel-backups"
if [[ ! -d "$BACKUP_DIR" ]]; then
  run_cmd mkdir -p "$BACKUP_DIR"
  log "→ Backup-Verzeichnis angelegt: $BACKUP_DIR"
else
  log "→ Backup-Verzeichnis vorhanden: $BACKUP_DIR"
fi

# 4) .gitignore Eintrag
GITIGNORE="$PROJECT_PATH/.gitignore"
IGNORE_LINE="/storage/app/laravel-backups/*"
if [[ -f "$GITIGNORE" ]]; then
  if ! grep -Fq "$IGNORE_LINE" "$GITIGNORE"; then
    if [[ $DRY_RUN -eq 1 ]]; then
      printf "[dry-run] append to .gitignore: %s\n" "$IGNORE_LINE"
    else
      printf "\n# Spatie backups\n%s\n" "$IGNORE_LINE" >> "$GITIGNORE"
      log "→ .gitignore ergänzt"
    fi
  else
    log "→ .gitignore enthält bereits den Backup-Eintrag"
  fi
else
  if [[ $DRY_RUN -eq 1 ]]; then
    printf "[dry-run] create .gitignore and add: %s\n" "$IGNORE_LINE"
  else
    printf "# Spatie backups\n%s\n" "$IGNORE_LINE" > "$GITIGNORE"
    log "→ .gitignore erstellt"
  fi
fi

# 5) routes/console.php anpassen (Laravel 11+ Scheduling)
ROUTES_FILE="$PROJECT_PATH/routes/console.php"
if [[ ! -f "$ROUTES_FILE" ]]; then
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "[dry-run] create routes/console.php with Schedule import"
  else
    cat > "$ROUTES_FILE" <<'PHP'
<?php

use Illuminate\Support\Facades\Schedule;

PHP
    log "→ routes/console.php erstellt"
  fi
else
  # sicherstellen: use Schedule
  if ! grep -Eq 'use\s+Illuminate\\Support\\Facades\\Schedule;' "$ROUTES_FILE"; then
    if [[ $DRY_RUN -eq 1 ]]; then
      echo "[dry-run] insert Schedule import into routes/console.php"
    else
      tmpfile="$(mktemp)"
      awk 'NR==1 && $0 ~ /<\?php/ { print; print ""; print "use Illuminate\\Support\\Facades\\Schedule;"; next } { print }' "$ROUTES_FILE" > "$tmpfile"
      mv "$tmpfile" "$ROUTES_FILE"
      log "→ Schedule-Import ergänzt in routes/console.php"
    fi
  fi
fi

# Blöcke hinzufügen (idempotent)
ADD_DB=0
if grep -q "backup:run --only-db" "$ROUTES_FILE"; then
  log "→ Schedule für backup:run --only-db bereits vorhanden"
else
  ADD_DB=1
fi

ADD_FULL=0
if grep -q "backup:run'" "$ROUTES_FILE" || grep -q 'backup:run"' "$ROUTES_FILE"; then
  :
else
  ADD_FULL=1
fi

ADD_CLEAN=0
if grep -q "backup:clean" "$ROUTES_FILE"; then :; else ADD_CLEAN=1; fi

ADD_MONITOR=0
if grep -q "backup:monitor" "$ROUTES_FILE"; then :; else ADD_MONITOR=1; fi

append_block() {
  local block="$1"
  if [[ $DRY_RUN -eq 1 ]]; then
    printf "[dry-run] append to routes/console.php:\n%s\n" "$block"
  else
    printf "%s\n" "$block" >> "$ROUTES_FILE"
  fi
}

# Je nach MODE den primary run-Eintrag setzen
if [[ "$MODE" == "db" ]]; then
  if [[ $ADD_DB -eq 1 ]]; then
    append_block "$(cat <<'PHP'
// Spatie Backup: DB-only wöchentlicher Lauf (So 03:10)
Schedule::command('backup:run --only-db')
    ->cron('10 3 * * 0')
    ->name('backup:run-db');
PHP
)"
  fi
else
  if [[ $ADD_FULL -eq 1 ]]; then
    append_block "$(cat <<'PHP'
// Spatie Backup: Full wöchentlicher Lauf (So 03:10)
Schedule::command('backup:run')
    ->cron('10 3 * * 0')
    ->name('backup:run-full');
PHP
)"
  fi
fi

if [[ $ADD_CLEAN -eq 1 ]]; then
  append_block "$(cat <<'PHP'
// Spatie Backup: Clean (So 03:40)
Schedule::command('backup:clean')
    ->cron('40 3 * * 0')
    ->name('backup:clean');
PHP
)"
fi

if [[ $ADD_MONITOR -eq 1 ]]; then
  append_block "$(cat <<'PHP'
// Spatie Backup: Monitor (Mo 08:00)
Schedule::command('backup:monitor')
    ->cron('0 8 * * 1')
    ->name('backup:monitor');
PHP
)"
fi

# 6) Caches leeren
run_cmd php "$ARTISAN" optimize:clear

# 7) Initiales Backup ausführen
if [[ "$MODE" == "db" ]]; then
  log "→ Führe initiales DB-Backup aus…"
  run_cmd php "$ARTISAN" backup:run --only-db
else
  log "→ Führe initiales Full-Backup aus…"
  run_cmd php "$ARTISAN" backup:run
fi

log "✅ Fertig. Zeitpläne sind in routes/console.php, Backups landen unter storage/app/laravel-backups/"
