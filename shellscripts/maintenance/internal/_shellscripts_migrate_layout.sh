#!/usr/bin/env bash
# shellscripts_migrate_layout v0.2.1
set -euo pipefail
IFS=$'\n\t'

SCRIPT_VERSION="v0.2.1"
ROOT="${HOME}/bin"
DEST="${ROOT}/shellscripts"
BACKUPS_ROOT="${ROOT}/backups"
TS="$(TZ='Europe/Berlin' date '+%Y%m%d_%H%M%S')"   # ohne Offset

# Default-Optionen
DRY_RUN=1
DEBUG=0

usage() {
  cat <<USAGE
shellscripts_migrate_layout ${SCRIPT_VERSION}
Verschiebt ~/bin/{install,maintenance,ops,patch,reports,scans} nach ~/bin/shellscripts/...
Erstellt vorher Dateibackups als Spiegel unter ~/bin/backups/<relativ_ab_ROOT>/<filename>.bak.${TS}

Optionen:
  --dry-run      Nur anzeigen (Default), keine Änderungen
  --apply        Ausführen (Backups + Move + Symlink-Rewrite)
  --debug        Ausführliche Ausgaben (set -x)
  -h|--help      Hilfe
USAGE
}

# Args
for a in "$@"; do
  case "$a" in
    --dry-run) DRY_RUN=1 ;;
    --apply)   DRY_RUN=0 ;;
    --debug)   DEBUG=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unbekannte Option: $a" >&2; usage; exit 64 ;;
  esac
done

[[ "${DEBUG}" -eq 1 ]] && set -x

# Gatekeeper
if [[ "$(pwd -P)" != "${ROOT}" ]]; then
  echo "Gatekeeper: Bitte aus ${ROOT} ausführen. Aktuelles PWD: $(pwd -P)" >&2
  exit 2
fi

DIRS=(install maintenance ops patch reports scans)

echo "== shellscripts_migrate_layout ${SCRIPT_VERSION} =="
echo "Zeit: $(TZ='Europe/Berlin' date '+%Y-%m-%d %H:%M:%S %Z')"
echo "Modus: $([[ ${DRY_RUN} -eq 1 ]] && echo 'DRY-RUN' || echo 'APPLY')"
echo "ROOT: ${ROOT}"
echo "DEST: ${DEST}"
echo "BACKUPS_ROOT (Spiegel zu shellscripts): ${BACKUPS_ROOT}"
echo

mkdir -p "${DEST}"
mkdir -p "${BACKUPS_ROOT}"

# -- PLAN: welche Verzeichnisse würden verschoben?
echo "-- PLAN: Directory-Moves --"
for d in "${DIRS[@]}"; do
  SRC="${ROOT}/${d}"
  TGT="${DEST}/${d}"
  if [[ -d "${SRC}" ]]; then
    if [[ -e "${TGT}" ]]; then
      echo "SKIP: ${SRC} → ${TGT} (Ziel existiert bereits)"
    else
      echo "MOVE: ${SRC} → ${TGT}"
    fi
  else
    echo "MISS: ${SRC} (nicht vorhanden)"
  fi
done
echo

# -- PLAN: Symlink-Umbiegungen im ~/bin-Root
echo "-- PLAN: Symlink-Rewrites (Top-Level) --"
while IFS= read -r -d '' link; do
  tgt_abs="$(readlink -f "${link}" || true)"
  [[ -z "${tgt_abs}" ]] && { echo "SKIP: Broken symlink: ${link}"; continue; }
  case "${tgt_abs}" in
    "${ROOT}/install/"*|\
    "${ROOT}/maintenance/"*|\
    "${ROOT}/ops/"*|\
    "${ROOT}/patch/"*|\
    "${ROOT}/reports/"*|\
    "${ROOT}/scans/"*)
      new="${tgt_abs/#${ROOT}\//${DEST}/}"
      echo "RELINK: ${link}  =>  ${new}"
    ;;
    *) : ;;
  esac
