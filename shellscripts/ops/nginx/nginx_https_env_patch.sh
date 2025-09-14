#!/usr/bin/env bash
set -euo pipefail

PROJECT_PATH="$HOME/code/tafel_wesseling"
ENV_FILE="$PROJECT_PATH/.env"
TIMESTAMP=$(date +%Y%m%d_%H%M%S")
BACKUP="${ENV_FILE}.${TIMESTAMP}.bak"

# Backup erstellen
cp "$ENV_FILE" "$BACKUP"
echo "Backup erstellt: $BACKUP"

# Ergänzen oder ersetzen
if grep -q '^VITE_DEV_SERVER_URL=' "$ENV_FILE"; then
  sed -i 's|^VITE_DEV_SERVER_URL=.*|VITE_DEV_SERVER_URL=https://localhost:5173|' "$ENV_FILE"
  echo "VITE_DEV_SERVER_URL aktualisiert in .env"
else
  echo "VITE_DEV_SERVER_URL=https://localhost:5173" >> "$ENV_FILE"
  echo "VITE_DEV_SERVER_URL hinzugefügt in .env"
fi

# Hinweis zur config-cache
echo "Bitte danach 'php artisan config:clear' ausführen, falls du config:cache nutzt."
