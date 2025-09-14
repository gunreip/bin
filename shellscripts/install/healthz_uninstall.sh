#!/usr/bin/env bash
set -euo pipefail
SCRIPT_VERSION="v1.0.1"

PROJECT_PATH=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p) PROJECT_PATH="${2:-}"; shift 2 ;;
    --version) echo "healthz_uninstall.sh $SCRIPT_VERSION"; exit 0 ;;
    *) echo "Unbekannter Parameter: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "${PROJECT_PATH}" ]]; then PROJECT_PATH="$(pwd)"; fi
[[ -d "$PROJECT_PATH" ]] || { echo "❌ Projektpfad nicht gefunden: $PROJECT_PATH" >&2; exit 2; }

rm -f "$PROJECT_PATH/routes/healthz.php" "$PROJECT_PATH/public/healthz.php"

WEB_ROUTES="$PROJECT_PATH/routes/web.php"
if [[ -f "$WEB_ROUTES" ]]; then
  tmp=$(mktemp)
  grep -v "routes/healthz.php" "$WEB_ROUTES" > "$tmp" || true
  mv "$tmp" "$WEB_ROUTES"
fi

echo "✅ healthz entfernt (Dateien gelöscht, web.php bereinigt)"
