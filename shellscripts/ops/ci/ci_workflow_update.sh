#!/usr/bin/env bash
# ci_workflow_update.sh — Backup bestehender CI und Schreiben neuer .github/workflows/ci.yml
# Läuft NUR im Projekt-Working-Dir (Gatekeeper: .env)
# Version: v1.0.0

set -euo pipefail
VERSION="v1.0.0"

print_help() {
  cat <<'HLP'
ci_workflow_update.sh — Backup bestehender CI und Schreiben neuer .github/workflows/ci.yml

USAGE
  ci_workflow_update.sh [--dry-run] [--no-db] [--help] [--version]

OPTIONEN
  --dry-run   Nur anzeigen, was gemacht würde (keine Änderungen)
  --no-db     CI ohne Postgres-Service, ohne "wait for Postgres" und ohne "migrate"
  -h, --help  Hilfe
  --version   Version ausgeben

HINWEISE
  • Skript MUSS im Projekt-Root laufen (Gatekeeper: .env muss vorhanden sein).
  • Bestehende ci.yml wird nach .github/workflows/.backup/ci.yml.<TS>.bak verschoben.
HLP
}

DRY=0
INCLUDE_DB=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY=1; shift;;
    --no-db)   INCLUDE_DB=0; shift;;
    --version) echo "$VERSION"; exit 0;;
    -h|--help) print_help; exit 0;;
    *) echo "Unbekannter Parameter: $1" >&2; print_help; exit 1;;
  esac
done

[[ -f .env ]] || { echo "Fehler: .env fehlt. Bitte im Projekt-Root ausführen." >&2; exit 2; }

WF_DIR=".github/workflows"
BACKUP_DIR="${WF_DIR}/.backup"
TARGET="${WF_DIR}/ci.yml"
TS="$(date +%Y%m%d_%H%M%S)"

run() { if [[ $DRY -eq 1 ]]; then echo "[DRY] $*"; else eval "$@"; fi; }

run "mkdir -p '${WF_DIR}' '${BACKUP_DIR}'"

if [[ -f "${TARGET}" ]]; then
  BK="${BACKUP_DIR}/ci.yml.${TS}.bak"
  run "mv '${TARGET}' '${BK}'"
  echo "Backup: ${BK}"
fi

if [[ $INCLUDE_DB -eq 1 ]]; then
  if [[ $DRY -eq 1 ]]; then
    echo "[DRY] würde schreiben: ${TARGET} (Variante: MIT DB)"
  else
    cat > "${TARGET}" <<'YAML'
name: CI

on:
  push:
    branches: [ main ]
  pull_request:
    branches: [ main ]
  workflow_dispatch:

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

permissions:
  contents: read

jobs:
  test:
    name: test
    runs-on: ubuntu-latest

    services:
      postgres:
        image: postgres:16-alpine
        env:
          POSTGRES_DB: testing
          POSTGRES_USER: postgres
          POSTGRES_PASSWORD: postgres
        ports: ["5432:5432"]
        options: >-
          --health-cmd="pg_isready -U postgres"
          --health-interval=10s
          --health-timeout=5s
          --health-retries=5

    steps:
      - name: Checkout
        uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Setup PHP
        uses: shivammathur/setup-php@v2
        with:
          php-version: '8.3'
          extensions: mbstring, intl, bcmath, gd, pdo_pgsql, pcntl
          coverage: none

      - name: Cache Composer
        uses: actions/cache@v4
        with:
          path: ~/.cache/composer
          key: composer-${{ runner.os }}-${{ hashFiles('**/composer.lock') }}
          restore-keys: composer-${{ runner.os }}-

      - name: Install PHP dependencies
        run: composer install --no-ansi --no-interaction --no-progress --prefer-dist

      - name: Prepare .env + APP_KEY
        run: |
          cp -n .env.example .env || true
          php artisan key:generate --force
        env:
          APP_ENV: testing

      - name: Wait for Postgres
        run: |
          for i in {1..30}; do
            if pg_isready -h 127.0.0.1 -p 5432 -U postgres; then exit 0; fi
            sleep 1
          done
          echo "Postgres not ready" >&2; exit 1

      - name: Migrate database
        run: php artisan migrate --no-interaction -vvv
        env:
          DB_CONNECTION: pgsql
          DB_HOST: 127.0.0.1
          DB_PORT: 5432
          DB_DATABASE: testing
          DB_USERNAME: postgres
          DB_PASSWORD: postgres

      - name: Run tests (Pest/PHPUnit)
        run: |
          if [ -x vendor/bin/pest ]; then
            vendor/bin/pest --ci
          else
            vendor/bin/phpunit --colors=never
          fi
        env:
          APP_ENV: testing
          DB_CONNECTION: pgsql
          DB_HOST: 127.0.0.1
          DB_PORT: 5432
          DB_DATABASE: testing
          DB_USERNAME: postgres
          DB_PASSWORD: postgres

  phpstan:
    name: phpstan
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }
      - uses: shivammathur/setup-php@v2
        with:
          php-version: '8.3'
          tools: phpstan
          coverage: none
      - name: Cache Composer
        uses: actions/cache@v4
        with:
          path: ~/.cache/composer
          key: composer-${{ runner.os }}-${{ hashFiles('**/composer.lock') }}
          restore-keys: composer-${{ runner.os }}-
      - name: Install PHP dependencies
        run: composer install --no-ansi --no-interaction --no-progress --prefer-dist
      - name: Run PHPStan
        run: |
          if [ -x vendor/bin/phpstan ]; then
            vendor/bin/phpstan analyse --no-progress --memory-limit=1G
          else
            phpstan analyse --no-progress --memory-limit=1G
          fi

  pint:
    name: pint
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }
      - uses: shivammathur/setup-php@v2
        with:
          php-version: '8.3'
          tools: composer
          coverage: none
      - name: Cache Composer
        uses: actions/cache@v4
        with:
          path: ~/.cache/composer
          key: composer-${{ runner.os }}-${{ hashFiles('**/composer.lock') }}
          restore-keys: composer-${{ runner.os }}-
      - name: Install PHP dependencies
        run: composer install --no-ansi --no-interaction --no-progress --prefer-dist
      - name: Laravel Pint (verify)
        run: |
          if [ -x vendor/bin/pint ]; then
            vendor/bin/pint --test
          else
            composer global require laravel/pint
            ~/.composer/vendor/bin/pint --test
          fi
