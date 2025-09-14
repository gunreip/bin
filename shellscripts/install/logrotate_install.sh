#!/usr/bin/env bash
set -euo pipefail

SCRIPT_VERSION="v1.0.0"

usage() {
  cat <<'USAGE'
logrotate_install.sh - Install logrotate config for Laravel logs
Version: v1.0.0

Usage:
  sudo ./logrotate_install.sh [-p <project_path>] [--log-dir <dir>] [--frequency weekly|daily|monthly] [--rotate <N>] [--no-compress] [--no-copytruncate] [--dry-run]

Defaults:
  -p               current directory
  --log-dir        <project>/storage/logs
  --frequency      weekly
  --rotate         8
  --compress       enabled (use --no-compress to disable)
  --copytruncate   enabled (use --no-copytruncate to disable)

Examples:
  sudo ./logrotate_install.sh -p /home/gunreip/code/tafel_wesseling
  sudo ./logrotate_install.sh --frequency daily --rotate 14
USAGE
}

PROJECT_PATH="$(pwd)"
LOG_DIR=""
FREQUENCY="weekly"
ROTATE="8"
COMPRESS="yes"
COPYTRUNCATE="yes"
DRY_RUN="no"

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0;;
    -p) PROJECT_PATH="$2"; shift 2;;
    --log-dir) LOG_DIR="$2"; shift 2;;
    --frequency) FREQUENCY="$2"; shift 2;;
    --rotate) ROTATE="$2"; shift 2;;
    --no-compress) COMPRESS="no"; shift;;
    --no-copytruncate) COPYTRUNCATE="no"; shift;;
    --dry-run|--simulate) DRY_RUN="yes"; shift;;
    *) echo "Unknown option: $1" >&2; usage; exit 2;;
  esac
done

if [[ -z "${LOG_DIR}" ]]; then
  LOG_DIR="${PROJECT_PATH%/}/storage/logs"
fi

if [[ ! -d "$PROJECT_PATH" ]]; then
  echo "❌ Project path not found: $PROJECT_PATH" >&2
  exit 2
fi

# derive project name for config filename
PROJECT_NAME="$(basename "$PROJECT_PATH")"
CONFIG_FILE="/etc/logrotate.d/laravel_${PROJECT_NAME}"

# build config body
cat_body() {
  local compress_block="compress\n  delaycompress"
  if [[ "$COMPRESS" != "yes" ]]; then
    compress_block="# compress disabled"
  fi
  local copytruncate_line="copytruncate"
  if [[ "$COPYTRUNCATE" != "yes" ]]; then
    copytruncate_line="# copytruncate disabled"
  fi

  cat <<EOF
${LOG_DIR%/}/*.log {
  ${FREQUENCY}
  rotate ${ROTATE}
  missingok
  notifempty
  ${compress_block}
  ${copytruncate_line}
}
EOF
}

echo "🔧 logrotate_install.sh ${SCRIPT_VERSION}"
echo "• Project: ${PROJECT_NAME}"
echo "• Logs: ${LOG_DIR}"
echo "• Config: ${CONFIG_FILE}"
echo "• Policy: frequency=${FREQUENCY}, rotate=${ROTATE}, compress=${COMPRESS}, copytruncate=${COPYTRUNCATE}"

if [[ "${DRY_RUN}" == "yes" ]]; then
  echo "---- BEGIN CONFIG PREVIEW ----"
  cat_body
  echo "---- END CONFIG PREVIEW ----"
  echo "(dry-run) Not writing to ${CONFIG_FILE}"
  exit 0
fi

# require root
if [[ "$EUID" -ne 0 ]]; then
  echo "❌ Please run with sudo/root to write ${CONFIG_FILE}" >&2
  exit 3
fi

# ensure log dir exists (do not fail if absent; missingok will handle)
mkdir -p "${LOG_DIR}" || true

# write config
tmp="$(mktemp)"
cat_body > "$tmp"
install -m 0644 "$tmp" "$CONFIG_FILE"
rm -f "$tmp"

echo "✅ Installed: ${CONFIG_FILE}"
echo "🧪 Test (no changes): sudo logrotate -d /etc/logrotate.conf | grep -F '${CONFIG_FILE}' -n || true"
echo "▶️  Force a rotation run (debug): sudo logrotate -d /etc/logrotate.conf"
