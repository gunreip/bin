#!/usr/bin/env bash
set -euo pipefail

PROJECT_PATH=""
usage(){ echo "Usage: $0 -p <project_path>"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p) PROJECT_PATH="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "Unbekannte Option: $1"; usage; exit 1;;
  esac
done

[[ -z "$PROJECT_PATH" ]] && { usage; exit 1; }
cd "$PROJECT_PATH"

[[ -f .env ]] || cp .env.example .env

php artisan key:generate || true
php artisan storage:link || true

# Laravel-typische Dev-Optimierungen
php artisan config:clear || true
php artisan route:clear || true
php artisan view:clear || true

echo "✅ .env/Key/Storage-Link erledigt für $PROJECT_PATH"
