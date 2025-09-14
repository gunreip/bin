#!/usr/bin/env bash
# backup_restore_drill.sh — Geführter Restore-Drill (DB + Files) in sichere Zielpfade
# Version: v0.1.3
set -uo pipefail

VERSION="v0.1.3"
DRY=0; FORMAT="md"; STRICT=0; YES=0
DB_ONLY=0; FILES_ONLY=0
DB_NAME=""; RESTORE_ROOT=""; REPO_OVERRIDE=""

usage() { cat <<'HLP'
backup_restore_drill — testweise Wiederherstellung von DB & Files (ohne Live-Overwrite)
USAGE
  backup_restore_drill [--dry-run] [--format md|txt] [--strict-exit] [--yes]
                       [--db-only | --files-only]
                       [--db-name <name>] [--restore-root <dir>] [--repo <restic_repo_path>]
HLP
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY=1; shift;;
    --format) FORMAT="$2"; shift 2;;
    --strict-exit) STRICT=1; shift;;
    --yes) YES=1; shift;;
    --db-only) DB_ONLY=1; FILES_ONLY=0; shift;;
    --files-only) FILES_ONLY=1; DB_ONLY=0; shift;;
    --db-name) DB_NAME="$2"; shift 2;;
    --restore-root) RESTORE_ROOT="$2"; shift 2;;
    --repo) REPO_OVERRIDE="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    --version) echo "$VERSION"; exit 0;;
    *) echo "Unbekannter Parameter: $1" >&2; usage; exit 1;;
  esac
done

[[ -f .env ]] || { echo "Fehler: .env fehlt (im Projekt-Root ausführen)"; exit 2; }

# Logger + Fallbacks
if [[ -f "$HOME/bin/proj_logger.sh" ]]; then source "$HOME/bin/proj_logger.sh"; fi
if ! type -t log_init >/dev/null 2>&1; then
  log_init(){ :; }; log_section(){ :; }
  log_info(){ echo "[INFO] $*"; }; log_warn(){ echo "[WARN] $*" >&2; }; log_error(){ echo "[ERROR] $*" >&2; }
  log_file(){ :; }; log_dry(){ echo "[DRY] $*"; }
fi

export PROJ_LOG_FORMAT="${FORMAT:-md}"
export PROJ_LOG_PREFIX="$(basename "$PWD")|restore_drill"
log_init 2>/dev/null || true
log_section "Plan"
log_info "Version=${VERSION} DRY=${DRY} STRICT=${STRICT} YES=${YES}"

# .env lesen (robust)
dotenv_get() { sed -nE "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*['\"]?([^\"'#]*)['\"]?.*$/\1/p" .env | tail -n1 | tr -d '\r'; }
DB_HOST="$(dotenv_get DB_HOST)"; DB_PORT="$(dotenv_get DB_PORT)"
DB_DATABASE="$(dotenv_get DB_DATABASE)"; DB_USERNAME="$(dotenv_get DB_USERNAME)"
DB_PASSWORD="$(dotenv_get DB_PASSWORD)"

[[ -n "$DB_HOST" && -n "$DB_PORT" && -n "$DB_DATABASE" && -n "$DB_USERNAME" ]] || {
  log_error "DB-Konfiguration unvollständig (.env)"; exit 3;
}
[[ -z "$DB_NAME" ]] && DB_NAME="${DB_DATABASE}_restore"
[[ -z "$DB_HOST" ]] && DB_HOST="127.0.0.1"

# Einheitliche Verbindungs-ENV
export PGHOST="$DB_HOST"
export PGPORT="$DB_PORT"
export PGUSER="$DB_USERNAME"
export PGPASSWORD="$DB_PASSWORD"

log_info "DB-Conn: host=${DB_HOST} port=${DB_PORT} user=${DB_USERNAME} db(src)=${DB_DATABASE} db(target)=${DB_NAME}"

