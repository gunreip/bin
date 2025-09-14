#!/usr/bin/env bash
# pg17_config_one_shot.sh
# Version: v1.0.0 (2025-08-30)
# Zweck: PostgreSQL 17 (main) auf WSL/Ubuntu in einem Rutsch konfigurieren.
#  - listen_addresses='*'
#  - Port=5432 (oder autodetektiert aus pg_lsclusters)
#  - pg_hba.conf: local/host -> scram-sha-256 (Passwort-Login), 127.0.0.1/32 + ::1/128
#  - optional: Passwort für 'postgres' via PG17_PASSWORD
#  - Restart + Statusausgabe

set -Eeuo pipefail
IFS=$'\n\t'

need_root(){ [[ $EUID -eq 0 ]] || { echo "Bitte mit sudo ausführen."; exit 1; }; }
have(){ command -v "$1" >/dev/null 2>&1; }

need_root
for b in psql pg_lsclusters; do have "$b" || { echo "Benötigtes Tool fehlt: $b (sudo apt install postgresql-common)"; exit 1; }; done

# --- Konstanten/Autodetektion ---
VERSION=17
CLUSTER=main
CONF_DIR="/etc/postgresql/${VERSION}/${CLUSTER}"
PGCONF="${CONF_DIR}/postgresql.conf"
PG_HBA="${CONF_DIR}/pg_hba.conf"
UNIT="postgresql@${VERSION}-${CLUSTER}"

[[ -d "$CONF_DIR" ]] || { echo "Konfigpfad fehlt: $CONF_DIR — ist PostgreSQL ${VERSION} installiert?"; exit 1; }

# Port autodetektion aus pg_lsclusters, sonst 5432
PORT="$(pg_lsclusters | awk '$1==17 && $2=="main"{print $3}' || true)"
PORT="${PORT:-5432}"

# Backups
ts="$(date +%Y%m%d-%H%M%S)"
cp -a "$PGCONF" "${PGCONF}.bak.${ts}"
cp -a "$PG_HBA" "${PG_HBA}.bak.${ts}"

echo "→ Setze Basis-Parameter in postgresql.conf (listen_addresses='*', port=${PORT})"
if have pg_conftool; then
  pg_conftool ${VERSION} ${CLUSTER} set listen_addresses "'*'"
  pg_conftool ${VERSION} ${CLUSTER} set port "${PORT}"
  pg_conftool ${VERSION} ${CLUSTER} set password_encryption "scram-sha-256"
else
  # Fallback via sed
  grep -qE "^[#\s]*listen_addresses\s*=" "$PGCONF" \
    && sed -i "s|^[#\s]*listen_addresses\s*=.*|listen_addresses = '*'|g" "$PGCONF" \
    || echo "listen_addresses = '*'" >> "$PGCONF"
  grep -qE "^[#\s]*port\s*=" "$PGCONF" \
    && sed -i "s|^[#\s]*port\s*=.*|port = ${PORT}|g" "$PGCONF" \
    || echo "port = ${PORT}" >> "$PGCONF"
  grep -qE "^[#\s]*password_encryption\s*=" "$PGCONF" \
    && sed -i "s|^[#\s]*password_encryption\s*=.*|password_encryption = scram-sha-256|g" "$PGCONF" \
    || echo "password_encryption = scram-sha-256" >> "$PGCONF"
fi

echo "→ Härte pg_hba.conf ab: 'peer' → 'scram-sha-256' (local) + host-Regeln 127.0.0.1/::1"
# local-Zeilen auf scram umstellen (Socket-Login verlangt dann Passwort)
sed -E -i \
  -e 's/^(local[[:space:]]+all[[:space:]]+postgres[[:space:]]+).*/\1scram-sha-256/' \
  -e 's/^(local[[:space:]]+all[[:space:]]+all[[:space:]]+).*/\1scram-sha-256/' \
  "$PG_HBA"

# host 127.0.0.1/32 -> scram (ersetzen oder hinzufügen)
grep -qE "^[[:space:]]*host[[:space:]]+all[[:space:]]+all[[:space:]]+127\.0\.0\.1/32" "$PG_HBA" \
  && sed -E -i 's/^(.*host[[:space:]]+all[[:space:]]+all[[:space:]]+127\.0\.0\.1\/32[[:space:]]+).*/\1scram-sha-256/' "$PG_HBA" \
  || echo "host    all             all             127.0.0.1/32            scram-sha-256" >> "$PG_HBA"

# host ::1/128 -> scram (ersetzen oder hinzufügen)
grep -qE "^[[:space:]]*host[[:space:]]+all[[:space:]]+all[[:space:]]+::1/128" "$PG_HBA" \
  && sed -E -i 's/^(.*host[[:space:]]+all[[:space:]]+all[[:space:]]+::1\/128[[:space:]]+).*/\1scram-sha-256/' "$PG_HBA" \
  || echo "host    all             all             ::1/128                 scram-sha-256" >> "$PG_HBA"

# Optional: Passwort setzen, wenn PG17_PASSWORD gesetzt ist
if [[ "${PG17_PASSWORD:-}" != "" ]]; then
  echo "→ Setze Passwort für DB-User 'postgres' (SCRAM)"
  sudo -u postgres psql -v ON_ERROR_STOP=1 -d postgres -c "ALTER USER postgres WITH PASSWORD '${PG17_PASSWORD//\'/''}';"
fi

echo "→ Dienst neu starten: ${UNIT}"
systemctl restart "${UNIT}" 2>/dev/null || systemctl restart postgresql || service postgresql restart

echo "→ Status & Check"
pg_lsclusters || true
sudo -u postgres psql -d postgres -c "select version();" || true

echo "✅ Fertig. Passwort-Login testen (Beispiel):"
echo "  PGPASSWORD='***' psql -h 127.0.0.1 -p ${PORT} -U postgres -d postgres -c 'select now();'"