YAML
    echo "Neue CI geschrieben: ${TARGET}"
  fi
else
  if [[ $DRY -eq 1 ]]; then
    echo "[DRY] würde schreiben: ${TARGET} (Variante: OHNE DB)"
  else
    cat > "${TARGET}" <<'YAML'
name: CI

on:
  push:
    branches: [ main ]
  pull_request:
    branches: [ main ]
  workflow_dispatch:

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

permissions:
  contents: read

jobs:
  test:
    name: test
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }
      - uses: shivammathur/setup-php@v2
        with:
          php-version: '8.3'
          extensions: mbstring, intl, bcmath, gd, pcntl
          coverage: none
      - name: Cache Composer
        uses: actions/cache@v4
        with:
          path: ~/.cache/composer
          key: composer-${{ runner.os }}-${{ hashFiles('**/composer.lock') }}
          restore-keys: composer-${{ runner.os }}-
      - name: Install PHP dependencies
        run: composer install --no-ansi --no-interaction --no-progress --prefer-dist
      - name: Prepare .env + APP_KEY
        run: |
          cp -n .env.example .env || true
          php artisan key:generate --force
        env:
          APP_ENV: testing
      - name: Run tests (Pest/PHPUnit)
        run: |
          if [ -x vendor/bin/pest ]; then
            vendor/bin/pest --ci
          else
            vendor/bin/phpunit --colors=never
          fi
        env:
          APP_ENV: testing

  phpstan:
    name: phpstan
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }
      - uses: shivammathur/setup-php@v2
        with:
          php-version: '8.3'
          tools: phpstan
          coverage: none
      - name: Cache Composer
        uses: actions/cache@v4
        with:
          path: ~/.cache/composer
          key: composer-${{ runner.os }}-${{ hashFiles('**/composer.lock') }}
          restore-keys: composer-${{ runner.os }}-
      - name: Install PHP dependencies
        run: composer install --no-ansi --no-interaction --no-progress --prefer-dist
      - name: Run PHPStan
        run: |
          if [ -x vendor/bin/phpstan ]; then
            vendor/bin/phpstan analyse --no-progress --memory-limit=1G
          else
            phpstan analyse --no-progress --memory-limit=1G
          fi

  pint:
    name: pint
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }
      - uses: shivammathur/setup-php@v2
        with:
          php-version: '8.3'
          tools: composer
          coverage: none
      - name: Cache Composer
        uses: actions/cache@v4
        with:
          path: ~/.cache/composer
          key: composer-${{ runner.os }}-${{ hashFiles('**/composer.lock') }}
          restore-keys: composer-${{ runner.os }}-
      - name: Install PHP dependencies
        run: composer install --no-ansi --no-interaction --no-progress --prefer-dist
      - name: Laravel Pint (verify)
        run: |
          if [ -x vendor/bin/pint ]; then
            vendor/bin/pint --test
          else
            composer global require laravel/pint
            ~/.composer/vendor/bin/pint --test
          fi
YAML
    echo "Neue CI geschrieben: ${TARGET}"
  fi
fi

echo "Fertig."
