#!/usr/bin/env bash
# ci_bp_apply.sh — setzt Branch-Protection für Default-Branch (nur im Projekt-Working-Dir, .env erforderlich)
# Version: v0.1.1 (contexts=() init + sichere ctx_json-Erzeugung)
set -euo pipefail
VERSION="v0.1.1"

print_help(){ cat <<'HLP'
ci_bp_apply.sh — setzt GitHub Branch-Protection für den Default-Branch

USAGE
  ci_bp_apply.sh [--branch <name>] [--checks "A,B,C"] [--reviews N] [--no-codeowners]
                 [--no-enforce-admins] [--no-strict] [--dry-run] [--help] [--version]
HLP
}

TARGET_BRANCH=""; OVERRIDE_CHECKS=""; REVIEW_COUNT=1
REQUIRE_CODEOWNERS=1; ENFORCE_ADMINS=1; STRICT_UPTODATE=1; DRY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch) TARGET_BRANCH="$2"; shift 2;;
    --checks) OVERRIDE_CHECKS="$2"; shift 2;;
    --reviews) REVIEW_COUNT="$2"; shift 2;;
    --no-codeowners) REQUIRE_CODEOWNERS=0; shift;;
    --no-enforce-admins) ENFORCE_ADMINS=0; shift;;
    --no-strict) STRICT_UPTODATE=0; shift;;
    --dry-run) DRY=1; shift;;
    --version) echo "$VERSION"; exit 0;;
    -h|--help) print_help; exit 0;;
    *) echo "Unbekannter Parameter: $1" >&2; print_help; exit 1;;
  esac
done

[[ -f .env ]] || { echo "Fehler: .env fehlt. Im Projekt-Working-Dir ausführen." >&2; exit 2; }
command -v git >/dev/null || { echo "Fehler: git nicht gefunden." >&2; exit 3; }
command -v gh  >/dev/null || { echo "Fehler: gh (GitHub CLI) nicht gefunden." >&2; exit 4; }
command -v jq  >/dev/null || { echo "Fehler: jq nicht gefunden." >&2; exit 5; }

origin_url="$(git remote get-url origin 2>/dev/null || true)"
owner_repo="$(printf '%s\n' "${origin_url:-}" | sed -E 's#.*github\.com[:/]([^/]+/[^/.]+)(\.git)?$#\1#')"
owner="${owner_repo%%/*}"; repo="${owner_repo##*/}"

def_local="$(git remote show origin 2>/dev/null | sed -n 's/.*HEAD branch: //p' || true)"
[[ -z "$def_local" ]] && def_local="$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null | sed -E 's#.*/##||' || true)"
# Fallback sed fix (falls oben leer blieb):
[[ -z "$def_local" ]] && def_local="$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null | sed 's#.*/##' || true)"

if [[ -z "${TARGET_BRANCH:-}" ]]; then
  api_def="$(gh api "repos/${owner}/${repo}" -q '.default_branch' 2>/dev/null || true)"
  TARGET_BRANCH="${api_def:-$def_local}"
fi
[[ -n "${TARGET_BRANCH:-}" ]] || { echo "Fehler: Default-Branch konnte nicht ermittelt werden." >&2; exit 6; }

CODEOWNERS="false"; [[ -f .github/CODEOWNERS ]] && CODEOWNERS="true"
if [[ "$CODEOWNERS" == "false" ]]; then REQUIRE_CODEOWNERS=0; fi

# --- WICHTIG: Array vorab initialisieren (verhindert 'unbound variable') ---
declare -a contexts=()

