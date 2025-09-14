#!/usr/bin/env bash
set -euo pipefail

PROJECT_PATH=""
WWW_USER="www-data"
WWW_GROUP="www-data"

usage(){ echo "Usage: sudo $0 -p <project_path> [-U <www_user>] [-G <www_group>]"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p) PROJECT_PATH="$2"; shift 2;;
    -U) WWW_USER="$2"; shift 2;;
    -G) WWW_GROUP="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "Unbekannte Option: $1"; usage; exit 1;;
  esac
done

[[ -z "$PROJECT_PATH" ]] && { usage; exit 1; }

chown -R "$USER":"$USER" "$PROJECT_PATH"
chgrp -R "$WWW_GROUP" "$PROJECT_PATH"/storage "$PROJECT_PATH"/bootstrap/cache || true
chmod -R ug+rwX "$PROJECT_PATH"/storage "$PROJECT_PATH"/bootstrap/cache

# Wenn setfacl verfügbar, feiner einstellen:
if command -v setfacl >/dev/null; then
  setfacl -R -m u:${WWW_USER}:rwX -m u:${USER}:rwX "$PROJECT_PATH"/storage "$PROJECT_PATH"/bootstrap/cache || true
  setfacl -dR -m u:${WWW_USER}:rwX -m u:${USER}:rwX "$PROJECT_PATH"/storage "$PROJECT_PATH"/bootstrap/cache || true
fi

echo "✅ Berechtigungen gesetzt für ${PROJECT_PATH}"
