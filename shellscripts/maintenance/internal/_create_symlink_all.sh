#!/usr/bin/env bash
# _create_symlink_all.sh — erzeugt in ~/bin für jede *.sh-Datei einen gleichnamigen Symlink ohne .sh
# Läuft NUR in ~/bin. Keine Aktionen außerhalb. Überschreibt nichts.

set -euo pipefail
VERSION="v0.2.0"
DRY=0
CLEAN_STALE=0
FORCE=0

help() {
  cat <<'HLP'
_create_symlink_all.sh — Alias-Symlinks ohne .sh in ~/bin erzeugen

USAGE
  ./_create_symlink_all.sh [--dry-run] [--clean-stale] [--force] [--help] [--version]

OPTIONEN
  --dry-run     Nur anzeigen, was passieren würde
  --clean-stale Verwaiste Symlinks (Ziel existiert nicht) entfernen
  --force       Vorhandene, abweichende Symlinks durch korrekte ersetzen
  --help        Hilfe
  --version     Version ausgeben

HINWEISE
  • Muss in ~/bin ausgeführt werden (Gatekeeper).
  • Für jede Datei *.sh wird (falls noch nicht vorhanden) ein Symlink ohne .sh angelegt.
  • Bestehende Dateien/Symlinks werden NICHT überschrieben (außer mit --force).
HLP
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY=1; shift;;
    --clean-stale) CLEAN_STALE=1; shift;;
    --force) FORCE=1; shift;;
    --version) echo "$VERSION"; exit 0;;
    -h|--help) help; exit 0;;
    *) echo "Unbekannter Parameter: $1" >&2; help; exit 1;;
  esac
done

BIN="${HOME}/bin"
if [[ "$(pwd -P)" != "$BIN" ]]; then
  echo "Fehler: Bitte in ${BIN} ausführen." >&2
  exit 2
fi

run() { if [[ "$DRY" -eq 1 ]]; then echo "[DRY] $*"; else eval "$@"; fi; }

created=0; skipped=0; warned=0; replaced=0; cleaned=0

# optional: verwaiste Symlinks aufräumen
if [[ "$CLEAN_STALE" -eq 1 ]]; then
  while IFS= read -r -d '' link; do
    tgt="$(readlink -f "$link" || true)"
    if [[ -z "$tgt" || ! -e "$tgt" ]]; then
      run "rm -f '$link'"
      echo "[CLEAN] entfernt: $link"
      ((cleaned++)) || true
    fi
  done < <(find . -maxdepth 1 -type l -print0)
fi

# für alle *.sh im aktuellen Ordner
shopt -s nullglob
for f in *.sh; do
  [[ "$f" == "_create_symlink_all.sh" ]] && continue
  # Quelldatei ausführbar machen
  run "chmod +x '$f'"

  base="${f%.sh}"
  # Wenn Ziel identisch ist, "foo" nicht auf sich selbst verlinken
  [[ "$base" == "$f" ]] && continue

  if [[ -L "$base" ]]; then
    tgt="$(readlink -f "$base" 2>/dev/null || true)"
    real="$(readlink -f "$f" 2>/dev/null || true)"
    if [[ -n "$tgt" && "$tgt" == "$real" ]]; then
      echo "[SKIP] Symlink existiert bereits: $base -> $f"
      ((skipped++)) || true
      continue
    else
      if [[ "$FORCE" -eq 1 ]]; then
        run "rm -f '$base'"
        run "ln -s '$f' '$base'"
        echo "[REPLACE] $base -> $f"
        ((replaced++)) || true
      else
        echo "[WARN] Abweichender Symlink vorhanden: $base -> $(readlink "$base"); überspringe (nutze --force zum Ersetzen)." >&2
        ((warned++)) || true
      fi
      continue
    fi
  fi

  if [[ -e "$base" ]]; then
    echo "[WARN] $base existiert bereits (Datei/Ordner). Kein Symlink erstellt." >&2
    ((warned++)) || true
    continue
  fi

  run "ln -s '$f' '$base'"
  echo "[OK] ln -s '$f' '$base'"
  ((created++)) || true
done

echo "Fertig. created=$created replaced=$replaced skipped=$skipped warned=$warned cleaned=$cleaned"
