#!/bin/bash
set -euo pipefail

PROJECT_PATH=""
DO_BUILD=0

usage() {
  echo "Usage: $0 -p <project_path> [-b]"
  exit 1
}

while getopts "p:b" opt; do
  case $opt in
    p) PROJECT_PATH="$OPTARG" ;;
    b) DO_BUILD=1 ;;
    *) usage ;;
  esac
done

if [[ -z "${PROJECT_PATH}" ]]; then
  usage
fi

if [[ ! -d "${PROJECT_PATH}" ]]; then
  echo "❌ Projektpfad nicht gefunden: ${PROJECT_PATH}"
  exit 2
fi

cd "${PROJECT_PATH}"

# 1) Checks
echo "📦 Prüfe Node & npm..."
if ! command -v node >/dev/null 2>&1; then
  echo "❌ 'node' nicht gefunden. Bitte Node.js installieren (z. B. via nvm)."
  exit 3
fi
if ! command -v npm >/dev/null 2>&1; then
  echo "❌ 'npm' nicht gefunden. Bitte npm installieren."
  exit 4
fi
echo "   node: $(node -v) | npm: $(npm -v)"

# Muss Laravel-Projekt sein
if [[ ! -f artisan ]]; then
  echo "❌ '${PROJECT_PATH}' scheint kein Laravel-Projekt zu sein (artisan fehlt)."
  exit 5
fi

# 2) Paketinstallation (Tailwind v3, PostCSS, Autoprefixer, daisyUI, Lucide)
echo "🧹 Bereinige evtl. Tailwind v4/CLI Reste (falls vorhanden)..."
# Ziel: keine Abbrüche, nur best-effort
npm pkg delete devDependencies.@tailwindcss/cli >/dev/null 2>&1 || true

echo "🧩 Installiere Frontend-Pakete (Tailwind v3, PostCSS, Autoprefixer, daisyUI, Lucide)..."
# Stelle sicher, dass package.json existiert
test -f package.json || { echo "❌ package.json fehlt"; exit 6; }

# Installiere/aktualisiere devDependencies idempotent
npm i -D tailwindcss@^3 postcss@^8 autoprefixer@^10 daisyui@^4 >/dev/null

# Lucide (normal dependency)
npm i lucide >/dev/null

# 3) Tailwind/PostCSS Dateien schreiben (ohne CLI-Aufruf)
echo "🛠️  Tailwind/PostCSS Dateien schreiben..."
# tailwind.config.js
if [[ ! -f tailwind.config.js ]]; then
  cat > tailwind.config.js <<'TWCFG'
/** @type {import('tailwindcss').Config} */
module.exports = {
  content: [
    "./resources/**/*.blade.php",
    "./resources/**/*.js",
    "./resources/**/*.vue",
    "./resources/**/*.ts",
  ],
  theme: {
    extend: {},
  },
  plugins: [
    require('daisyui'),
  ],
};
TWCFG
else
  # wenn existiert, ensure content + plugin (ohne fragile sed Magie -> append hint)
  if ! grep -q "daisyui" tailwind.config.js; then
    echo "// HINWEIS: daisyui Plugin noch nicht in tailwind.config.js eingetragen." >&2
  fi
fi

# postcss.config.js
if [[ ! -f postcss.config.js ]]; then
  cat > postcss.config.js <<'PCCFG'
module.exports = {
  plugins: {
    tailwindcss: {},
    autoprefixer: {},
  },
}
PCCFG
fi

# resources/css/app.css
mkdir -p resources/css
if [[ ! -f resources/css/app.css ]]; then
  cat > resources/css/app.css <<'CSS'
@tailwind base;
@tailwind components;
@tailwind utilities;
CSS
fi

# resources/js/app.js (Lucide init)
mkdir -p resources/js
touch resources/js/app.js
if ! grep -q "lucide" resources/js/app.js; then
  cat >> resources/js/app.js <<'JS'

// Lucide Icons initialisieren
import { createIcons, icons } from 'lucide';
document.addEventListener('DOMContentLoaded', () => {
  try { createIcons({ icons }); } catch (e) { console.warn('Lucide init warn:', e); }
});
JS
fi

# 4) Vite Grundkonfiguration prüfen/erstellen
echo "🧪 Vite Grund-Check..."
if [[ ! -f vite.config.js ]]; then
  # Standard Laravel Vite Konfig erzeugen
  npm i -D vite laravel-vite-plugin >/dev/null
  cat > vite.config.js <<'VITECFG'
import { defineConfig } from 'vite';
import laravel from 'laravel-vite-plugin';

export default defineConfig({
    plugins: [
        laravel({
            input: ['resources/css/app.css', 'resources/js/app.js'],
            refresh: true,
        }),
    ],
});
VITECFG
else
  # ensure laravel-vite-plugin present
  if ! grep -q "laravel-vite-plugin" vite.config.js; then
    npm i -D laravel-vite-plugin vite >/dev/null
  fi
fi

# 5) Scripts sicherstellen
node -e "let p=require('./package.json');p.scripts=p.scripts||{}; if(!p.scripts.dev) p.scripts.dev='vite'; if(!p.scripts.build) p.scripts.build='vite build'; require('fs').writeFileSync('package.json', JSON.stringify(p,null,2));"

# 6) Install (mit Timeout, ohne interaktive Prompts)
echo "📦 npm install (kann einen Moment dauern)..."
INSTALL_CMD="npm install --no-audit --no-fund"
# nutze timeout, aber nicht unterbrechen wenn timeout fehlt
if command -v timeout >/dev/null 2>&1; then
  timeout 600s bash -c "${INSTALL_CMD}"
else
  bash -c "${INSTALL_CMD}"
fi

# 7) Optional Build
if [[ ${DO_BUILD} -eq 1 ]]; then
  echo "🏗️  npm run build..."
  BUILD_CMD="npm run build"
  if command -v timeout >/dev/null 2>&1; then
    timeout 900s bash -c "${BUILD_CMD}"
  else
    bash -c "${BUILD_CMD}"
  fi
fi

echo "✅ UI-Setup abgeschlossen."