# 1) Kontexte aus Workflow-Jobs ableiten
wf_dir=".github/workflows"
if [[ -d "$wf_dir" ]]; then
  while IFS= read -r -d '' yml; do
    wf_name="$(awk -F: '$1 ~ /^name$/ && !seen { sub(/^[^:]+:[[:space:]]*/,""); print; seen=1; exit }' "$yml" 2>/dev/null || true)"
    [[ -z "$wf_name" ]] && wf_name="$(basename "$yml")"
    mapfile -t jobs < <(awk '
      /^jobs:/ {in=1; next}
      in==1 {
        if ($0 ~ /^[^[:space:]]/) {in=0; next}
        if ($0 ~ /^[[:space:]]{2}[A-Za-z0-9_.-]+:/) {s=$0; sub(/^[[:space:]]+/,"",s); sub(/:.*/,"",s); print s}
      }' "$yml" 2>/dev/null || true)
    if (( ${#jobs[@]} )); then
      for j in "${jobs[@]}"; do
        [[ "$wf_name" =~ [Dd]eploy ]] && continue
        contexts+=("${wf_name} / ${j}")
      done
    fi
  done < <(find "$wf_dir" -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) -print0 2>/dev/null)
fi

# 2) Fallback: Check-Runs letzten Commits
if (( ${#contexts[@]} == 0 )); then
  git fetch --quiet origin || true
  head_sha="$(git rev-parse "origin/${TARGET_BRANCH}" 2>/dev/null || echo "")"
  if [[ -n "$head_sha" ]]; then
    mapfile -t cr_names < <(gh api "repos/${owner}/${repo}/commits/${head_sha}/check-runs" -q '.check_runs[].name' 2>/dev/null || true)
    for n in "${cr_names[@]:-}"; do
      [[ "$n" =~ [Dd]eploy ]] && continue
      [[ -n "$n" ]] && contexts+=("$n")
    done
    (( ${#contexts[@]} > 0 )) && mapfile -t contexts < <(printf '%s\n' "${contexts[@]}" | awk '!seen[$0]++')
  fi
fi

# 3) Manuelle Overrides
if [[ -n "${OVERRIDE_CHECKS:-}" ]]; then
  IFS=',' read -r -a manual <<<"$OVERRIDE_CHECKS"
  contexts=()
  for c in "${manual[@]}"; do
    c_trim="$(echo "$c" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -n "$c_trim" ]] && contexts+=("$c_trim")
  done
fi

# --- ctx_json sicher bauen ---
if (( ${#contexts[@]} > 0 )); then
  ctx_json="$(printf '%s\n' "${contexts[@]}" | jq -R . | jq -s . 2>/dev/null || echo '[]')"
else
  ctx_json='[]'
fi

strict_bool="true"; [[ $STRICT_UPTODATE -eq 0 ]] && strict_bool="false"
enforce_bool="true"; [[ $ENFORCE_ADMINS -eq 0 ]] && enforce_bool="false"
co_bool="false"; [[ $REQUIRE_CODEOWNERS -eq 1 ]] && co_bool="true"

body_json="$(
  jq -n \
    --argjson strict "$strict_bool" \
    --argjson contexts "$ctx_json" \
    --argjson enforce "$enforce_bool" \
    --argjson reviews "$REVIEW_COUNT" \
    --argjson codeowners "$co_bool" \
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

echo "== ci_bp_apply ${VERSION} =="
echo "Repo: ${owner_repo} / Branch: ${TARGET_BRANCH}"
echo "Gefundene required checks: ${ctx_json}"
echo "Reviews: ${REVIEW_COUNT}, Codeowner-Review: $([[ $REQUIRE_CODEOWNERS -eq 1 ]] && echo on || echo off), Enforce-Admins: $([[ $ENFORCE_ADMINS -eq 1 ]] && echo on || echo off), Strict: $([[ $STRICT_UPTODATE -eq 1 ]] && echo on || echo off)"
echo

if [[ $DRY -eq 1 ]]; then
  echo "[DRY-RUN] JSON-Body:"
  echo "$body_json" | jq .
  echo
  echo "[DRY-RUN] Befehl:"
  echo "gh api -X PUT repos/${owner}/${repo}/branches/${TARGET_BRANCH}/protection -H 'Accept: application/vnd.github+json' --input -"
  exit 0
fi

printf '%s' "$body_json" | gh api -X PUT "repos/${owner}/${repo}/branches/${TARGET_BRANCH}/protection" \
  -H "Accept: application/vnd.github+json" --input -

echo
echo "[OK] Branch-Protection gesetzt. Prüfe Status…"
gh api "repos/${owner}/${repo}/branches/${TARGET_BRANCH}/protection" -q '. | {required_status_checks, enforce_admins, required_pull_request_reviews}'
