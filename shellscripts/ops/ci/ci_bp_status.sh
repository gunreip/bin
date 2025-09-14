#!/usr/bin/env bash
# ci_bp_status.sh — CI/Branch-Protection Status (nur im Projekt-Working-Dir, .env erforderlich)
# Version: v0.5.2
set -euo pipefail
VERSION="v0.5.2"

print_help(){ cat <<'HLP'
ci_bp_status.sh — ermittelt den Status von GitHub-Actions-Workflows & Branch-Protection

USAGE
  ci_bp_status.sh [--out] [--json] [--max N] [--dry-run] [--help] [--version]

OPTIONEN
  --out        Ergebnis nach .wiki/ci/ schreiben (Markdown; bei --json zusätzlich .json)
  --json       JSON-Ausgabe erzeugen (benötigt jq; sonst Hinweis und kein JSON-File)
  --max N      Max. Anzahl gespeicherter Reports je Typ (Default: 10)
  --dry-run    Nur anzeigen, welche Dateien geschrieben/gelöscht würden
  -h, --help   Hilfe
  --version    Version ausgeben

HINWEISE
  • Skript MUSS im Projekt-Working-Dir laufen (Gatekeeper: .env muss vorhanden sein).
  • Für Branch-Protection-Abfrage: GitHub CLI "gh" (eingeloggt).
HLP
}

DO_OUT=0; DO_JSON=0; MAX=10; DRY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) DO_OUT=1; shift;;
    --json) DO_JSON=1; shift;;
    --max) MAX="$2"; shift 2;;
    --dry-run) DRY=1; shift;;
    --version) echo "$VERSION"; exit 0;;
    -h|--help) print_help; exit 0;;
    *) echo "Unbekannter Parameter: $1" >&2; print_help; exit 1;;
  esac
done

# Gatekeeper
[[ -f .env ]] || { echo "Fehler: .env fehlt. Skript nur im Projektordner ausführen." >&2; exit 2; }
command -v git >/dev/null || { echo "Fehler: git nicht gefunden." >&2; exit 3; }

have_jq=0; command -v jq >/dev/null && have_jq=1
have_gh=0; command -v gh >/dev/null && have_gh=1

# --- Repo/Branch-Basics ---
origin_url="$(git remote get-url origin 2>/dev/null || true)"
branch_curr="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "-")"
branch_def_local="$(git remote show origin 2>/dev/null | sed -n 's/.*HEAD branch: //p' || true)"
[[ -z "$branch_def_local" ]] && branch_def_local="$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null | sed -E 's#.*/##/' || true)"
default_branch="$branch_def_local"
owner_repo="$(printf '%s\n' "${origin_url:-}" | sed -E 's#.*github\.com[:/]([^/]+/[^/.]+)(\.git)?$#\1#')"
owner="${owner_repo%%/*}"; repo="${owner_repo##*/}"

# --- Report-Metadaten ---
project_name="$(basename "$(pwd -P)")"
project_path="$(pwd -P)"
timestamp="$(date '+%Y-%m-%d %H:%M:%S %Z')"

# --- Workflows / Secrets / CODEOWNERS ---
wf_dir=".github/workflows"
mapfile -t wf_files < <(find "$wf_dir" -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) -print 2>/dev/null | sort || true)
secrets_used="$(grep -hoR 'secrets\.[A-Za-z0-9_]+' "$wf_dir" 2>/dev/null | sort -u || true)"
codeowners_present="false"; [[ -f .github/CODEOWNERS ]] && codeowners_present="true"