done < <(find "${ROOT}" -maxdepth 1 -xtype l -print0)
echo

# -- PLAN: Backups (Spiegelstruktur unter ~/bin/backups, Dateien als *.bak.<TS>)
echo "-- PLAN: Backups (Datei-Ebene) --"
for d in "${DIRS[@]}"; do
  SRC="${ROOT}/${d}"
  [[ -d "${SRC}" ]] || continue
  while IFS= read -r -d '' f; do
    rel="${f#${ROOT}/}"                             # z.B. maintenance/internal/_tool.sh
    back_path="${BACKUPS_ROOT}/${rel}"              # ~/bin/backups/maintenance/internal/_tool.sh
    back_dir="$(dirname "${back_path}")"
    back_file="${back_dir}/$(basename "${back_path}").bak.${TS}"
    echo "BACKUP: ${f}  ->  ${back_file}"
  done < <(find "${SRC}" -type f -print0)
done
echo

# Ende im DRY-RUN
if [[ "${DRY_RUN}" -eq 1 ]]; then
  echo "Hinweis: --dry-run aktiv. Zum Ausführen: bash maintenance/internal/_shellscripts_migrate_layout.sh --apply"
  exit 0
fi

# -- APPLY: Backups schreiben
echo "-- APPLY: Backups schreiben --"
for d in "${DIRS[@]}"; do
  SRC="${ROOT}/${d}"
  [[ -d "${SRC}" ]] || continue
  while IFS= read -r -d '' f; do
    rel="${f#${ROOT}/}"
    back_path="${BACKUPS_ROOT}/${rel}"
    back_dir="$(dirname "${back_path}")"
    back_file="${back_dir}/$(basename "${back_path}").bak.${TS}"
    mkdir -p "${back_dir}"
    cp -a -- "${f}" "${back_file}"
    echo "BACKUP: ${f}  ->  ${back_file}"
  done < <(find "${SRC}" -type f -print0)
done
echo

# -- APPLY: Verschieben der Verzeichnisse
echo "-- APPLY: Verschieben --"
for d in "${DIRS[@]}"; do
  SRC="${ROOT}/${d}"
  TGT="${DEST}/${d}"
  if [[ -d "${SRC}" ]]; then
    if [[ -e "${TGT}" ]]; then
      echo "SKIP: Ziel existiert bereits: ${TGT}"
    else
      mv -- "${SRC}" "${DEST}/"
      echo "MOVED: ${SRC} -> ${TGT}"
    fi
  fi
done
echo

# -- APPLY: Symlinks im ~/bin-Root neu setzen
echo "-- APPLY: Symlink-Rewrites --"
while IFS= read -r -d '' link; do
  tgt_abs="$(readlink -f "${link}" || true)"
  [[ -z "${tgt_abs}" ]] && { echo "SKIP: Broken symlink: ${link}"; continue; }
  case "${tgt_abs}" in
    "${ROOT}/install/"*|\
    "${ROOT}/maintenance/"*|\
    "${ROOT}/ops/"*|\
    "${ROOT}/patch/"*|\
    "${ROOT}/reports/"*|\
    "${ROOT}/scans/"*)
      new="${tgt_abs/#${ROOT}\//${DEST}/}"
      if [[ -e "${new}" ]]; then
        ln -sfn -- "${new}" "${link}"
        echo "RELINKED: ${link} -> ${new}"
      else
        echo "WARN: Ausgelassen, Ziel nicht gefunden: ${new}  (für ${link})"
      fi
    ;;
    *) : ;;
  esac
done < <(find "${ROOT}" -maxdepth 1 -xtype l -print0)
echo

echo "Fertig. Backups unter: ${BACKUPS_ROOT}  (Zeitstempel: ${TS})"
echo "Zeit: $(TZ='Europe/Berlin' date '+%Y-%m-%d %H:%M:%S %Z')"
