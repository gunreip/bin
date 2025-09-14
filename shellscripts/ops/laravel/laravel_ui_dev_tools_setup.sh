#!/bin/bash
set -e

while [[ "$#" -gt 0 ]]; do
    case $1 in
        -p) PROJECT_PATH="$2"; shift ;;
        *) echo "Unbekannter Parameter: $1"; exit 1 ;;
    esac
    shift
done

if [[ -z "$PROJECT_PATH" ]]; then
    echo "❌ Projektpfad fehlt. Aufruf: $0 -p <project_path>"
    exit 1
fi

cd "$PROJECT_PATH"

if [[ ! -f "composer.json" ]] || [[ ! -f "artisan" ]]; then
    echo "❌ Kein Laravel-Projekt gefunden in $PROJECT_PATH"
    exit 1
fi

composer require --dev barryvdh/laravel-debugbar laravel/pint nunomaduro/larastan itsgoingd/clockwork

if [[ ! -f phpstan.neon.dist ]]; then
cat > phpstan.neon.dist <<EOF
includes:
  - ./vendor/nunomaduro/larastan/extension.neon

parameters:
  level: 5
  paths:
    - app
EOF
fi

if [[ ! -f config/debugbar.php ]]; then
    php artisan vendor:publish --provider="Barryvdh\Debugbar\ServiceProvider" --tag=config
fi

php artisan optimize:clear

echo "✅ laravel_ui_dev_tools_setup abgeschlossen."
