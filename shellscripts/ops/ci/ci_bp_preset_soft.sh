#!/usr/bin/env bash
# ci_bp_preset_soft.sh — setzt eine „weiche“ Branch-Protection (minimal)
# Default:
#   - required checks: ["CI / test"]
#   - strict = false, enforce_admins = false
#   - reviews = 0, require_code_owner_reviews = false, dismiss_stale_reviews = false
#   - required_conversation_resolution = false
# Läuft NUR im Projekt-Working-Dir (.env Gatekeeper)
# Version: v0.1.0

set -euo pipefail
VERSION="v0.1.0"

print_help(){ cat <<'HLP'
ci_bp_preset_soft — setzt eine minimale, „weiche“ Branch-Protection

USAGE
  ci_bp_preset_soft [--branch <name>] [--checks "A,B"] [--reviews N]
                    [--enforce-admins on|off] [--strict on|off]
                    [--codeowners on|off] [--conv-resolve on|off] [--dismiss-stale on|off]
                    [--dry-run] [--help] [--version]

Defaults:
  checks="CI / test", reviews=0, enforce-admins=off, strict=off,
  codeowners=off, conv-resolve=off, dismiss-stale=off
HLP
}

TARGET_BRANCH=""; OVERRIDE_CHECKS=""
REVIEWS="0"
ENFORCE="off"; STRICT="off"; CODEOWNERS="off"; CONV="off"; DISMISS="off"
DRY=0

# Args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch) TARGET_BRANCH="$2"; shift 2;;
    --checks) OVERRIDE_CHECKS="$2"; shift 2;;
    --reviews) REVIEWS="$2"; shift 2;;
    --enforce-admins) ENFORCE="$2"; shift 2;;
    --strict) STRICT="$2"; shift 2;;
    --codeowners) CODEOWNERS="$2"; shift 2;;
    --conv-resolve) CONV="$2"; shift 2;;
    --dismiss-stale) DISMISS="$2"; shift 2;;
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

# Checks bestimmen
declare -a contexts=()
if [[ -n "$OVERRIDE_CHECKS" ]]; then
  IFS=',' read -r -a arr <<<"$OVERRIDE_CHECKS"
  for c in "${arr[@]}"; do
    c_trim="$(echo "$c" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -n "$c_trim" ]] && contexts+=("$c_trim")
  done
else
  contexts=("CI / test")
fi
ctx_json="$(printf '%s\n' "${contexts[@]}" | jq -R . | jq -s . 2>/dev/null || echo '[]')"

# on/off -> true/false
to_bool() { [[ "$1" == "on" ]] && echo true || echo false; }
enforce_bool="$(to_bool "$ENFORCE")"
strict_bool="$(to_bool "$STRICT")"
codeowners_bool="$(to_bool "$CODEOWNERS")"
conv_bool="$(to_bool "$CONV")"
dismiss_bool="$(to_bool "$DISMISS")"

# Body (Hauptschutz)
body_json="$(
  jq -n \
    --argjson contexts "$ctx_json" \
    --argjson strict "$strict_bool" \
    --argjson enforce "$enforce_bool" \
    --argjson reviews "$(printf '%s' "$REVIEWS" | jq -R 'tonumber')" \
    --argjson codeowners "$codeowners_bool" \
    --argjson dismiss "$dismiss_bool" \
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

echo "== ci_bp_preset_soft ${VERSION} =="
echo "Repo: ${owner_repo} / Branch: ${TARGET_BRANCH}"
echo "Checks: $(printf '%s\n' "${contexts[@]}")"
echo "Reviews: ${REVIEWS}, Codeowners: ${CODEOWNERS}, Enforce-Admins: ${ENFORCE}, Strict: ${STRICT}, Conversation-Resolution: ${CONV}, Dismiss-stale: ${DISMISS}"
echo

if (( DRY )); then
  echo "[DRY-RUN] JSON-Body (Haupt-PUT):"
  echo "$body_json" | jq .
  if [[ "$conv_bool" == "true" ]]; then
    echo "[DRY-RUN] Conversation-Resolution: ON (separater Endpoint)"
  else
    echo "[DRY-RUN] Conversation-Resolution: OFF"
  fi
  echo
  echo "[DRY-RUN] Befehle:"
  echo "gh api -X PUT repos/${owner}/${repo}/branches/${TARGET_BRANCH}/protection -H 'Accept: application/vnd.github+json' --input -"
  [[ "$conv_bool" == "true" ]] && echo "gh api -X PUT repos/${owner}/${repo}/branches/${TARGET_BRANCH}/protection/required_conversation_resolution -H 'Accept: application/vnd.github+json'"
  exit 0
fi

# Anwenden (Haupt-Protection)
printf '%s' "$body_json" | gh api -X PUT "repos/${owner}/${repo}/branches/${TARGET_BRANCH}/protection" \
  -H "Accept: application/vnd.github+json" --input -

# Conversation-Resolution ggf. separat setzen
if [[ "$conv_bool" == "true" ]]; then
  set +e
  gh api -X PUT "repos/${owner}/${repo}/branches/${TARGET_BRANCH}/protection/required_conversation_resolution" \
    -H "Accept: application/vnd.github+json" >/dev/null 2>&1
  set -e
fi

echo
echo "[OK] Soft-Preset angewendet. Kurz prüfen…"
gh api "repos/${owner}/${repo}/branches/${TARGET_BRANCH}/protection" -q '. | {required_status_checks, enforce_admins, required_pull_request_reviews}'
