#!/usr/bin/env bash
# ci_bp_preset_flip.sh — schaltet Branch-Protection zwischen "strict" und "soft"
#   nutzt: ci_bp_preset_strict, ci_bp_preset_soft
# Gatekeeper: im Projekt-Root (mit .env) ausführen
# Version: v0.1.0
set -euo pipefail
VERSION="v0.1.0"

print_help(){ cat <<'HLP'
ci_bp_preset_flip — schaltet Branch-Protection zwischen "strict" und "soft"

USAGE
  ci_bp_preset_flip --to strict|soft [--branch <name>] [--checks "A,B,C"] [--reviews N] [--dry-run]
  ci_bp_preset_flip --help | --version

OPTIONEN
  --to strict|soft   Ziel-Preset (erforderlich)
  --branch <name>    Ziel-Branch (Default: Repo-Default-Branch)
  --checks "A,B,C"   Check-Kontexte überschreiben
  --reviews N        Anzahl Reviews (Default: strict=1, soft=0)
  --dry-run          Nur anzeigen, was ausgeführt würde (an Unter-Skript durchgereicht)
  -h, --help         Hilfe
  --version          Version ausgeben

HINWEIS
  Dieses Skript ist ein Wrapper um die Presets:
    • ci_bp_preset_strict
    • ci_bp_preset_soft
  Beide müssen im PATH verfügbar sein (sie werden von uns üblicherweise in ~/bin installiert).
HLP
}

TARGET=""; BRANCH=""; CHECKS=""; REVIEWS=""
DRY=0

# --- Args parsen ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --to) TARGET="$2"; shift 2;;
    --branch) BRANCH="$2"; shift 2;;
    --checks) CHECKS="$2"; shift 2;;
    --reviews) REVIEWS="$2"; shift 2;;
    --dry-run) DRY=1; shift;;
    --version) echo "$VERSION"; exit 0;;
    -h|--help) print_help; exit 0;;
    *) echo "Unbekannter Parameter: $1" >&2; print_help; exit 1;;
  esac
done

# --- Gatekeeper & Tools ---
[[ -f .env ]] || { echo "Fehler: .env fehlt. Bitte im Projekt-Root ausführen." >&2; exit 2; }
command -v gh  >/dev/null || { echo "Fehler: gh (GitHub CLI) nicht gefunden." >&2; exit 3; }
command -v jq  >/dev/null || { echo "Fehler: jq nicht gefunden." >&2; exit 4; }

# --- Ziel prüfen ---
case "${TARGET,,}" in
  strict) CMD="ci_bp_preset_strict";;
  soft)   CMD="ci_bp_preset_soft";;
  *) echo "Fehler: --to muss 'strict' oder 'soft' sein." >&2; exit 5;;
esac
command -v "$CMD" >/dev/null || { echo "Fehler: benötigtes Preset-Skript '$CMD' nicht im PATH." >&2; exit 6; }

# --- Aufruf bauen ---
args=()
[[ -n "$BRANCH" ]] && { args+=("--branch" "$BRANCH"); }
[[ -n "$CHECKS" ]] && { args+=("--checks" "$CHECKS"); }
[[ -n "$REVIEWS" ]] && { args+=("--reviews" "$REVIEWS"); }
(( DRY )) && args+=("--dry-run")

echo "== ci_bp_preset_flip ${VERSION} =="
echo "Preset: $TARGET"
echo "Cmd: $CMD ${args[*]}"
echo

# --- Ausführen ---
"$CMD" "${args[@]}"
