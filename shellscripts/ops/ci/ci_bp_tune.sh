#!/usr/bin/env bash
# ci_bp_tune.sh — Branch-Protection gezielt anpassen (nur im Projekt-Working-Dir, .env erforderlich)
# Version: v0.1.0
set -euo pipefail
VERSION="v0.1.0"

print_help(){ cat <<'HLP'
ci_bp_tune — Branch-Protection gezielt anpassen

USAGE
  ci_bp_tune [--branch <name>] [--list] [--dry-run]
             [--add-checks "A,B"] [--remove-checks "A,B"] [--set-checks "A,B"]
             [--reviews N] [--codeowners on|off] [--enforce-admins on|off]
             [--strict on|off] [--conv-resolve on|off] [--dismiss-stale on|off]
             [--help] [--version]

BESCHREIBUNG
  • --list           zeigt aktuelle Protection (rohes JSON)
  • --set-checks     ersetzt die gesamte Checkliste (Kontexte)
  • --add-checks     fügt Kontexte hinzu (dedupliziert)
  • --remove-checks  entfernt Kontexte
  • --reviews        Anzahl benötigter Reviews (Integer)
  • --codeowners     Codeowner-Review Pflicht ein/aus
  • --enforce-admins Admins müssen Regeln befolgen ein/aus
  • --strict         "Up-to-date before merge" ein/aus
  • --conv-resolve   "Required conversation resolution" ein/aus
  • --dismiss-stale  "dismiss stale reviews" ein/aus
  • --dry-run        nur zeigen, was gesendet würde

HINWEISE
  • Skript MUSS im Projekt-Root laufen (.env Gatekeeper).
  • Erfordert: gh (eingeloggt), git, jq.
HLP
}

# ---- Args ----
TARGET_BRANCH=""; DO_LIST=0; DRY=0
ADD_CHECKS=""; REMOVE_CHECKS=""; SET_CHECKS=""
REVIEWS=""; CODEOWNERS=""; ENFORCE=""; STRICT=""; CONV=""; DISMISS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch) TARGET_BRANCH="$2"; shift 2;;
    --list) DO_LIST=1; shift;;
    --dry-run) DRY=1; shift;;
    --add-checks) ADD_CHECKS="$2"; shift 2;;
    --remove-checks) REMOVE_CHECKS="$2"; shift 2;;
    --set-checks) SET_CHECKS="$2"; shift 2;;
    --reviews) REVIEWS="$2"; shift 2;;
    --codeowners) CODEOWNERS="$2"; shift 2;;
    --enforce-admins) ENFORCE="$2"; shift 2;;
    --strict) STRICT="$2"; shift 2;;
    --conv-resolve) CONV="$2"; shift 2;;
    --dismiss-stale) DISMISS="$2"; shift 2;;
    --version) echo "$VERSION"; exit 0;;
    -h|--help) print_help; exit 0;;
    *) echo "Unbekannter Parameter: $1" >&2; print_help; exit 1;;
  esac
done

# ---- Gatekeeper & Tools ----
[[ -f .env ]] || { echo "Fehler: .env fehlt. Bitte im Projekt-Root ausführen." >&2; exit 2; }
command -v git >/dev/null || { echo "Fehler: git nicht gefunden." >&2; exit 3; }
command -v gh  >/dev/null || { echo "Fehler: gh (GitHub CLI) nicht gefunden." >&2; exit 4; }
command -v jq  >/dev/null || { echo "Fehler: jq nicht gefunden." >&2; exit 5; }

# ---- Repo/Branch ermitteln ----
origin_url="$(git remote get-url origin 2>/dev/null || true)"
owner_repo="$(printf '%s\n' "${origin_url:-}" | sed -E 's#.*github\.com[:/]([^/]+/[^/.]+)(\.git)?$#\1#')"
owner="${owner_repo%%/*}"; repo="${owner_repo##*/}"

# Default-Branch (robust)
def_local="$(git remote show origin 2>/dev/null | sed -n 's/.*HEAD branch: //p' || true)"
[[ -z "$def_local" ]] && def_local="$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null | sed 's#.*/##' || true)"
api_def="$(gh api "repos/${owner}/${repo}" -q '.default_branch' 2>/dev/null || true)"
DEFAULT_BRANCH="${api_def:-$def_local}"

[[ -n "${TARGET_BRANCH:-}" ]] || TARGET_BRANCH="$DEFAULT_BRANCH"
[[ -n "$TARGET_BRANCH" ]] || { echo "Fehler: Default-Branch konnte nicht ermittelt werden." >&2; exit 6; }

