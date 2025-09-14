#!/bin/bash

echo "🚧 PostgreSQL 16 wird vollständig entfernt und neu installiert..."

# PostgreSQL stoppen und entfernen
sudo systemctl stop postgresql
sudo apt purge -y postgresql-16 postgresql-client-16 postgresql-common
sudo rm -rf /var/lib/postgresql/16 /etc/postgresql/16 /var/log/postgresql
sudo apt autoremove -y
sudo apt autoclean

# PostgreSQL 16 neu installieren
echo "📦 Installation von PostgreSQL 16..."
sudo apt update
sudo apt install -y postgresql-16

# Cluster initialisieren
echo "🚀 Initialisierung des Clusters..."
sudo pg_createcluster 16 main --start

# Status prüfen
echo "🔍 PostgreSQL-Status:"
sudo systemctl status postgresql@16-main --no-pager

# Testverbindung
echo "🔗 Verbindungstest:"
sudo -u postgres psql -c "\l"

echo "✅ PostgreSQL 16 wurde erfolgreich neu installiert und gestartet."
