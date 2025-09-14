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

php artisan migrate || true
php artisan config:cache || true
php artisan route:cache || true
php artisan view:cache || true

echo "✅ Migration & Caches erledigt."
