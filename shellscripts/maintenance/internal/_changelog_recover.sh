#!/usr/bin/env bash
# =====================================================================
#  _changelog_recover.sh  — Rekonstruiert CHANGELOG aus Git-Historie
#  SCRIPT_VERSION="v0.1.0"
# =====================================================================
# CHANGELOG
# v0.1.0 (2025-09-14) ✅
# - Erste Version: Rekonstruktion aus git, Vorschau + optionales Patchen des Skriptkopfs.
# - Standard-Icons festgelegt: OK=✅, Warn=⚡, Fail=❌, Unknown=⁉️
#
# shellcheck disable=SC2317,SC2155
#
# =====================================================================

set -euo pipefail
IFS=$'\n\t'

# --------------------------- Config / Defaults ------------------------
PROG_NAME="changelog_recover"
DEFAULT_ROTATION=5
DEFAULT_STEPS=0   # 0=still, 1=grobe Schritte, 2=Details, 3=Debug
UNICODE="yes"

# Icon-Set (fest nach User-Vorgabe)
ICON_OK="✅"
ICON_WARN="⚡"
ICON_FAIL="❌"
ICON_UNKNOWN="⁉️"

# Farben nur wenn TTY
if [ -t 1 ]; then
  C_RESET=$'\033[0m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_BLUE=$'\033[34m'
else
  C_RESET=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_BLUE=""
fi

# --------------------------- Helpers ----------------------------------
die(){ echo -e "${C_RED}ERROR:${C_RESET} $*" >&2; exit 1; }
msg(){ local lvl="$1"; shift; local txt="$*"; 
  case "$lvl" in
    step) [ "$STEPS" -ge 1 ] && echo -e "${C_BLUE}▶${C_RESET} $txt" ;;
    info) [ "$STEPS" -ge 2 ] && echo "  - $txt" ;;
    dbg)  [ "$STEPS" -ge 3 ] && echo "    · $txt" ;;
    ok)   echo -e "${C_GREEN}✔${C_RESET} $txt" ;;
    warn) echo -e "${C_YELLOW}⚡${C_RESET} $txt" ;;
  esac
}

gatekeeper(){
  local cwd
  cwd="$(pwd)"
  if [ "${cwd%/}" != "${HOME}/bin" ]; then
    echo -e "${C_RED}Gatekeeper:${C_RESET} Bitte aus <tt>~/bin</tt> ausführen. Aktuell: \`$cwd\`" >&2
    exit 2
  fi
}

usage(){
  cat <<USAGE
$PROG_NAME — Rekonstruiert CHANGELOG aus Git-Historie

Nutzung:
  $PROG_NAME --script=REL_PATH [--apply] [--reduce] [--rotation=N] [--dry-run] [--steps=0|1|2|3]

Wichtig:
  --script       Relativer Pfad unter ~/bin/shellscripts/... (z. B. maintenance/internal/_changelog_extract.sh)
  --apply        Patcht den Skriptkopf (mit Backup) – ohne dies nur Vorschau/Write des CHANGELOG-Spiegels
  --reduce       Kürzt den Quellkopf nach Write auf neuesten Eintrag (optional)
  --rotation=N   Snapshot-Aufbewahrung (Default ${DEFAULT_ROTATION})
  --dry-run      Nichts verändern, nur anzeigen (Default)
  --steps=...    0 still, 1 Schritte, 2 Details, 3 Debug

Flag-Erklärungen:
  --apply        wendet Änderungen an der Quelldatei an
  --reduce       reduziert die Historie im Skriptkopf auf den letzten Eintrag
  --rotation     legt Anzahl zu behaltender Snapshots in changelogs/ fest
  --dry-run      führt keinen schreibenden Schritt aus
  --steps        steuert die Ausgabemenge

USAGE
}

# Heuristik: Icon aus Commit-Message
icon_from_msg(){
  local msg="${1,,}"
  if [[ "$msg" =~ fix|bug|hotfix|pass|green|ok ]]; then echo "$ICON_OK"; return; fi
  if [[ "$msg" =~ warn|deprec|slow|perf|todo|caution|might ]]; then echo "$ICON_WARN"; return; fi
  if [[ "$msg" =~ fail|broken|revert|rollback|red|error ]]; then echo "$ICON_FAIL"; return; fi
  echo "$ICON_UNKNOWN"
}

