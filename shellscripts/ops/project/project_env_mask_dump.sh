#!/usr/bin/env bash
SCRIPT_VERSION="v0.1.0"
set -euo pipefail

PROJECT_PATH="$(pwd)"; DRY=0
while [[ $# -gt 0 ]]; do case "$1" in -p) PROJECT_PATH="$2"; shift 2;; --dry-run) DRY=1; shift;; --version) echo "$SCRIPT_VERSION"; exit 0;; *) echo "Unknown: $1" >&2; exit 1;; esac; done

cd "$PROJECT_PATH"
[[ -f .env ]] || { printf 'Fehler: .env fehlt.\n' >&2; exit 2; }

abs="$(pwd)"
ts="$(date +%Y-%m-%d\ %H:%M)"
tsfile="$(date +%Y%m%d_%H%M)"
outdir=".wiki/env_dumps"; outfile="${outdir}/env_dump_${tsfile}.md"
mkdir -p "$outdir"

mask_line() {
  # behalte Key, ersetze Value durch Sternchen (wenn vorhanden)
  awk -F'=' 'BEGIN{OFS="="}
  /^[[:space:]]*#/ {print; next}
  NF<2 {print; next}
  {
    key=$1; val=substr($0, index($0,"=")+1)
    low=tolower(key)
    if (low ~ /(key|secret|password|passwd|token|app_key|private|client_secret)/) {
      gsub(/.*/, "********", val)
      print key, val
    } else {
      print key, val
    }
  }'
}

emit() {
  printf '%s\n' "$1" >> "$outfile"
}

# Build output (Markdown)
{
  echo "- Projekt: $(basename "$abs")"
  echo "- Projektpfad: \`$abs\`"
  echo "- Erstellt am: ${ts}"
  echo "- Version: ${SCRIPT_VERSION}"
  echo
  echo "## .env (maskiert)"
  echo '```dotenv'
  cat .env | mask_line
  echo '```'
  if [[ -f .env.example ]]; then
    echo
    echo "## .env.example (maskiert)"
    echo '```dotenv'
    cat .env.example | mask_line
    echo '```'
  fi
} > "$outfile"

if [[ "$DRY" -eq 1 ]]; then
  printf '[DRY] würde schreiben: %s\n' "$outfile"
else
  printf 'OK: %s\n' "$outfile"
fi
