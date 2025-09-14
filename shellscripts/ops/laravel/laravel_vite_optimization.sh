#!/bin/bash
set -e

# Defaultwerte
LIMIT=1500
BUILD=true

while [[ "$#" -gt 0 ]]; do
    case $1 in
        -p) PROJECT_PATH="$2"; shift ;;
        --limit) LIMIT="$2"; shift ;;
        --no-build) BUILD=false ;;
        *) echo "Unbekannter Parameter: $1"; exit 1 ;;
    esac
    shift
done

if [[ -z "$PROJECT_PATH" ]]; then
    echo "❌ Projektpfad fehlt. Aufruf: $0 -p <project_path> [--limit <mb>] [--no-build]"
    exit 1
fi

cd "$PROJECT_PATH"

if [[ ! -f "package.json" ]]; then
    echo "❌ Keine package.json gefunden in $PROJECT_PATH"
    exit 1
fi

BACKUP_NAME="vite.config.js.bak-$(date +%Y%m%d-%H%M%S)"
[[ -f vite.config.js ]] && cp vite.config.js "$BACKUP_NAME"

cat > vite.config.js <<EOF
import { defineConfig } from 'vite';
import laravel from 'laravel-vite-plugin';

export default defineConfig({
    plugins: [laravel()],
    build: {
        chunkSizeWarningLimit: $LIMIT,
        rollupOptions: {
            output: {
                manualChunks: {
                    lucide: ['lucide'],
                    vendor: ['axios', 'lodash']
                }
            }
        }
    }
});
EOF

if $BUILD; then
    echo "📦 Starte Build-Vorgang..."
    timeout 600 bash -c "npm install && npm run build"
    if [[ $? -ne 0 ]]; then
        echo "❌ Build fehlgeschlagen oder Zeitüberschreitung."
        exit 1
    fi
fi

echo "✅ vite_optimization abgeschlossen."
