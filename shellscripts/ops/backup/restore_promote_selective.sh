#!/usr/bin/env bash
# restore_promote_selective.sh — promote aus .restore/<ts>/files/ ins Projekt
# Version: v0.3.0 (Scopes uploads/storage-other bei WHAT=all, Markdown mit Totals)
set -uo pipefail

VERSION="v0.3.0"
DRY=1; YES=0; WHAT="uploads"; SRC=""; NO_BACKUP=0; FORMAT="md"

usage(){ cat <<'HLP'
restore_promote_selective — Dateien aus .restore/<ts>/files/ selektiv ins Projekt übernehmen

USAGE
  restore_promote_selective [--dry-run|--no-dry-run] [--yes]
                            [--what uploads|storage|all]
                            [--src <path/to/.restore/<ts>/files>]
                            [--no-backup]
                            [--format md|txt] [--help] [--version]

Standard: --dry-run, --what uploads
HLP
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY=1; shift;;
    --no-dry-run) DRY=0; shift;;
    --yes) YES=1; shift;;
    --what) WHAT="$2"; shift 2;;
    --src) SRC="$2"; shift 2;;
    --no-backup) NO_BACKUP=1; shift;;
    --format) FORMAT="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    --version) echo "$VERSION"; exit 0;;
    *) echo "Unbekannter Parameter: $1"; usage; exit 1;;
  esac
done

[[ -f .env ]] || { echo "Fehler: .env fehlt (im Projekt-Root ausführen)"; exit 2; }

# Logger
if [[ -f "$HOME/bin/proj_logger.sh" ]]; then source "$HOME/bin/proj_logger.sh"; fi
if ! type -t log_init >/dev/null 2>&1; then
  log_init(){ :; }; log_section(){ :; }
  log_info(){ echo "[INFO] $*"; }; log_warn(){ echo "[WARN] $*" >&2; }; log_error(){ echo "[ERROR] $*" >&2; }
  log_file(){ :; }; log_dry(){ echo "[DRY] $*"; }
fi
export PROJ_LOG_FORMAT="$FORMAT"
export PROJ_LOG_PREFIX="$(basename "$PWD")|promote"
log_init 2>/dev/null || true

fatal=0
run() {
  local cmd="$*"
  if (( DRY )); then log_dry "$cmd"; return 0; fi
  bash -c "$cmd"; local rc=$?
  (( rc != 0 )) && { log_warn "Fehler (rc=$rc): $cmd"; fatal=1; }
  return 0
}

# Quelle ermitteln
if [[ -z "$SRC" ]]; then
  SRC="$(ls -1dt .restore/*/files 2>/dev/null | head -n1 || true)"
fi
[[ -n "$SRC" && -d "$SRC" ]] || { log_error "Quelle nicht gefunden. Nutze --src <pfad/zu/.restore/<ts>/files>"; exit 3; }

log_section "Plan"
log_info "Version=$VERSION DRY=$DRY YES=$YES WHAT=$WHAT"
log_info "Quelle: $SRC"

# Scopes bestimmen
# Wir arbeiten mit parallelen Arrays:
#  INCLUDES[i]  = Quell-Unterordner relativ zu .restore/<ts>/files
#  NAMES[i]     = Anzeigename des Scopes
#  EXCL[i]      = optionale rsync --exclude=... (ein Eintrag, kann leer sein)
declare -a INCLUDES NAMES EXCL

case "$WHAT" in
  uploads)
    INCLUDES=( "storage/app/public/" )
    NAMES=( "uploads" )
    EXCL=( "" )
    ;;
  storage)
    INCLUDES=( "storage/app/" )
    NAMES=( "storage" )
    EXCL=( "" )
    ;;
  all)
    INCLUDES=( "storage/app/public/" "storage/app/" )
    NAMES=( "uploads" "storage-other" )
    EXCL=( "" "--exclude=public/**" )
    ;;
  *)
    log_error "--what muss uploads|storage|all sein"; exit 4;;
esac

