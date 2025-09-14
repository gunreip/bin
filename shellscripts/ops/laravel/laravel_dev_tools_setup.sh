#!/bin/bash
set -euo pipefail

PROJECT_PATH=""

while getopts "p:" opt; do
  case $opt in
    p) PROJECT_PATH=$OPTARG ;;
    *) echo "Usage: $0 -p <project_path>" ; exit 1 ;;
  esac
done

if [[ -z "$PROJECT_PATH" ]]; then
  echo "❌ Bitte -p <project_path> angeben (z. B. ~/code/tafel_wesseling)"
  exit 1
fi

if [[ ! -d "$PROJECT_PATH" ]]; then
  echo "❌ Verzeichnis $PROJECT_PATH existiert nicht"
  exit 1
fi

cd "$PROJECT_PATH"

echo "📦 Installiere Laravel Dev-Tools..."

# Laravel Debugbar
composer require --dev barryvdh/laravel-debugbar

# Laravel Pint
composer require --dev laravel/pint

# Larastan (PHPStan für Laravel)
composer require --dev nunomaduro/larastan

# Clockwork (Performance Profiling)
composer require --dev itsgoingd/clockwork

echo "✅ Dev-Tools erfolgreich installiert:"
echo "   - Laravel Debugbar"
echo "   - Laravel Pint"
echo "   - Larastan"
echo "   - Clockwork"

echo "👉 Debugbar ist automatisch aktiv in local/dev."
echo "👉 Pint: ./vendor/bin/pint"
echo "👉 Larastan: ./vendor/bin/phpstan analyse"
echo "👉 Clockwork: Browser-Extension installieren (optional)."
