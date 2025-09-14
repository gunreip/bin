#!/usr/bin/env bash
# _dev_aliases.sh — Shell-Aliases/Funktionen für Laravel-Dev-Komfort (bin-only)
# Version: 0.1.0
# Changelog:
# - 0.1.0: Initial (init/install/doctor, a/t/rr/cc/v/hcb, Reports nach ~/bin/.wiki/dev)
set -o pipefail

VERSION="0.1.0"
SCRIPT_NAME="_dev_aliases"

usage(){ cat <<'EOF'
_dev_aliases — Developer-Aliases/Funktionen
Usage:
  _dev_aliases init                     # gibt Shell-Snippet aus (zum "eval")
  _dev_aliases install [--dry-run]      # schreibt eval-Zeile in dein Shell-RC (idempotent)
  _dev_aliases doctor                   # prüft Setup & zeigt Hinweise
  _dev_aliases --version | -h|--help

Hinweise:
- Bin-only: keine Projekt-Annahme. Funktionen wie `a` finden das Projekt-Root automatisch (Datei "artisan").
- Reports/Logs: ~/bin/.wiki/dev/ (mit last.txt/last.log), Rotation 30 Tage
EOF
}

# Defaults (bin-only-Konventionen)
DRY_RUN=0
COLOR_MODE="auto"   # auto|always|never
DEBUG=0             # nach Stabilisierung standardmäßig AUS

# Farben
setup_colors(){ local use=0
  case "$COLOR_MODE" in always) use=1;; never) use=0;; auto) [[ -t 1 ]] && use=1 || use=0;; esac
  if [[ $use -eq 1 ]]; then BOLD=$'\e[1m'; DIM=$'\e[2m'; RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; BLUE=$'\e[34m'; RESET=$'\e[0m'
  else BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; RESET=""; fi
}

# Reporting/Logs (bin/.wiki)
RUN_ROOT="$HOME/bin/.wiki/dev"; mkdir -p "$RUN_ROOT"
find "$RUN_ROOT" -type f -mtime +30 -delete 2>/dev/null || true
ts(){ date +"%Y-%m-%d %H:%M:%S%z"; }
start_run(){ RUN_TS="$(date +%F_%H%M%S)"; RUN_LOG="$RUN_ROOT/_run_${RUN_TS}.log"; : >"$RUN_LOG"; }
log(){ printf "[%s] %s\n" "$(ts)" "$*" >> "$RUN_LOG"; }
write_last(){ printf "%s\n" "$1" > "$RUN_ROOT/last.txt"; cp -f "$RUN_LOG" "$RUN_ROOT/last.log" 2>/dev/null || true; }

# --- Shell-Snippet (nur stdout, keine Deko!) ---
print_init_snippet(){
cat <<'EOS'
# --- _dev_aliases (init) ---
__dev_find_root() {
  local r="$PWD"
  while [[ "$r" != "/" ]]; do
    [[ -f "$r/artisan" ]] && { printf "%s" "$r"; return 0; }
    r="$(dirname "$r")"
  done
  return 1
}

a() {
  local r
  r="$(__dev_find_root)" || { echo "[a] kein 'artisan' im Pfad gefunden (im Projekt laufen)">&2; return 2; }
  ( cd "$r" && XDEBUG_MODE="${XDEBUG_MODE:-off}" php artisan "$@" )
}

artisan() { a "$@"; }               # optionaler Alias-Name
t() { a tinker "$@"; }              # Tinker
rr(){ a route:clear && a route:cache; }     # Routes neu
cc(){ a config:clear && a config:cache; }   # Config neu

pv(){ php -v 2>/dev/null | head -n1; }
cv(){ command -v composer >/dev/null && composer --version || true; }
av(){ a --version 2>/dev/null || true; }
v(){ pv; cv; av; }                  # Versions-Shortreport

hcb(){                               # Health-Report, wenn installiert
  local r; r="$(__dev_find_root)" || { echo "[hcb] kein Projekt-Root">&2; return 2; }
  if command -v health_check_basic >/dev/null; then ( cd "$r" && health_check_basic --format md ); else echo "[hcb] 'health_check_basic' nicht gefunden">&2; fi
}
# --- /_dev_aliases (init) ---
EOS
}

# --- RC-Datei finden & patchen ---
detect_rc(){
  # Bevorzugt zsh, dann bash
  if [[ -n "${ZSH_VERSION:-}" || "${SHELL##*/}" = "zsh" ]]; then echo "$HOME/.zshrc"
  elif [[ -n "${BASH_VERSION:-}" || "${SHELL##*/}" = "bash" ]]; then echo "$HOME/.bashrc"
  else echo "$HOME/.bashrc"
  fi
}

install_rc(){
  local rc="$1"; local begin="# >>> _dev_aliases >>>"; local end="# <<< _dev_aliases <<<"
  local block="eval \"\$(_dev_aliases init)\""
  [[ ! -f "$rc" ]] && touch "$rc"
  # Bestehenden Block entfernen (idempotent)
  if grep -q "$begin" "$rc"; then
    $DRY_RUN -eq 1 && true || awk -v b="$begin" -v e="$end" 'BEGIN{skip=0} {if($0~b){skip=1;next} if($0~e){skip=0;next} if(!skip)print}' "$rc" > "$rc.tmp" && mv "$rc.tmp" "$rc"
  fi
  # Block ans Ende anhängen
  if [[ $DRY_RUN -eq 1 ]]; then
    return 0
  else
    {
      echo "$begin"
      echo "$block"
      echo "$end"
    } >> "$rc"
  fi
}

# --- Main ---
setup_colors
start_run

case "${1:-}" in
  init)
    # Wichtig: nur Snippet ausgeben, keine Logs/Colors
    print_init_snippet
    exit 0
    ;;
  install)
    shift
    while [[ $# -gt 0 ]]; do
      case "$1" in --dry-run) DRY_RUN=1;; --color) COLOR_MODE="${2:-auto}"; shift;; --debug) DEBUG=1;; *) ;; esac; shift; done
    RC="$(detect_rc)"
    MSG="Installiere _dev_aliases in: $RC   (idempotent; DRY_RUN=$DRY_RUN)"
    log "$MSG"; [[ $DEBUG -eq 1 ]] && echo "$MSG" >&2
    install_rc "$RC"
    SUM="Füge in $RC den Block hinzu: eval \"\$(_dev_aliases init)\""
    write_last "$SUM"
    echo "${GREEN}✅ _dev_aliases installiert.${RESET}  Öffne neue Shell oder: ${BOLD}eval \"\$(_dev_aliases init)\"${RESET}"
    echo "   RC-Datei: $RC"
    ;;
  doctor)
    RC="$(detect_rc)"
    ok="NEIN"; grep -q 'eval "\$(_dev_aliases init)"' "$RC" 2>/dev/null && ok="JA"
    REPORT="Shell: ${SHELL##*/}\nRC: $RC\nInit-Eintrag vorhanden: $ok\nTest: a --version (im Projekt ausführen)\n"
    write_last "$REPORT"
    printf "%b" "$REPORT"
    ;;
  --version)
    echo "$VERSION";;
  -h|--help|"")
    usage;;
  *)
    echo "Unknown command: $1" >&2; usage; exit 2;;
esac