# kleine Helfer
human() {
  local b=${1:-0} u=(B KB MB GB TB) i=0
  while (( b >= 1024 && i < ${#u[@]}-1 )); do b=$(( b/1024 )); ((i++)); done
  printf "%d %s" "$b" "${u[$i]}"
}
count_files() { local d="$1"; [[ -d "$d" ]] || { echo 0; return 0; }; find "$d" -type f 2>/dev/null | wc -l | awk '{print $1}'; }
sum_bytes()   { local d="$1"; [[ -d "$d" ]] || { echo 0; return 0; }; du -sb "$d" 2>/dev/null | awk '{print $1}'; }

rsync_plan_counts() {
  # zählt add/update/delete aus rsync --itemize-changes dry-run (mit optionalem --exclude)
  local src="$1" dst="$2" excl="$3"
  local added=0 updated=0 deleted=0
  if command -v rsync >/dev/null 2>&1; then
    # Kommando als Array aufbauen
    local -a cmd=(rsync -ai --delete --ignore-errors --dry-run)
    [[ -n "$excl" ]] && cmd+=("$excl")
    cmd+=("$src" "$dst")
    while IFS= read -r line; do
      case "$line" in
        \*deleting*) ((deleted++));;
        ">"*)
          if [[ "$line" == *"++++++++"* ]]; then ((added++)); else ((updated++)); fi
          ;;
      esac
    done < <("${cmd[@]}" 2>/dev/null || true)
  fi
  printf "%d %d %d\n" "$added" "$updated" "$deleted"
}

# Preview (gekürzt)
log_section "Preview (top-level)"
for idx in "${!INCLUDES[@]}"; do
  inc="${INCLUDES[$idx]}"; excl="${EXCL[$idx]}"
  if command -v rsync >/dev/null 2>&1; then
    log_info "rsync --dry-run ${inc} ${excl}"
    # Array bauen
    cmd=(rsync -ai --delete --ignore-errors --dry-run)
    [[ -n "$excl" ]] && cmd+=("$excl")
    cmd+=("$SRC/$inc" "./$inc")
    "${cmd[@]}" 2>/dev/null | sed -n '1,120p'
  else
    log_info "diff -ruN (gekürzt) $inc"
    diff -ruN "$SRC/$inc" "./$inc" 2>/dev/null | sed -n '1,120p' || true
  fi
done

# Sicherheitsfrage
if (( DRY == 0 )) && (( YES == 0 )); then
  echo "Promote wird Dateien ins Projekt kopieren. Fortfahren? [YES/no]"
  read -r a; [[ "$a" == "YES" ]] || { log_warn "Abgebrochen."; echo "Logfile: $(log_file 2>/dev/null || echo '')"; exit 0; }
fi

# Vorab-Metriken + Plan
declare -a BEFORE_SRC_FILES BEFORE_SRC_BYTES BEFORE_DST_FILES BEFORE_DST_BYTES
declare -a PLAN_ADD PLAN_UPD PLAN_DEL

for idx in "${!INCLUDES[@]}"; do
  inc="${INCLUDES[$idx]}"; s="$SRC/$inc"; d="./$inc"; excl="${EXCL[$idx]}"
  BEFORE_SRC_FILES[$idx]=$(count_files "$s")
  BEFORE_SRC_BYTES[$idx]=$(sum_bytes "$s")
  BEFORE_DST_FILES[$idx]=$(count_files "$d")
  BEFORE_DST_BYTES[$idx]=$(sum_bytes "$d")
  read -r a u del <<<"$(rsync_plan_counts "$s" "$d" "$excl")"
  PLAN_ADD[$idx]=$a; PLAN_UPD[$idx]=$u; PLAN_DEL[$idx]=$del
done

# Backup
TS="$(date +%Y%m%d_%H%M%S)"
BACKUP_DIR=".restore/_backup/$TS"
if (( NO_BACKUP )); then
  log_info "Backup: AUS"
else
  log_info "Backup: $BACKUP_DIR"
  run "mkdir -p '$BACKUP_DIR'"
  for inc in "${INCLUDES[@]}"; do
    if [[ -d "./$inc" ]]; then
      run "mkdir -p '$BACKUP_DIR/$inc'"
      run "cp -a './$inc.' '$BACKUP_DIR/' 2>/dev/null || cp -a './$inc' '$BACKUP_DIR/$inc'"
    fi
  done
fi

# Promote
log_section "Promote"
for idx in "${!INCLUDES[@]}"; do
  inc="${INCLUDES[$idx]}"; excl="${EXCL[$idx]}"
  if command -v rsync >/dev/null 2>&1; then
    cmd=(rsync -a --delete --ignore-errors --exclude='.env' --exclude='vendor/' --exclude='node_modules/')
    [[ -n "$excl" ]] && cmd+=("$excl")
    cmd+=("$SRC/$inc" "./$inc")
    run "${cmd[*]}"
  else
    run "mkdir -p './$inc'"
    run "cp -a '$SRC/$inc.' './$inc/' 2>/dev/null || cp -a '$SRC/$inc' './$inc/'"
  fi
  log_info "Übernommen: $inc"
done

# Nachher-Metriken / Projektion
declare -a AFTER_DST_FILES AFTER_DST_BYTES
for idx in "${!INCLUDES[@]}"; do
  inc="${INCLUDES[$idx]}"
  if (( DRY )); then
    BEFORE=${BEFORE_DST_FILES[$idx]}
    AFTER_DST_FILES[$idx]=$(( BEFORE - PLAN_DEL[$idx] + PLAN_ADD[$idx] ))
    AFTER_DST_BYTES[$idx]=0
  else
    AFTER_DST_FILES[$idx]=$(count_files "./$inc")
    AFTER_DST_BYTES[$idx]=$(sum_bytes "./$inc")
  fi
done

# Markdown-Summary + Totals
log_section "Summary"
printf "%s\n" "| Scope | Src files | Src size | Dest files (before) | Dest size (before) | +Add | ~Upd | -Del | Dest files (after) | Dest size (after) |"
printf "%s\n" "|------:|----------:|---------:|--------------------:|-------------------:|-----:|-----:|-----:|--------------------:|-------------------:|"

t_sf=0; t_sb=0; t_df=0; t_db=0; t_add=0; t_upd=0; t_del=0; t_af=0; t_ab=0

for idx in "${!INCLUDES[@]}"; do
  scope="${NAMES[$idx]}"
  sf=${BEFORE_SRC_FILES[$idx]}; sb=${BEFORE_SRC_BYTES[$idx]}
  df=${BEFORE_DST_FILES[$idx]}; db=${BEFORE_DST_BYTES[$idx]}
  a=${PLAN_ADD[$idx]}; u=${PLAN_UPD[$idx]}; del=${PLAN_DEL[$idx]}
  af=${AFTER_DST_FILES[$idx]}; ab=${AFTER_DST_BYTES[$idx]:-0}

  sbh=$(human "$sb"); dbh=$(human "$db"); abh="—"; (( DRY )) || abh=$(human "$ab")
  printf "| %s | %d | %s | %d | %s | %d | %d | %d | %d | %s |\n" \
    "$scope" "$sf" "$sbh" "$df" "$dbh" "$a" "$u" "$del" "$af" "$abh"

  t_sf=$(( t_sf + sf )); t_sb=$(( t_sb + sb ))
  t_df=$(( t_df + df )); t_db=$(( t_db + db ))
  t_add=$(( t_add + a )); t_upd=$(( t_upd + u )); t_del=$(( t_del + del ))
  t_af=$(( t_af + af )); t_ab=$(( t_ab + ab ))
done

t_sbh=$(human "$t_sb"); t_dbh=$(human "$t_db"); t_abh="—"; (( DRY )) || t_abh=$(human "$t_ab")
printf "| **Total** | **%d** | **%s** | **%d** | **%s** | **%d** | **%d** | **%d** | **%d** | **%s** |\n" \
  "$t_sf" "$t_sbh" "$t_df" "$t_dbh" "$t_add" "$t_upd" "$t_del" "$t_af" "$t_abh"

lf=""; if type -t log_file >/dev/null 2>&1; then lf="$(log_file || true)"; fi
printf "Logfile: %s\n" "${lf}"

(( fatal == 0 )) && exit 0 || exit 1
