#!/usr/bin/env bash
set -euo pipefail
SCRIPT_VERSION="v1.0.1"

PROJECT_PATH=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p) PROJECT_PATH="${2:-}"; shift 2 ;;
    --version) echo "healthz_install.sh $SCRIPT_VERSION"; exit 0 ;;
    *) echo "Unbekannter Parameter: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "${PROJECT_PATH}" ]]; then PROJECT_PATH="$(pwd)"; fi
if [[ ! -d "$PROJECT_PATH" ]]; then echo "❌ Projektpfad nicht gefunden: $PROJECT_PATH" >&2; exit 2; fi

ROUTES_DIR="$PROJECT_PATH/routes"
PUBLIC_DIR="$PROJECT_PATH/public"
WIKI_NGX_DIR="$PROJECT_PATH/.wiki/nginx"
mkdir -p "$ROUTES_DIR" "$PUBLIC_DIR" "$WIKI_NGX_DIR"

# routes/healthz.php
cat > "$ROUTES_DIR/healthz.php" <<'PHP'
<?php

use Illuminate\Http\Request;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Route;

Route::get('/healthz', function (Request $request) {
    $deep = filter_var($request->query('deep'), FILTER_VALIDATE_BOOLEAN);

    $status = ['ok' => true, 'checks' => ['liveness' => 'ok'], 'ts' => now()->toIso8601String()];

    if ($deep) {
        try {
            DB::connection()->getPdo();
            $status['checks']['db'] = 'ok';
        } catch (\Throwable $e) {
            $status['ok'] = false;
            $status['checks']['db'] = 'fail';
        }

        try {
            Cache::put('__healthz', 'ok', 60);
            $status['checks']['cache'] = Cache::get('__healthz') === 'ok' ? 'ok' : 'fail';
            if ($status['checks']['cache'] !== 'ok') $status['ok'] = false;
        } catch (\Throwable $e) {
            $status['ok'] = false;
            $status['checks']['cache'] = 'fail';
        }
    }

    return response()->json($status, $status['ok'] ? 200 : 503);
});
PHP

# public/healthz.php (fast path, ohne Laravel)
cat > "$PUBLIC_DIR/healthz.php" <<'PHP'
<?php
http_response_code(200);
header('Content-Type: text/plain; charset=utf-8');
echo "OK
";
PHP

# Nginx-Snippet Vorlage
cat > "$WIKI_NGX_DIR/healthz.conf" <<'NGINX'
# /healthz bevorzugt die schnelle PHP-Datei (fällt auf Laravel zurück)
location = /healthz {
    try_files /healthz.php /index.php?$query_string;
}
NGINX

# routes/web.php um require ergänzen (idempotent)
WEB_ROUTES="$ROUTES_DIR/web.php"
if [[ -f "$WEB_ROUTES" ]]; then
  if ! grep -q "routes/healthz.php" "$WEB_ROUTES"; then
    printf "\n// healthz route\nif (file_exists(base_path('routes/healthz.php'))) { require base_path('routes/healthz.php'); }\n" >> "$WEB_ROUTES"
  fi
fi

echo "✅ healthz installiert:"
echo "   - $PROJECT_PATH/routes/healthz.php"
echo "   - $PROJECT_PATH/public/healthz.php"
echo "   - $PROJECT_PATH/.wiki/nginx/healthz.conf (Vorlage)"
echo "ℹ️  Route: /healthz  (mit ?deep=1 für DB/Cache-Check)"