# Extrahiert SCRIPT_VERSION aus Dateiinhalt (echo ohne v-Präfix normalisiert auf vX.Y.Z)
extract_version_from_blob(){
  awk '
    match($0, /SCRIPT_VERSION="v?[0-9]+\.[0-9]+\.[0-9]+"/) {
      ver=$0; gsub(/.*SCRIPT_VERSION="(v?[0-9]+\.[0-9]+\.[0-9]+)".*/, "\\1", ver);
      if (ver !~ /^v/) ver="v" ver;
      print ver; exit
    }
  ' 2>/dev/null
}

# Baut Mirror-Pfad: ~/bin/changelogs/<mirror_of_shellscripts_path>/CHANGELOG-<script>.md
mirror_path_for(){
  local rel="$1" # e.g. maintenance/internal/_changelog_extract.sh
  local script_name="$(basename "$rel")"
  local mirror_dir="${HOME}/bin/changelogs/${rel%/*}"
  mkdir -p "$mirror_dir"
  echo "${mirror_dir}/CHANGELOG-${script_name%.sh}.md"
}

# Patcht Skriptkopf (CHANGELOG-Block ersetzen)
patch_script_header(){
  local file="$1" tmpfile="$2"
  # Backup
  cp -a "$file" "$BACKUP_PATH"
  # Ersetzen: zwischen Zeile 'CHANGELOG' und erster Leerzeile nach 'shellcheck disable=' Block
  # robust: wir ersetzen ab Zeile 'CHANGELOG' bis zur nächsten Leerzeile nach 'shellcheck disable=' Zeile
  awk -v repl="$(sed 's/[&/\]/\\&/g' "$tmpfile")" '
    BEGIN{in_ch=0; printed=0}
    /^# *CHANGELOG/ {print; print repl; skip=1; in_ch=1; next}
    { if(!in_ch) print; else {
        # stop skipping after we detect a blank line following a "shellcheck disable" section
        if ($0 ~ /^# *shellcheck disable=/) {hold=1; next}
        if (hold && $0 ~ /^$/) {in_ch=0; hold=0; next} # end of block
      }
    }
  ' "$file" > "${file}.tmp"
  mv "${file}.tmp" "$file"
}

# Rotation für Snapshots im changelogs/-Mirror
rotate_keep(){
  local dir="$1" base="$2" keep="$3"
  ls -1t "$dir"/"$base".*.md 2>/dev/null | tail -n +$((keep+1)) | while read -r old; do rm -f "$old"; done
}

# --------------------------- Main -------------------------------------
main(){
  gatekeeper

  local SCRIPT_REL="" APPLY="no" REDUCE="no" ROTATION="$DEFAULT_ROTATION" DRYRUN="yes" STEPS="$DEFAULT_STEPS"

  for arg in "$@"; do
    case "$arg" in
      --script=*) SCRIPT_REL="${arg#*=}" ;;
      --apply)    APPLY="yes" ;;
      --reduce)   REDUCE="yes" ;;
      --rotation=*) ROTATION="${arg#*=}" ;;
      --dry-run)  DRYRUN="yes" ;;
      --no-dry-run) DRYRUN="no" ;;
      --steps=*)  STEPS="${arg#*=}" ;;
      -h|--help)  usage; exit 0 ;;
      *)          ;;
    esac
  done

  [ -z "$SCRIPT_REL" ] && usage && die "--script=... fehlt."
  local SCRIPT_PATH="${HOME}/bin/shellscripts/${SCRIPT_REL}"
  [ -f "$SCRIPT_PATH" ] || die "Nicht gefunden: \`$SCRIPT_PATH\`"

  # Git-Root finden
  local GIT_ROOT
  GIT_ROOT="$(git -C "${HOME}/bin" rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$GIT_ROOT" ] || die "Kein Git-Repository unter ~/bin gefunden."

  msg step "Analysiere Git-Historie für \`$SCRIPT_REL\`"
  msg info "Git-Root: $GIT_ROOT"

  # Commits, die die Datei betreffen (mit --follow)
  local commits
  commits="$(git -C "$GIT_ROOT" log --follow --pretty=format:'%H|%ad|%s' --date=short -- "bin/shellscripts/${SCRIPT_REL}" || true)"
  [ -n "$commits" ] || die "Keine Historie für Datei gefunden."

  # Version -> (date, icon, messages[]) sammeln
  declare -A VER_DATE VER_ICON VER_MSGS
  while IFS='|' read -r sha date subj; do
    # Dateiinhalt der Version lesen
    local blob
    blob="$(git -C "$GIT_ROOT" show "${sha}:bin/shellscripts/${SCRIPT_REL}" || true)"
    [ -n "$blob" ] || continue
    local ver
    ver="$(printf "%s\n" "$blob" | extract_version_from_blob || true)"
    [ -z "$ver" ] && ver="v?.?.?" # Fallback

    # Nachricht / Icon
    local icon
    icon="$(icon_from_msg "$subj")"
    VER_DATE["$ver"]="${VER_DATE["$ver"]:-$date}"
    VER_ICON["$ver"]="${VER_ICON["$ver"]:-$icon}"
    # Messages akkumulieren (einzigartige)
    local key="${VER_MSGS["$ver"]:-}"
    if [[ "$key" != *"$subj"* ]]; then
      VER_MSGS["$ver"]="${key}- ${subj}\n"
    fi
    msg dbg "$ver @ $date :: $subj"
  done <<< "$commits"

  # Versionen in absteigender Reihenfolge sortieren (semver, grob)
  local versions
  versions="$(printf "%s\n" "${!VER_DATE[@]}" | sort -Vr)"

  # Changelog-Block bauen
  local tmpch
  tmpch="$(mktemp)"
  while read -r ver; do
    [ -z "$ver" ] && continue
    local dt="${VER_DATE["$ver"]}"
    local ic="${VER_ICON["$ver"]:-$ICON_UNKNOWN}"
    printf "%s (%s) %s\n" "$ver" "$dt" "$ic" >> "$tmpch"
    # Messages
    printf "%b" "${VER_MSGS["$ver"]}" >> "$tmpch"
    printf "\n" >> "$tmpch"
  done <<< "$versions"

  # Mirror schreiben
  local mirror_file mirror_dir base ts
  mirror_file="$(mirror_path_for "$SCRIPT_REL")"
  mirror_dir="$(dirname "$mirror_file")"
  base="$(basename "$mirror_file" .md)"
  ts="$(date +%Y%m%d-%H%M%S)"
  local snapshot="${mirror_dir}/${base}.${ts}.md"

  msg step "Schreibe Mirror: \`$mirror_file\`"
  if [ "$DRYRUN" = "yes" ]; then
    msg warn "dry-run: Ausgabe nur in Terminal"
    echo "----- CHANGELOG (rekonstruiert) -----"
    cat "$tmpch"
  else
    cp -a "$tmpch" "$mirror_file"
    cp -a "$tmpch" "$snapshot"
    rotate_keep "$mirror_dir" "$base" "$ROTATION"
    msg ok "mirror write: ${mirror_file}"
  fi

  # Optional Patch
  if [ "$APPLY" = "yes" ]; then
    msg step "Patche Skriptkopf von \`$SCRIPT_PATH\`"
    BACKUP_PATH="${HOME}/bin/backups/$(basename "$SCRIPT_PATH").$ts.bak"
    if [ "$DRYRUN" = "yes" ]; then
      msg warn "dry-run: Patch wird nicht angewendet"
    else
      patch_script_header "$SCRIPT_PATH" "$tmpch"
      msg ok "Patch angewendet. Backup: \`$BACKUP_PATH\`"
      if [ "$REDUCE" = "yes" ]; then
        msg step "Reduce aktiv: Historie im Kopf auf neuesten Eintrag kürzen (nicht implementiert, TODO)"
      fi
    fi
  fi

  rm -f "$tmpch"
}

main "$@"
