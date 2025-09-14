#!/bin/bash
set -e

COMPOSER=false
MIGRATE=true
BUILD=true
DOWN=true
UP=true

while [[ "$#" -gt 0 ]]; do
    case $1 in
        -p) PROJECT_PATH="$2"; shift ;;
        --composer) COMPOSER=true ;;
        --no-migrate) MIGRATE=false ;;
        --no-build) BUILD=false ;;
        --no-down) DOWN=false ;;
        --no-up) UP=false ;;
        *) echo "Unbekannter Parameter: $1"; exit 1 ;;
    esac
    shift
done

cd "$PROJECT_PATH"

$DOWN && php artisan down || echo "⚠️ Wartungsmodus übersprungen"

$COMPOSER && composer install --no-dev --prefer-dist --optimize-autoloader

php artisan optimize:clear

$MIGRATE && php artisan migrate --force || echo "⚠️ Migration übersprungen"

php artisan config:cache
php artisan route:cache
php artisan view:cache

if $BUILD; then
    npm ci || npm install
    npm run build
else
    echo "⚠️ Build übersprungen"
fi

$UP && php artisan up || echo "⚠️ Wartungsmodus beibehalten"

echo "✅ Deploy abgeschlossen."