echo "== ci_bp_tune ${VERSION} =="
echo "Repo: ${owner_repo} / Branch: ${TARGET_BRANCH}"

# ---- Aktuelle Protection ziehen (oder leeres Grundgerüst) ----
set +e
RAW="$(gh api "repos/${owner}/${repo}/branches/${TARGET_BRANCH}/protection" 2>/dev/null)"
rc=$?
set -e
if [[ $rc -ne 0 || -z "${RAW:-}" ]]; then
  RAW='{
    "required_status_checks": {"strict": true, "contexts": []},
    "enforce_admins": false,
    "required_pull_request_reviews": {
      "required_approving_review_count": 0,
      "dismiss_stale_reviews": false,
      "require_code_owner_reviews": false
    },
    "restrictions": null,
    "required_conversation_resolution": false
  }'
fi

if (( DO_LIST )); then
  echo "[AKTUELL]"; echo "$RAW" | jq .
  exit 0
fi

# Hilfsfunktionen/Variablen für jq
# SET_CHECKS -> JSON-Array oder null
if [[ -n "$SET_CHECKS" ]]; then
  SET_JSON="$(printf '%s' "$SET_CHECKS" | tr ',' '\n' | sed 's/^ *//;s/ *$//' | jq -R . | jq -s .)"
else
  SET_JSON="null"
fi

# jq Patch bauen
PATCH="$(
  jq \
    --arg add   "${ADD_CHECKS}" \
    --arg rem   "${REMOVE_CHECKS}" \
    --argjson set "$SET_JSON" \
    --arg reviews "${REVIEWS}" \
    --arg codeowners "${CODEOWNERS}" \
    --arg enforce "${ENFORCE}" \
    --arg strict "${STRICT}" \
    --arg conv "${CONV}" \
    --arg dismiss "${DISMISS}" \
    '
    def split_list(s): if s=="" then [] else (s|split(",")|map(gsub("^\\s+|\\s+$";""))|map(select(length>0))) end;

    # Basis sicherstellen
    .required_status_checks = (.required_status_checks // {"strict":true,"contexts":[]})
    | .required_pull_request_reviews = (.required_pull_request_reviews // {})
    | .restrictions = (.restrictions // null)
    | .required_conversation_resolution = (.required_conversation_resolution // false)

    # Checks setzen/ergänzen/entfernen
    | ( if $set != null then
          .required_status_checks.contexts = $set
        else
          .required_status_checks.contexts = (
            ( .required_status_checks.contexts + split_list($add) ) 
            | unique
            | ( . - split_list($rem) )
          )
        end )

    # Strict
    | ( if $strict=="on" then .required_status_checks.strict = true
        elif $strict=="off" then .required_status_checks.strict = false
        else . end )

    # Enforce Admins
    | ( if $enforce=="on" then .enforce_admins = true
        elif $enforce=="off" then .enforce_admins = false
        else . end )

    # Reviews (Zahl)
    | ( if ($reviews|length)>0 then
          .required_pull_request_reviews.required_approving_review_count = ($reviews|tonumber)
        else . end )

    # Codeowners
    | ( if $codeowners=="on" then .required_pull_request_reviews.require_code_owner_reviews = true
        elif $codeowners=="off" then .required_pull_request_reviews.require_code_owner_reviews = false
        else . end )

    # Dismiss stale
    | ( if $dismiss=="on" then .required_pull_request_reviews.dismiss_stale_reviews = true
        elif $dismiss=="off" then .required_pull_request_reviews.dismiss_stale_reviews = false
        else . end )

    # Conversation resolution
    | ( if $conv=="on" then .required_conversation_resolution = true
        elif $conv=="off" then .required_conversation_resolution = false
        else . end )
    ' <<<"$RAW"
)"

echo
echo "[VORHER]"; echo "$RAW"   | jq '.required_status_checks, .enforce_admins, .required_pull_request_reviews, .required_conversation_resolution'
echo
echo "[NACHHER]"; echo "$PATCH" | jq '.required_status_checks, .enforce_admins, .required_pull_request_reviews, .required_conversation_resolution'
echo

if (( DRY )); then
  echo "[DRY-RUN] Befehl:"
  echo "gh api -X PUT repos/${owner}/${repo}/branches/${TARGET_BRANCH}/protection -H 'Accept: application/vnd.github+json' --input -"
  exit 0
fi

# Anwenden
printf '%s' "$PATCH" | gh api -X PUT "repos/${owner}/${repo}/branches/${TARGET_BRANCH}/protection" \
  -H "Accept: application/vnd.github+json" --input -

echo
echo "[OK] Protection aktualisiert."
