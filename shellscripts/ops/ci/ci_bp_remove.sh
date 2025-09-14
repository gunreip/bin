#!/usr/bin/env bash
# ci_bp_remove.sh — entfernt Branch-Protection vollständig (nur im Projekt-Working-Dir, .env erforderlich)
# Version: v0.1.0
set -euo pipefail
VERSION="v0.1.0"

print_help(){ cat <<'HLP'
ci_bp_remove.sh — entfernt GitHub Branch-Protection komplett

USAGE
  ci_bp_remove.sh [--branch <name>] [--dry-run] [--help] [--version]

OPTIONEN
  --branch <name>   Zielbranch (Default: Repo-Default-Branch)
  --dry-run         Nur anzeigen, was gesendet würde
  -h, --help        Hilfe
  --version         Version ausgeben

HINWEISE
  • Skript MUSS im Projekt-Working-Dir laufen (.env Gatekeeper).
  • Erfordert: gh (eingeloggt), git.
HLP
}

TARGET_BRANCH=""
DRY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch) TARGET_BRANCH="$2"; shift 2;;
    --dry-run) DRY=1; shift;;
    --version) echo "$VERSION"; exit 0;;
    -h|--help) print_help; exit 0;;
    *) echo "Unbekannter Parameter: $1" >&2; print_help; exit 1;;
  esac
done

# Gatekeeper & Tools
[[ -f .env ]] || { echo "Fehler: .env fehlt. Bitte im Projekt-Root ausführen." >&2; exit 2; }
command -v git >/dev/null || { echo "Fehler: git nicht gefunden." >&2; exit 3; }
command -v gh  >/dev/null || { echo "Fehler: gh (GitHub CLI) nicht gefunden." >&2; exit 4; }

# Repo/Owner
origin_url="$(git remote get-url origin 2>/dev/null || true)"
owner_repo="$(printf '%s\n' "${origin_url:-}" | sed -E 's#.*github\.com[:/]([^/]+/[^/.]+)(\.git)?$#\1#')"
owner="${owner_repo%%/*}"; repo="${owner_repo##*/}"

# Default-Branch ermitteln (robust)
def_local="$(git remote show origin 2>/dev/null | sed -n 's/.*HEAD branch: //p' || true)"
if [[ -z "$def_local" ]]; then
  def_local="$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null | sed 's#.*/##' || true)"
fi
api_def="$(gh api "repos/${owner}/${repo}" -q '.default_branch' 2>/dev/null || true)"
DEFAULT_BRANCH="${api_def:-$def_local}"

if [[ -z "${TARGET_BRANCH:-}" ]]; then
  TARGET_BRANCH="$DEFAULT_BRANCH"
fi
[[ -n "$TARGET_BRANCH" ]] || { echo "Fehler: Zielbranch unbekannt." >&2; exit 5; }

echo "== ci_bp_remove ${VERSION} =="
echo "Repo: ${owner_repo} / Branch: ${TARGET_BRANCH}"
echo

if [[ $DRY -eq 1 ]]; then
  echo "[DRY-RUN] Befehl:"
  echo "gh api -X DELETE repos/${owner}/${repo}/branches/${TARGET_BRANCH}/protection"
  exit 0
fi

# Protection löschen (idempotent: 404 = schon entfernt)
set +e
out="$(gh api -X DELETE "repos/${owner}/${repo}/branches/${TARGET_BRANCH}/protection" 2>&1)"
rc=$?
set -e
if [[ $rc -ne 0 ]]; then
  case "$out" in
    *"Branch not protected"*|*"404"*) echo "[OK] Branch war nicht geschützt oder bereits entfernt."; exit 0;;
    *) echo "[FEHLER] Entfernen fehlgeschlagen:"; echo "$out"; exit $rc;;
  esac
fi

echo "[OK] Branch-Protection entfernt."
