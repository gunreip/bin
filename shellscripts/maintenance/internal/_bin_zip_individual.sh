#!/usr/bin/env bash
# _bin_zip_individual.sh — erstellt EINZEL-ZIPs für alle *.sh aus ~/bin nach ~/code/RESCUE (overwrite)
# mit Projekt-Logging (Markdown-Tabellen) via proj_logger
# Version: v1.3.0
set -uo pipefail

VERSION="v1.3.0"
SRC_DIR="${HOME}/bin"
DST_DIR="${HOME}/code/RESCUE"
PROJECT_DIR="$PWD"
FORMAT="md"
DRY=0

usage() {
  cat <<'HLP'
_bin_zip_individual — pro *.sh in SRC ein einzelnes ZIP im DST erzeugen (overwrite) + Projekt-Logs

USAGE
  _bin_zip_individual [--src <dir>] [--dst <dir>] [--project <path>] [--format md|txt]
                      [--dry-run] [--help] [--version]

OPTIONEN
  --src <dir>       Quellverzeichnis (Default: ~/bin)
  --dst <dir>       Zielverzeichnis (Default: ~/code/RESCUE)
  --project <path>  Projekt-Root für Logs (<project>/.wiki/logs/...) (Default: aktuelles Verzeichnis)
  --format md|txt   Logformat (Default: md)
  --dry-run         nur planen und loggen, nichts ausführen (Exit 0)
  -h, --help        Hilfe
  --version         Version
HLP
}

# Args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --src) SRC_DIR="$2"; shift 2;;
    --dst) DST_DIR="$2"; shift 2;;
    --project) PROJECT_DIR="$2"; shift 2;;
    --format) FORMAT="$2"; shift 2;;
    --dry-run) DRY=1; shift;;
    --version) echo "$VERSION"; exit 0;;
    -h|--help) usage; exit 0;;
    *) echo "Unbekannter Parameter: $1" >&2; usage; exit 0;;
  esac
done

# Projekt-Root prüfen
if [[ ! -d "$PROJECT_DIR" ]]; then
  echo "Fehler: Projektverzeichnis existiert nicht: $PROJECT_DIR" >&2
  exit 2
fi
cd "$PROJECT_DIR"

# Logger laden (Fallback, falls nicht vorhanden)
if [[ -f "$HOME/bin/proj_logger.sh" ]]; then
  # shellcheck disable=SC1091
  source "$HOME/bin/proj_logger.sh"
else
  # Minimal-Fallback ohne Datei-Logging
  log_init(){ :; }
  log_info(){ echo "[INFO] $*"; }
  log_warn(){ echo "[WARN] $*" >&2; }
  log_error(){ echo "[ERROR] $*" >&2; }
  log_debug(){ echo "[DEBUG] $*"; }
  log_dry(){ echo "[DRY] $*"; }
  log_cmd(){ "$@"; return $?; }
  log_file(){ :; }
  log_section(){ :; }
  log_format(){ :; }
fi

# Log-Format setzen & init
case "$FORMAT" in md|txt) export PROJ_LOG_FORMAT="$FORMAT";; *) export PROJ_LOG_FORMAT="md";; esac
export PROJ_LOG_PREFIX="$(basename "$PROJECT_DIR")|bin_zip"
log_init

log_section "Plan"
log_info  "Version: ${VERSION}"
log_info  "SRC_DIR: ${SRC_DIR}"
log_info  "DST_DIR: ${DST_DIR}"
log_info  "DRY_RUN: ${DRY}"
log_info  "FORMAT: ${PROJ_LOG_FORMAT:-txt}"

# Zielordner
if (( DRY )); then
  log_dry "mkdir -p '${DST_DIR}'"
else
  mkdir -p "$DST_DIR" || { log_error "Zielordner nicht anlegbar: ${DST_DIR}"; exit 3; }
fi

# zip-Binary nur im echten Lauf prüfen
if (( ! DRY )); then
  if ! command -v zip >/dev/null 2>&1; then
    log_error "'zip' nicht gefunden (sudo apt-get install zip)."
    exit 4
  fi
fi

# SHA256 optional
HAS_SHA=0
if command -v sha256sum >/dev/null 2>&1; then HAS_SHA=1; fi

log_section "Zipping"

count=0; errors=0; total_in=0; total_out=0

# Dateien einsammeln (nur Top-Level *.sh)
mapfile -d '' files < <(find "$SRC_DIR" -maxdepth 1 -type f -name '*.sh' -print0 2>/dev/null || true)

if (( ${#files[@]} == 0 )); then
  log_warn "Keine *.sh in ${SRC_DIR} gefunden."
fi

for f in "${files[@]}"; do
  base="${f##*/}"
  name="${base%.sh}"
  out_zip="${DST_DIR}/${name}.zip"

  # Größen ermitteln (Input)
  in_sz="$(stat -c%s "$f" 2>/dev/null || wc -c <"$f" 2>/dev/null || echo 0)"

  if (( DRY )); then
    log_dry "rm -f '${out_zip}'"
    log_dry "zip -j -q -9 -X '${out_zip}' '${f}'"
    if (( HAS_SHA )); then
      log_dry "sha256sum '${f}'"
      log_dry "sha256sum '${out_zip}'"
    fi
    log_info "PLAN: ${base} → ${out_zip} (in=${in_sz} B)"
  else
    rm -f -- "$out_zip" 2>/dev/null || true
    # ohne '--' (Kompatibilität)
    if zip -j -q -9 -X "$out_zip" "$f" 1>/dev/null 2>/dev/null; then
      out_sz="$(stat -c%s "$out_zip" 2>/dev/null || wc -c <"$out_zip" 2>/dev/null || echo 0)"
      ratio="n/a"
      if [[ "$in_sz" =~ ^[0-9]+$ ]] && [[ "$out_sz" =~ ^[0-9]+$ ]] && (( in_sz > 0 )); then
        # Kompressionsrate in %
        ratio=$(( 100 - ( out_sz * 100 / in_sz ) ))
        (( ratio < 0 )) && ratio=0
      fi
      total_in=$((total_in + in_sz))
      total_out=$((total_out + out_sz))

      if (( HAS_SHA )); then
        sha_in="$(sha256sum "$f" | awk '{print $1}')"
        sha_out="$(sha256sum "$out_zip" | awk '{print $1}')"
        log_info "OK: ${base} → ${name}.zip | in=${in_sz} B | out=${out_sz} B | ratio=${ratio}%% | sha(in)=${sha_in} | sha(zip)=${sha_out}"
      else
        log_info "OK: ${base} → ${name}.zip | in=${in_sz} B | out=${out_sz} B | ratio=${ratio}%%"
      fi
    else
      errors=$((errors+1))
      log_error "ZIP FAIL: ${base} → ${name}.zip"
    fi
  fi

  count=$((count+1))
done

log_section "Summary"
if (( DRY )); then
  log_info  "Würde ${count} Datei(en) verarbeiten."
  log_info  "Ziel: ${DST_DIR}"
else
  log_info  "Fertig: ${count} Datei(en), Fehler: ${errors}"
  log_info  "Bytes in:  ${total_in}"
  log_info  "Bytes out: ${total_out}"
  if (( total_in > 0 )); then
    sum_ratio=$(( 100 - ( total_out * 100 / total_in ) ))
    (( sum_ratio < 0 )) && sum_ratio=0
    log_info  "Gesamt-Kompressionsrate: ${sum_ratio}%"
  fi
fi

printf "Logfile: %s\n" "$(log_file 2>/dev/null || echo '')"
exit 0
