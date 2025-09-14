#!/usr/bin/env bash
# pg_upgrade_pg16_to_pg17.sh
# Version: v0.2.2 (2025-08-30)

set -Eeuo pipefail
IFS=$'\n\t'

# ---- Logging ----
info(){ printf "[INFO] %s\n" "$*"; }
warn(){ printf "[WARN] %s\n" "$*" >&2; }
err(){  printf "[ERROR] %s\n" "$*" >&2; }
die(){  err "$*"; exit 1; }

# ---- Args ----
DO_BACKUP=1
DROP_OLD=0
DB_USER="${USER:-postgres}"
CLUSTER_NAME="main"

while (( "$#" )); do
  case "$1" in
    --no-backup) DO_BACKUP=0; shift ;;
    --drop-old)  DROP_OLD=1;  shift ;;
    --user)      DB_USER="${2:-$DB_USER}"; shift 2 ;;
    --cluster)   CLUSTER_NAME="${2:-$CLUSTER_NAME}"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--no-backup] [--drop-old] [--user <dbuser>] [--cluster <name>]"; exit 0 ;;
    *) die "Unbekanntes Argument: $1" ;;
  esac
done

# ---- Preflight ----
command -v lsb_release >/dev/null || die "lsb_release fehlt (sudo apt install lsb-release)."
for bin in psql pg_lsclusters pg_ctlcluster; do
  command -v "$bin" >/dev/null || die "Tool fehlt: $bin (sudo apt install postgresql-common)."
done

[[ "$(pg_lsclusters | grep -cE '^16\s+')" -ge 1 ]] || die "Kein 16er Cluster gefunden."
CODENAME="$(lsb_release -cs)"
PGDG_LIST="/etc/apt/sources.list.d/pgdg.list"
BACKUP_FILE="${HOME}/backup_pg16_$(date +%F_%H%M%S).sql"

# ---- Backup ----
if (( DO_BACKUP )); then
  info "Erstelle Backup: $BACKUP_FILE"
  command -v pg_dumpall >/dev/null || { sudo apt-get update -y; sudo apt-get install -y postgresql-client-common; }
  if ! pg_dumpall -U "$DB_USER" > "$BACKUP_FILE" 2>/dev/null; then
    warn "Backup mit -U $DB_USER fehlgeschlagen, versuche 'sudo -u postgres pg_dumpall'…"
    sudo -u postgres pg_dumpall > "$BACKUP_FILE" || die "Backup fehlgeschlagen."
  fi
  info "Backup OK."
else
  warn "--no-backup gesetzt: Backup wird übersprungen."
fi

# ---- PGDG Repo ----
if [[ ! -f "$PGDG_LIST" ]] || ! grep -q "-pgdg main" "$PGDG_LIST"; then
  info "Binde PGDG-Repository ein (${CODENAME})…"
  echo "deb http://apt.postgresql.org/pub/repos/apt ${CODENAME}-pgdg main" | sudo tee "$PGDG_LIST" >/dev/null
  (command -v curl >/dev/null && curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | sudo apt-key add -) \
  || (wget -qO- https://www.postgresql.org/media/keys/ACCC4CF8.asc | sudo apt-key add -) || true
else
  info "PGDG-Repository bereits vorhanden."
fi
sudo apt-get update -y

# ---- Install 17 ----
info "Installiere PostgreSQL 17…"
sudo apt-get install -y postgresql-17 postgresql-client-17

# ---- 17er Cluster sicherstellen ----
if ! pg_lsclusters | awk '$1==17 {ok=1} END{exit !ok}'; then
  info "Erzeuge 17er Cluster '${CLUSTER_NAME}'…"
  sudo pg_createcluster 17 "${CLUSTER_NAME}" --start
else
  info "17er Cluster vorhanden."
fi

# ---- Upgrade 16 -> 17 ----
info "Starte Upgrade 16→17…"
sudo pg_upgradecluster 16 "${CLUSTER_NAME}"

# ---- Check ----
info "psql --version: $(psql --version | awk '{print $3}')"
info "Clusterübersicht:"
pg_lsclusters || true

# ---- Optional: altes Cluster löschen ----
if (( DROP_OLD )); then
  warn "Entferne altes 16er Cluster '${CLUSTER_NAME}' …"
  sudo pg_dropcluster 16 "${CLUSTER_NAME}" --stop
  info "16er Cluster entfernt."
else
  warn "Altes 16er Cluster NICHT gelöscht. Entfernen mit: sudo pg_dropcluster 16 ${CLUSTER_NAME} --stop"
fi

info "Upgrade abgeschlossen."
