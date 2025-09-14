#!/usr/bin/env bash
SCRIPT_VERSION="v0.1.0"
set -euo pipefail

DRY=0
while [[ $# -gt 0 ]]; do case "$1" in --dry-run) DRY=1; shift;; --version) echo "$SCRIPT_VERSION"; exit 0;; *) echo "Unknown: $1" >&2; exit 1;; esac; done
run(){ if [[ "$DRY" -eq 1 ]]; then printf '[DRY] %s\n' "$*"; else eval "$@"; fi }

run "git config --global core.autocrlf false"
run "git config --global core.eol lf"

profile="${HOME}/.profile"
line1='export CHOKIDAR_USEPOLLING=1'
line2='export WATCHPACK_POLLING=true'
grep -qxF "$line1" "$profile" 2>/dev/null || run "printf '%s\n' '$line1' >> '$profile'"
grep -qxF "$line2" "$profile" 2>/dev/null || run "printf '%s\n' '$line2' >> '$profile'"

printf 'OK: WSL-Dev-Tweaks gesetzt (Shell neustarten oder: source ~/.profile)\n'
