#!/usr/bin/env bash
set -euo pipefail
SCRIPT_VERSION="v1.0.0"

REPO_PATH=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p) REPO_PATH="${2:-}"; shift 2 ;;
    --version) echo "prepush_uninstall.sh $SCRIPT_VERSION"; exit 0 ;;
    *) echo "Unbekannter Parameter: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "${REPO_PATH}" ]]; then REPO_PATH="$(pwd)"; fi
if [[ ! -d "$REPO_PATH/.git" ]]; then
  echo "❌ Kein Git-Repository unter: $REPO_PATH" >&2
  exit 2
fi

HOOKS_PATH="$(git -C "$REPO_PATH" config --get core.hooksPath || true)"
if [[ -z "${HOOKS_PATH}" ]]; then
  HOOKS_PATH="$REPO_PATH/.git/hooks"
fi
HOOK_FILE="$HOOKS_PATH/pre-push"

if [[ -f "$HOOK_FILE" ]]; then
  rm -f "$HOOK_FILE"
  echo "✅ pre-push Hook entfernt: $HOOK_FILE"
else
  echo "ℹ️  Kein pre-push Hook gefunden unter: $HOOK_FILE"
fi
