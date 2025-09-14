#!/usr/bin/env bash
set -euo pipefail

# PostgreSQL Konfigurations-Script für WSL/Ubuntu
# - Setzt listen_addresses = '*'
# - Setzt optional den Port
# - Ergänzt pg_hba.conf um sichere md5-Regeln (127.0.0.1, ::1 und optionale Subnetze)
# - Setzt optional ein Passwort für den 'postgres'-Benutzer
# - Restartet und aktiviert postgresql@<version>-main
#
# Verwendung:
#   sudo ./configure_postgresql.sh [-v 16] [-P 5432] [-a] [-s CIDR]... [-w PASSWORT] [--no-restart]
#
# Optionen:
#   -v, --version <N>     PostgreSQL-Version (Standard: 16)
#   -P, --port <PORT>     TCP-Port (Standard: 5432)
#   -s, --subnet <CIDR>   Zusätzlich erlaubtes IPv4-Netz (z. B. 192.168.178.0/24). Mehrfach nutzbar.
#   -a, --allow-all       Fügt 0.0.0.0/0 hinzu (nicht empfohlen, nur für isolierte Dev-Umgebungen).
#   -w, --password <PWD>  Setzt Passwort für Benutzer 'postgres'.
#       --no-restart      Dienst nicht neu starten (nur Dateien anpassen).
#   -h, --help            Hilfe anzeigen.
#
# Beispiele:
#   sudo ./configure_postgresql.sh -w "SehrSicher123!"
#   sudo ./configure_postgresql.sh -s 192.168.178.0/24 -w "pw" -P 5433
#
VERSION=16
PORT=5432
SUBNETS=()
ALLOW_ALL=0
PASSWORD=""
DO_RESTART=1

print_help() {
  sed -n '1,60p' "$0" | sed 's/^# \{0,1\}//'
}

# Argumente parsen
while [[ $# -gt 0 ]]; do
  case "$1" in
    -v|--version)
      VERSION="$2"; shift 2;;
    -P|--port)
      PORT="$2"; shift 2;;
    -s|--subnet)
      SUBNETS+=("$2"); shift 2;;
    -a|--allow-all)
      ALLOW_ALL=1; shift;;
    -w|--password)
      PASSWORD="$2"; shift 2;;
    --no-restart)
      DO_RESTART=0; shift;;
    -h|--help)
      print_help; exit 0;;
    *)
      echo "Unbekannte Option: $1"; print_help; exit 1;;
  esac
done

CONF_DIR="/etc/postgresql/${VERSION}/main"
PG_HBA="${CONF_DIR}/pg_hba.conf"
PGCONF="${CONF_DIR}/postgresql.conf"
UNIT="postgresql@${VERSION}-main"

if [[ $EUID -ne 0 ]]; then
  echo "Bitte mit sudo ausführen."; exit 1
fi

if [[ ! -d "$CONF_DIR" ]]; then
  echo "Konfigurationsordner ${CONF_DIR} existiert nicht. Ist PostgreSQL ${VERSION} installiert?"
  exit 1
fi

# Backups
ts=$(date +%Y%m%d-%H%M%S)
cp -a "$PG_HBA" "${PG_HBA}.bak.${ts}"
cp -a "$PGCONF" "${PGCONF}.bak.${ts}"

echo "→ postgresql.conf anpassen (listen_addresses, port)"
# listen_addresses setzen (vorhandene auskommentierte/gesetzte Zeilen behandeln)
if grep -qE "^[#\s]*listen_addresses\s*=" "$PGCONF"; then
  sed -i "s|^[#\s]*listen_addresses\s*=.*|listen_addresses = '*'|g" "$PGCONF"
else
  echo "listen_addresses = '*'" >> "$PGCONF"
fi

# port setzen
if grep -qE "^[#\s]*port\s*=" "$PGCONF"; then
  sed -i "s|^[#\s]*port\s*=.*|port = ${PORT}|g" "$PGCONF"
else
  echo "port = ${PORT}" >> "$PGCONF"
fi

echo "→ pg_hba.conf Regeln hinzufügen"
# Doppelte Einträge vermeiden: vorhandene Zeilen zu 127.0.0.1/32 & ::1/128 auf md5 setzen, sonst hinzufügen
if grep -qE "^[\t ]*host[\t ]+all[\t ]+all[\t ]+127\.0\.0\.1/32" "$PG_HBA"; then
  sed -i "s|^\([\t ]*host[\t ]\+all[\t ]\+all[\t ]\+127\.0\.0\.1/32[\t ]\+\).*|\1md5|g" "$PG_HBA"
else
  echo "host    all             all             127.0.0.1/32            md5" >> "$PG_HBA"
fi
if grep -qE "^[\t ]*host[\t ]+all[\t ]+all[\t ]+::1/128" "$PG_HBA"; then
  sed -i "s|^\([\t ]*host[\t ]\+all[\t ]\+all[\t ]\+::1/128[\t ]\+\).*|\1md5|g" "$PG_HBA"
else
  echo "host    all             all             ::1/128                 md5" >> "$PG_HBA"
fi

# Weitere Subnetze
for net in "${SUBNETS[@]}"; do
  if ! grep -qE "^[\t ]*host[\t ]+all[\t ]+all[\t ]+${net//\//\\/}(\s|$)" "$PG_HBA"; then
    echo "host    all             all             ${net}                 md5" >> "$PG_HBA"
  fi
done

# 0.0.0.0/0 nur auf Wunsch
if [[ "$ALLOW_ALL" -eq 1 ]]; then
  if ! grep -qE "^[\t ]*host[\t ]+all[\t ]+all[\t ]+0\.0\.0\.0/0(\s|$)" "$PG_HBA"; then
    echo "host    all             all             0.0.0.0/0              md5" >> "$PG_HBA"
  fi
fi

# Passwort setzen
if [[ -n "$PASSWORD" ]]; then
  echo "→ Passwort für Benutzer 'postgres' setzen"
  sudo -u postgres psql -v ON_ERROR_STOP=1 <<SQL
ALTER USER postgres WITH PASSWORD '${PASSWORD}';
SQL
fi

# Dienst neu starten/aktivieren
if [[ "$DO_RESTART" -eq 1 ]]; then
  echo "→ Dienst neu starten: ${UNIT}"
  systemctl restart "${UNIT}"
  systemctl enable "${UNIT}" >/dev/null 2>&1 || true
  echo "→ Status:"
  systemctl --no-pager --full status "${UNIT}" || true
  echo "→ Cluster:"
  pg_lsclusters || true
else
  echo "Hinweis: --no-restart gesetzt. Bitte Dienst manuell neu starten: systemctl restart ${UNIT}"
fi

echo "✅ Fertig. Du kannst dich z. B. so verbinden: psql -h 127.0.0.1 -p ${PORT} -U postgres"
