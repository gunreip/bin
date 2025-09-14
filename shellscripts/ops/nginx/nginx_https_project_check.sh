#!/usr/bin/env bash
set -euo pipefail

SCRIPT_VERSION="v1.0.0"

PROJECT_PATH=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p) PROJECT_PATH="$2"; shift 2;;
    --version) echo "$SCRIPT_VERSION"; exit 0;;
    -h|--help) echo "Usage: $0 -p <project_path>"; exit 0;;
    *) echo "Unbekannte Option: $1"; exit 1;;
  esac
done

[[ -z "$PROJECT_PATH" ]] && { echo "❌ Projektpfad fehlt (-p)!" >&2; exit 1; }
cd "$PROJECT_PATH"

echo "🔍 Prüfe HTTPS-Konfiguration in: $PROJECT_PATH"

echo -n "→ APP_URL in .env: "
grep '^APP_URL=' .env | cut -d '=' -f2- || echo "⚠️ Nicht gefunden"

echo -n "→ VITE_DEV_SERVER_URL in .env oder .env.local: "
grep '^VITE_DEV_SERVER_URL=' .env .env.local 2>/dev/null | cut -d '=' -f2- || echo "⚠️ Nicht gefunden"

echo -n "→ forceScheme() in AppServiceProvider: "
grep 'forceScheme.*https' app/Providers/AppServiceProvider.php && echo "✔️" || echo "⚠️ Nicht gefunden"

echo -n "→ X-Forwarded-Proto in Nginx-Config (manuell prüfen): "
echo "⚠️ Bitte manuell verifizieren"

echo -n "→ Trusted Proxies Middleware vorhanden: "
[[ -f app/Http/Middleware/TrustProxies.php ]] && echo "✔️" || echo "⚠️ Fehlt"

echo "✅ Prüfung abgeschlossen"