# Restic-Repo finden
detect_repo() {
  [[ -n "${REPO_OVERRIDE:-}" ]] && { printf "%s\n" "$REPO_OVERRIDE"; return 0; }
  [[ -n "${BACKUP_REPO:-}" && -d "${BACKUP_REPO}" ]] && { printf "%s\n" "$BACKUP_REPO"; return 0; }
  local u cand base legacy project; project="$(basename "$PWD")"
  for u in "${USERNAME:-}" "${USER:-}"; do
    [[ -n "$u" ]] || continue
    for cand in "/mnt/c/Users/$u/iCloudDrive" "/mnt/c/Users/$u/iCloud Drive"; do
      if [[ -d "$cand" ]]; then
        base="$cand/Backups/${project}/restic"; legacy="$cand/${project}_restic"
        [[ -d "$legacy" ]] && { printf "%s\n" "$legacy"; return 0; }
        printf "%s\n" "$base"; return 0
      fi
    done
  done
  for d in /mnt/c/Users/*; do
    bn="${d##*/}"
    [[ -d "$d" && "$bn" != "Public" && "$bn" != "Default" && "$bn" != "Default User" ]] || continue
    for cand in "$d/iCloudDrive" "$d/iCloud Drive"; do
      if [[ -d "$cand" ]]; then
        base="$cand/Backups/${project}/restic"; legacy="$cand/${project}_restic"
        [[ -d "$legacy" ]] && { printf "%s\n" "$legacy"; return 0; }
        printf "%s\n" "$base"; return 0
      fi
    done
  done
  printf "%s\n" "$PWD/.backups/restic"
}
REPO="$(detect_repo)"
PASSFILE="$HOME/.config/restic/pass"

ts="$(date +%Y%m%d_%H%M%S)"
[[ -z "$RESTORE_ROOT" ]] && RESTORE_ROOT="$PWD/.restore/${ts}"
DST_DB_DIR="$RESTORE_ROOT/db"; DST_FILES_DIR="$RESTORE_ROOT/files"
log_info "Restore-Root: ${RESTORE_ROOT}"
log_info "Restic-Repo: ${REPO}"

fatal=0
run() {
  local cmd="$*"
  if (( DRY )); then log_dry "$cmd"; return 0; fi
  bash -c "$cmd"; local rc=$?
  (( rc != 0 )) && { log_warn "Fehler (rc=$rc): $cmd"; (( STRICT )) && fatal=1; }
  return 0
}

# Helper: DB existiert?
db_exists() {
  local qname; qname="$(printf "%s" "$DB_NAME" | sed "s/'/''/g")"
  psql -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='${qname}'" 2>/dev/null | grep -q 1
}

# Helper: DB anlegen (2 Versuche), true/false zurückgeben
create_db() {
  # Versuch 1: createdb
  createdb "$DB_NAME" >/dev/null 2>&1 && return 0
  # Versuch 2: explizit via psql
  local qname oname
  qname="$(printf "%s" "$DB_NAME" | sed 's/"/""/g')"
  oname="$(printf "%s" "$DB_USERNAME" | sed 's/"/""/g')"
  psql -d postgres -v ON_ERROR_STOP=1 -c "CREATE DATABASE \"${qname}\" OWNER \"${oname}\" TEMPLATE template0 ENCODING 'UTF8';" >/dev/null 2>&1 && return 0
  return 1
}

# Sicherheitsabfrage
if (( !DRY )) && (( YES == 0 )); then
  echo "Restore-Drill: Es werden NEUE Ziele angelegt (keine Overwrites). Fortfahren? [YES/no]"
  read -r answer
  [[ "$answer" == "YES" ]] || { log_warn "Abgebrochen vom Benutzer."; echo "Logfile: $(log_file 2>/dev/null || echo '')"; exit 0; }
fi