extract_wf_name() {
  awk -F: '$1 ~ /^name$/ && !seen { sub(/^[^:]+:[[:space:]]*/,""); print; seen=1; exit }' "$1" 2>/dev/null || true
}
extract_wf_events() {
  awk '
    BEGIN{in_on=0}
    /^on:[[:space:]]*\[/ {match($0, /\[.*\]/); s=substr($0,RSTART+1,RLENGTH-2); gsub(/[,]/," ",s); gsub(/[[:space:]]+/," ",s); print s; next}
    /^on:[[:space:]]*$/ {in_on=1; next}
    in_on==1 {
      if ($0 ~ /^[^[:space:]]/) {in_on=0; next}
      if ($0 ~ /^[[:space:]]{2}[A-Za-z0-9_.-]+:/) {line=$0; sub(/^[[:space:]]+/,"",line); sub(/:.*/,"",line); printf "%s ", line}
    }' "$1" 2>/dev/null | xargs || true
}
extract_job_ids() {
  awk '
    /^jobs:/ {in=1; next}
    in==1 {
      if ($0 ~ /^[^[:space:]]/) {in=0; next}
      if ($0 ~ /^[[:space:]]{2}[A-Za-z0-9_.-]+:/) {s=$0; sub(/^[[:space:]]+/,"",s); sub(/:.*/,"",s); print s}
    }' "$1" 2>/dev/null || true
}

# --- gh / Branch-Protection ---
bp_json=""
if [[ $have_gh -eq 1 && -n "$owner" && -n "$repo" ]]; then
  api_def="$(gh api "repos/${owner}/${repo}" -q '.default_branch' 2>/dev/null || true)"
  [[ -n "$api_def" ]] && default_branch="$api_def"
  bp_raw="$(gh api -X GET "repos/${owner}/${repo}/branches/${default_branch}/protection" 2>/dev/null || true)"
  [[ -n "$bp_raw" ]] && bp_json="$bp_raw"
fi

# --- Branch-Protection (human, ASCII-only) ---
bp_human=""
if [[ -n "$bp_json" && $have_jq -eq 1 ]]; then
  bp_human="$(printf '%s' "$bp_json" | jq -r '
    [
      "- required_status_checks: " +
        ((.required_status_checks.contexts // []) | tostring),
      "- enforce_admins: " +
        (try .enforce_admins.enabled catch false | tostring),
      "- required_pull_request_reviews: { " +
        "required_approving_review_count=" +
          (try .required_pull_request_reviews.required_approving_review_count catch 0 | tostring) + ", " +
        "require_code_owner_reviews=" +
          (try .required_pull_request_reviews.require_code_owner_reviews catch false | tostring) + ", " +
        "dismiss_stale_reviews=" +
          (try .required_pull_request_reviews.dismiss_stale_reviews catch false | tostring) + " }",
      "- restrictions: " +
        (if .restrictions == null then "none" else "enabled" end)
    ] | .[]
  ' )"
fi

# --- Tempfiles und Trap (nur löschen, wenn gesetzt) ---
tmp_md="$(mktemp)"; tmp_json=""
cleanup() {
  [[ -n "${tmp_md:-}"   && -f "$tmp_md"   ]] && rm -f "$tmp_md"
  [[ -n "${tmp_json:-}" && -f "$tmp_json" ]] && rm -f "$tmp_json"
}
trap cleanup EXIT

# --- Markdown in Temp-Datei aufbauen ---
{
  echo "# CI / Branch-Protection - Status"
  echo
  echo "- Projekt: ${project_name}"
  echo "- Projektpfad: \`${project_path}\`"
  echo "- Erstellt am: ${timestamp}"
  echo "- Version: ${VERSION}"
  echo "- Repo: ${owner_repo:-"-"}"
  echo "- Remote: ${origin_url:-"-"}"
  echo "- Akt. Branch: ${branch_curr}"
  echo "- Default-Branch: ${default_branch:-"-"}"
  echo
  echo "## Workflows (.github/workflows)"
  if (( ${#wf_files[@]} == 0 )); then
    echo "- keine Workflows gefunden."
  else
    echo "- Anzahl: ${#wf_files[@]}"
    for f in "${wf_files[@]}"; do
      name="$(extract_wf_name "$f")"; [[ -z "$name" ]] && name="$(basename "$f")"
      events="$(extract_wf_events "$f")"
      mapfile -t jobs < <(extract_job_ids "$f")
      echo
      echo "- ${name}"
      echo "  • Datei: ${f}"
      echo "  • on:    ${events:-"-"}"
      if (( ${#jobs[@]} )); then
        echo "  • jobs:  ${jobs[*]}"
        echo "  • (Check-Kontext-Beispiel): \"${name} / ${jobs[0]}\""
      fi
    done
  fi

  if [[ -n "$secrets_used" ]]; then
    echo
    echo "## In Workflows referenzierte Secrets"
    while IFS= read -r line; do
      [[ -n "$line" ]] && echo "- $line"
    done <<<"$secrets_used"
  fi

  if [[ "$codeowners_present" == "true" ]]; then
    echo
    echo "## CODEOWNERS"
    echo "- vorhanden: .github/CODEOWNERS"
  fi

  echo
  echo "## Branch-Protection"
  if [[ -n "$bp_json" ]]; then
    if [[ $have_jq -eq 1 ]]; then
      printf '%s\n' "$bp_human"
    else
      echo "- (Rohdaten verfügbar, installiere jq für schöne Ausgabe)"
    fi
  else
    if [[ $have_gh -eq 0 ]]; then
      echo "- Hinweis: gh nicht gefunden oder nicht eingeloggt -> keine Abfrage möglich."
    else
      echo "- Keine Branch-Protection gefunden oder fehlende Berechtigung."
    fi
  fi
} >> "$tmp_md"

# --- Terminal-Ausgabe ---
cat "$tmp_md"

# --- Datei-Output ---
if (( DO_OUT == 1 )); then
  outdir=".wiki/ci"; ts="$(date +%Y%m%d_%H%M%S)"; mkdir -p "$outdir"
  md_file="${outdir}/ci_bp_status_${ts}.md"
  if (( DRY == 1 )); then
    echo "[DRY] würde schreiben: $md_file"
  else
    cp "$tmp_md" "$md_file"
    echo "OK: $md_file"
  fi

  if (( DO_JSON == 1 )); then
    if (( have_jq == 1 )); then
      tmp_json="$(mktemp)"

      # Workflows JSON (einzeln sammeln, dann zusammenfassen)
      wf_items=()
      if (( ${#wf_files[@]} > 0 )); then
        for f in "${wf_files[@]}"; do
          name="$(extract_wf_name "$f")"; [[ -z "$name" ]] && name="$(basename "$f")"
          events="$(extract_wf_events "$f")"
          mapfile -t jobs < <(extract_job_ids "$f")
          jobs_json="$(printf '%s\n' "${jobs[@]}" | jq -R . | jq -s .)"
          item="$(jq -n --arg name "$name" --arg file "$f" --arg on "$events" --argjson jobs "$jobs_json" \
                  '{name:$name, file:$file, on:$on, jobs:$jobs}')"
          wf_items+=("$item")
        done
      fi
      wf_json="$(printf '%s\n' "${wf_items[@]:-}" | jq -s '.')"

      secrets_json="$(printf '%s\n' "${secrets_used:-}" | sed '/^$/d' | jq -R . | jq -s .)"
      bp_json_or_null="${bp_json:-null}"
      codeowners_bool="false"; [[ "$codeowners_present" == "true" ]] && codeowners_bool="true"

      jq -n \
        --arg remote "${origin_url:-}" \
        --arg repo   "${owner_repo:-}" \
        --arg branch_current "${branch_curr:-}" \
        --arg branch_default "${default_branch:-}" \
        --argjson workflows "${wf_json:-[]}" \
        --argjson secrets   "${secrets_json:-[]}" \
        --argjson branch_protection "${bp_json_or_null}" \
        --argjson codeowners "${codeowners_bool}" \
        '{ remote: $remote, repo: $repo, branch_current: $branch_current, branch_default: $branch_default,
           workflows: $workflows, secrets: $secrets, branch_protection: $branch_protection, codeowners: $codeowners }' \
        > "$tmp_json"

      json_file="${outdir}/ci_bp_status_${ts}.json"
      if (( DRY == 1 )); then
        echo "[DRY] würde schreiben: $json_file"
      else
        mv "$tmp_json" "$json_file"
        echo "OK: $json_file"
      fi
    else
      echo "Hinweis: jq nicht installiert – JSON wird nicht geschrieben." >&2
    fi
  fi

  # Housekeeping je Typ
  hk() {
    local ext="$1" cnt=0
    for f in $(ls -t "$outdir"/ci_bp_status_*.${ext} 2>/dev/null); do
      cnt=$((cnt+1))
      if (( cnt > MAX )); then
        if (( DRY == 1 )); then
          echo "[DRY] rm -f '$f'"
        else
          rm -f "$f"
        fi
      fi
    done
  }
  hk md
  (( DO_JSON==1 && have_jq==1 )) && hk json
fi
