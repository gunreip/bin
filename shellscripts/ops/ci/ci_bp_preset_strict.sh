#!/usr/bin/env bash
# ci_bp_preset_strict.sh — setzt eine „streng, aber praxisnah“ Branch-Protection
#   - required checks (Standard): CI / test, CI / phpstan, CI / pint
#   - strict = true, enforce_admins = true
#   - reviews = 1, require_code_owner_reviews = true, dismiss_stale_reviews = true
#   - required_conversation_resolution = true
# Läuft NUR im Projekt-Working-Dir (.env Gatekeeper)
# Version: v0.1.0

set -euo pipefail
VERSION="v0.1.0"

print_help(){ cat <<'HLP'
ci_bp_preset_strict — setzt eine strikte Branch-Protection

USAGE
  ci_bp_preset_strict [--branch <name>] [--checks "A,B,C"] [--reviews N]
                      [--dry-run] [--help] [--version]

OPTIONEN
  --branch <name>   Zielbranch (Default: Repo-Default-Branch)
  --checks "A,B,C"  Eigene Check-Kontexte statt Standard
  --reviews N       Anzahl Reviews (Default: 1)
  --dry-run         Nur anzeigen, was gesendet würde
  -h, --help        Hilfe
  --version         Version ausgeben

HINWEISE
  • Skript MUSS im Projekt-Root laufen (.env Gatekeeper).
  • Erfordert: gh (eingeloggt), git, jq.
HLP
}

TARGET_BRANCH=""; OVERRIDE_CHECKS=""; REVIEWS="1"; DRY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch) TARGET_BRANCH="$2"; shift 2;;
    --checks) OVERRIDE_CHECKS="$2"; shift 2;;
    --reviews) REVIEWS="$2"; shift 2;;
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
command -v jq  >/dev/null || { echo "Fehler: jq nicht gefunden." >&2; exit 5; }

# Repo/Owner
origin_url="$(git remote get-url origin 2>/dev/null || true)"
owner_repo="$(printf '%s\n' "${origin_url:-}" | sed -E 's#.*github\.com[:/]([^/]+/[^/.]+)(\.git)?$#\1#')"
owner="${owner_repo%%/*}"; repo="${owner_repo##*/}"

# Default-Branch ermitteln (robust)
def_local="$(git remote show origin 2>/dev/null | sed -n 's/.*HEAD branch: //p' || true)"
[[ -z "$def_local" ]] && def_local="$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null | sed 's#.*/##' || true)"
api_def="$(gh api "repos/${owner}/${repo}" -q '.default_branch' 2>/dev/null || true)"
DEFAULT_BRANCH="${api_def:-$def_local}"
[[ -n "${TARGET_BRANCH:-}" ]] || TARGET_BRANCH="$DEFAULT_BRANCH"
[[ -n "$TARGET_BRANCH" ]] || { echo "Fehler: Default-Branch konnte nicht ermittelt werden." >&2; exit 6; }

# Check-Kontexte
declare -a contexts=()
if [[ -n "$OVERRIDE_CHECKS" ]]; then
  IFS=',' read -r -a arr <<<"$OVERRIDE_CHECKS"
  for c in "${arr[@]}"; do
    c_trim="$(echo "$c" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -n "$c_trim" ]] && contexts+=("$c_trim")
  done
else
  contexts=("CI / test" "CI / phpstan" "CI / pint")
fi

ctx_json="$(printf '%s\n' "${contexts[@]}" | jq -R . | jq -s . 2>/dev/null || echo '[]')"

# Body bauen
body_json="$(
  jq -n \
    --argjson contexts "$ctx_json" \
    --argjson strict true \
    --argjson enforce true \
    --argjson reviews "$(printf '%s' "$REVIEWS" | jq -R 'tonumber')" \
    --argjson codeowners true \
    --argjson dismiss true \
    --argjson restrictions null \
    '{
      required_status_checks: { strict: $strict, contexts: $contexts },
      enforce_admins: $enforce,
      required_pull_request_reviews: {
        required_approving_review_count: $reviews,
        require_code_owner_reviews: $codeowners,
        dismiss_stale_reviews: $dismiss
      },
      restrictions: $restrictions
    }'
)"

echo "== ci_bp_preset_strict ${VERSION} =="
echo "Repo: ${owner_repo} / Branch: ${TARGET_BRANCH}"
echo "Checks: $(printf '%s\n' "${contexts[@]}")"
echo "Reviews: ${REVIEWS}, Codeowners: on, Enforce-Admins: on, Strict: on, Conversation-Resolution: on"
echo

if (( DRY )); then
  echo "[DRY-RUN] JSON-Body (Haupt-PUT):"
  echo "$body_json" | jq .
  echo
  echo "[DRY-RUN] Befehle:"
  echo "gh api -X PUT repos/${owner}/${repo}/branches/${TARGET_BRANCH}/protection -H 'Accept: application/vnd.github+json' --input -"
  echo "gh api -X PUT repos/${owner}/${repo}/branches/${TARGET_BRANCH}/protection/required_conversation_resolution -H 'Accept: application/vnd.github+json'"
  exit 0
fi

# Anwenden (1) Haupt-Protection
printf '%s' "$body_json" | gh api -X PUT "repos/${owner}/${repo}/branches/${TARGET_BRANCH}/protection" \
  -H "Accept: application/vnd.github+json" --input -

# Anwenden (2) required conversation resolution (separater Endpoint; idempotent)
set +e
gh api -X PUT "repos/${owner}/${repo}/branches/${TARGET_BRANCH}/protection/required_conversation_resolution" \
  -H "Accept: application/vnd.github+json" >/dev/null 2>&1
set -e

echo
echo "[OK] Preset angewendet. Kurz prüfen…"
gh api "repos/${owner}/${repo}/branches/${TARGET_BRANCH}/protection" -q '. | {required_status_checks, enforce_admins, required_pull_request_reviews}'
