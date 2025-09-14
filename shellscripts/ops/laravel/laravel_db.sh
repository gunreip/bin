#!/usr/bin/env bash
# laravel_db.sh
# Purpose:
#   - Run ONLY inside a Laravel <project> (requires .env + artisan).
#   - Read DB settings from .env (DB_DATABASE, DB_USERNAME, DB_PASSWORD, DB_HOST, DB_PORT).
#   - Create/adjust role & database idempotently; set DB owner.
#   - Verify connection as the application user (over TCP).
#
# Flags (override .env):
#   -d <dbname>   # DB name
#   -u <dbuser>   # DB user
#   -p <dbpass>   # DB password (prompted if empty and -y not set)
#   -h <dbhost>   # DB host (default from .env or 127.0.0.1)
#   -P <dbport>   # DB port (default from .env or 5432)
#   -y            # Non-interactive (no prompts)
#
# Mini flag explanations:
#   psql -v ON_ERROR_STOP=1   # stop on first SQL error
#   psql -Atq                 # -A: unaligned, -t: tuples only, -q: quiet
#   sudo -u postgres <cmd>    # run as OS user 'postgres' (bypasses peer auth)
set -Eeuo pipefail
IFS=$'\n\t'

info(){ printf "[INFO] %s\n" "$*"; }
warn(){ printf "[WARN] %s\n" "$*" >&2; }
err(){  printf "[ERROR] %s\n" "$*" >&2; }
die(){  err "$*"; exit 1; }

usage(){
  cat <<USAGE
Usage: $(basename "$0") [-d <dbname>] [-u <dbuser>] [-p <dbpass>] [-h <dbhost>] [-P <dbport>] [-y]
Reads defaults from .env in the current project directory. Must be run inside a <project>!
USAGE
}

# Gatekeeper: ensure we're inside a Laravel project
[[ -f .env && -f artisan ]] || die "Kein Projektordner. Dieses Script nur aus einem <project> mit .env + artisan ausführen."

# .env reader (last occurrence wins, strips surrounding quotes)
env_get(){
  local key="$1"
  local line val
  line="$(grep -E "^[[:space:]]*${key}=" .env | tail -n1 | sed -E "s/^[[:space:]]*${key}=(.*)$/\1/" | tr -d '\r')"
  val="${line%\"}"; val="${val#\"}"; val="${val%\'}"; val="${val#\'}"
  printf "%s" "$val"
}

# Defaults from .env
DB_NAME_DEFAULT="$(env_get DB_DATABASE || true)"
DB_USER_DEFAULT="$(env_get DB_USERNAME || true)"
DB_PASS_DEFAULT="$(env_get DB_PASSWORD || true)"
DB_HOST_DEFAULT="$(env_get DB_HOST || true)"
DB_PORT_DEFAULT="$(env_get DB_PORT || true)"
[[ -n "${DB_HOST_DEFAULT}" ]] || DB_HOST_DEFAULT="127.0.0.1"
[[ -n "${DB_PORT_DEFAULT}" ]] || DB_PORT_DEFAULT="5432"

DB_NAME="${DB_NAME_DEFAULT}"
DB_USER="${DB_USER_DEFAULT}"
DB_PASS="${DB_PASS_DEFAULT}"
DB_HOST="${DB_HOST_DEFAULT}"
DB_PORT="${DB_PORT_DEFAULT}"
ASSUME_YES=0

# CLI overrides
while getopts ":d:u:p:h:P:y" opt; do
  case "$opt" in
    d) DB_NAME="$OPTARG" ;;
    u) DB_USER="$OPTARG" ;;
    p) DB_PASS="$OPTARG" ;;
    h) DB_HOST="$OPTARG" ;;
    P) DB_PORT="$OPTARG" ;;
    y) ASSUME_YES=1 ;;
    *) usage; exit 1 ;;
  done
done

# Connection driver sanity
DB_CONN="$(env_get DB_CONNECTION || true)"
if [[ -n "$DB_CONN" && "$DB_CONN" != "pgsql" ]]; then
  die "DB_CONNECTION=$DB_CONN in .env → dieses Script ist für PostgreSQL (pgsql). Abbruch."
fi

# Required fields; ask for password if missing (unless -y)
[[ -n "${DB_NAME:-}" ]] || die "DB_DATABASE fehlt (in .env oder via -d)."
[[ -n "${DB_USER:-}" ]] || die "DB_USERNAME fehlt (in .env oder via -u)."
if [[ -z "${DB_PASS:-}" ]]; then
  if (( ASSUME_YES )); then
    die "DB_PASSWORD fehlt und -y gesetzt (keine Interaktion erlaubt)."
  fi
  read -r -s -p "Passwort für DB-User ${DB_USER}: " DB_PASS; echo ""
fi

# Escaping helpers
esc_sql_lit(){ printf "%s" "$1" | sed "s/'/''/g"; }
esc_ident(){   printf "%s" "$1" | sed 's/\"/\"\"/g'; }

USER_SQL="$(esc_sql_lit "$DB_USER")"
PASS_SQL="$(esc_sql_lit "$DB_PASS")"
DB_SQL="$(esc_sql_lit "$DB_NAME")"
DB_I="$(esc_ident "$DB_NAME")"
USER_I="$(esc_ident "$DB_USER")"

info "Ziel: DB='${DB_NAME}', USER='${DB_USER}', HOST='${DB_HOST}', PORT='${DB_PORT}'"

# Create/alter role (idempotent)
info "Rolle prüfen/anlegen…"
sudo -u postgres psql -v ON_ERROR_STOP=1 <<SQL
DO
\$\$
BEGIN
   IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${USER_SQL}') THEN
      EXECUTE format('CREATE ROLE %I LOGIN PASSWORD %L', '${USER_SQL}', '${PASS_SQL}');
   ELSE
      EXECUTE format('ALTER ROLE %I WITH PASSWORD %L', '${USER_SQL}', '${PASS_SQL}');
   END IF;
END
\$\$;
SQL

# Create DB if missing; ensure owner
EXISTS_DB="$(sudo -u postgres psql -Atq -c "SELECT 1 FROM pg_database WHERE datname='${DB_SQL}'" || true)"
if [[ -z "$EXISTS_DB" ]]; then
  info "Datenbank anlegen und Owner setzen…"
  sudo -u postgres psql -v ON_ERROR_STOP=1 -c "CREATE DATABASE \"${DB_I}\" OWNER \"${USER_I}\";"
else
  CURR_OWNER="$(sudo -u postgres psql -Atq -c "SELECT pg_catalog.pg_get_userbyid(datdba) FROM pg_database WHERE datname='${DB_SQL}'" || true)"
  if [[ "$CURR_OWNER" != "$DB_USER" ]]; then
    info "Setze Owner der bestehenden DB auf ${DB_USER}… (war: ${CURR_OWNER:-unbekannt})"
    sudo -u postgres psql -v ON_ERROR_STOP=1 -c "ALTER DATABASE \"${DB_I}\" OWNER TO \"${USER_I}\";"
  fi
fi

# Connection test (TCP, matches Laravel behavior)
info "Verbindungstest als ${DB_USER}…"
PGPASSWORD="${DB_PASS}" psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -c "\conninfo" >/dev/null

info "✅ Datenbank '${DB_NAME}' & User '${DB_USER}' einsatzbereit."