# --- A) DB-Restore ---
if (( FILES_ONLY == 0 )); then
  log_section "DB Restore"

  latest_dump="$(ls -1t .backups/db/hourly/*.sql.gz 2>/dev/null | head -n1 || true)"
  if [[ -z "$latest_dump" ]]; then
    log_error "Kein lokaler Dump gefunden (.backups/db/hourly/*.sql.gz)."
    (( STRICT )) && exit 11 || fatal=1
  else
    log_info "Quelle: $latest_dump"
    # 1) Server-Connectivity gegen bestehende DB (oder postgres als Fallback)
    if (( DRY )); then
      log_dry "psql -d '$DB_DATABASE' -c 'select 1;' || psql -d postgres -c 'select 1;'"
    else
      if ! psql -d "$DB_DATABASE" -c 'select 1;' >/dev/null 2>&1; then
        if ! psql -d postgres -c 'select 1;' >/dev/null 2>&1; then
          log_error "DB-Server nicht erreichbar (weder $DB_DATABASE noch postgres). Läuft PostgreSQL?"
          (( STRICT )) && exit 12 || fatal=1
        fi
      fi
    fi
    # 2) Ziel-DB sicherstellen
    if db_exists; then
      log_info "Ziel-DB existiert bereits: ${DB_NAME}"
    else
      if (( DRY )); then
        log_dry "createdb '$DB_NAME' || psql -d postgres -c 'CREATE DATABASE \"${DB_NAME}\" OWNER \"${DB_USERNAME}\" TEMPLATE template0 ENCODING ''UTF8'';'"
      else
        if create_db; then
          log_info "Ziel-DB angelegt: ${DB_NAME}"
        else
          # Rechte prüfen & Hinweise
          has_createdb="$(psql -d postgres -tAc "SELECT rolcreatedb FROM pg_roles WHERE rolname=current_user;" 2>/dev/null | tr -d '[:space:]')"
          log_error "Konnte Ziel-DB nicht anlegen: ${DB_NAME}"
          if [[ "$has_createdb" != "t" ]]; then
            log_warn "Aktueller User hat KEIN CREATEDB-Recht."
            log_warn "Optionen:"
            log_warn "  a) Als Superuser: ALTER ROLE \"${DB_USERNAME}\" CREATEDB;"
            log_warn "  b) Script mit --db-name <existierende_db> aufrufen"
            log_warn "  c) Restore mit einem User ausführen, der CREATEDB hat (z. B. postgres)"
          fi
          (( STRICT )) && exit 13 || { fatal=1; }
        fi
      fi
    fi
    # 3) Einspielen
    if (( DRY )); then
      log_dry "zcat '$latest_dump' | psql -d '$DB_NAME'"
    else
      run "zcat '$latest_dump' | psql -d '$DB_NAME'"
    fi
  fi
fi

# --- B) Files-Restore (Restic) ---
if (( DB_ONLY == 0 )); then
  log_section "Files Restore"
  [[ -z "$RESTORE_ROOT" ]] && RESTORE_ROOT="$PWD/.restore/$(date +%Y%m%d_%H%M%S)"
  run "mkdir -p '$DST_FILES_DIR'"
  if (( DRY )); then
    log_dry "RESTIC_PASSWORD_FILE='$PASSFILE' restic -r '$REPO' snapshots --last"
    log_dry "RESTIC_PASSWORD_FILE='$PASSFILE' restic -r '$REPO' restore latest --target '$DST_FILES_DIR' --include 'storage/app/**'"
  else
    if command -v restic >/dev/null 2>&1; then
      RESTIC_PASSWORD_FILE="$PASSFILE" restic -r "$REPO" snapshots --last >/dev/null 2>&1 || log_warn "Snapshots-Anzeige warnte."
      run "RESTIC_PASSWORD_FILE='$PASSFILE' restic -r '$REPO' restore latest --target '$DST_FILES_DIR' --include 'storage/app/**'"
    else
      log_warn "restic nicht gefunden – Files-Restore übersprungen."
    fi
  fi
  log_info "Files (falls vorhanden) liegen in: $DST_FILES_DIR/storage/app/"
fi

lf=""; if type -t log_file >/dev/null 2>&1; then lf="$(log_file || true)"; fi
printf "Logfile: %s\n" "${lf}"
(( STRICT )) && (( fatal != 0 )) && exit 1 || exit 0
