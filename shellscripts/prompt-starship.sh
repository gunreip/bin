#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# prompt-starship — toggelt die Starship-Prompt in ~/.bashrc
#   Optionen: --install | --on | --off | --state
# -----------------------------------------------------------------------------
set -euo pipefail
IFS=$'\n\t'

BASHRC="${HOME}/.bashrc"
CFG_DIR="${HOME}/.config/starship"
STATE_FILE="${CFG_DIR}/enabled"

START_MARK="# >>> STARSHIP (managed) >>>"
END_MARK="# <<< STARSHIP (managed) <<<"
WRAP_START="# >>> STARSHIP wrapper (managed) >>>"
WRAP_END="# <<< STARSHIP wrapper (managed) <<<"

ensure_block() {
  mkdir -p "${CFG_DIR}"
  [ -f "${STATE_FILE}" ] || echo "1" > "${STATE_FILE}"   # Default: ON

  local tmp="${BASHRC}.tmp.$$"
  {
    # 1) Bestehende managed-Blöcke entfernen + alle fremden "starship init bash" Zeilen entschärfen
    awk -v START="$START_MARK" -v END="$END_MARK" '
      BEGIN{inblock=0}
      {
        if ($0==START) {inblock=1; next}
        if (inblock && $0==END) {inblock=0; next}
        # Jede Zeile, die starship init bash enthält (egal ob mit eval/Quotes) deaktivieren
        if (inblock==0 && $0 ~ /starship[[:space:]]+init[[:space:]]+bash/) {
          print "# (disabled by prompt-starship) " $0
          next
        }
        print
      }
    ' "${BASHRC}" 2>/dev/null || true

    # 2) Frischen managed-Block anhängen
    cat <<BLOCK
${START_MARK}
# Toggle: starship --on | starship --off | starship --state
STARSHIP_STATE_FILE="\$HOME/.config/starship/enabled"
STARSHIP_ENABLED="1"
if [ -r "\$STARSHIP_STATE_FILE" ]; then
  STARSHIP_ENABLED="\$(cat "\$STARSHIP_STATE_FILE" 2>/dev/null || echo 1)"
fi
if [ "\$STARSHIP_ENABLED" = "1" ]; then
  command -v starship >/dev/null 2>&1 && eval "\$(starship init bash)"
fi
${END_MARK}
BLOCK
  } > "${tmp}"
  mv "${tmp}" "${BASHRC}"
}

ensure_wrapper() {
  # Wrapper nur einmal einfügen (fängt --on/--off/--state ab und re-exec't die Shell)
  grep -Fq "${WRAP_START}" "${BASHRC}" 2>/dev/null && return 0
  {
    printf '\n%s\n' "${WRAP_START}"
    cat <<'W'
starship() {
  case "${1:-}" in
    --on)
      mkdir -p "$HOME/.config/starship"
      echo 1 > "$HOME/.config/starship/enabled"
      command -v prompt-starship >/dev/null 2>&1 && command prompt-starship --install >/dev/null 2>&1 || true
      echo "Starship: ON → Shell wird neu gestartet…"
      exec bash -l
      ;;
    --off)
      mkdir -p "$HOME/.config/starship"
      echo 0 > "$HOME/.config/starship/enabled"
      command -v prompt-starship >/dev/null 2>&1 && command prompt-starship --install >/dev/null 2>&1 || true
      echo "Starship: OFF → Shell wird neu gestartet…"
      exec bash -l
      ;;
    --state)
      if [ -r "$HOME/.config/starship/enabled" ] && [ "$(cat "$HOME/.config/starship/enabled" 2>/dev/null)" = "0" ]; then
        echo "off"
      else
        echo "on"
      fi
      ;;
    *)
      command starship "$@"
      ;;
  esac
}
W
    printf '%s\n' "${WRAP_END}"
  } >> "${BASHRC}"
}

set_state() {  # 1|0
  mkdir -p "${CFG_DIR}"
  echo "$1" > "${STATE_FILE}"
}

show_state() {
  local s="1"
  [ -r "${STATE_FILE}" ] && s="$(cat "${STATE_FILE}" 2>/dev/null || echo 1)"
  if [ "$s" = "1" ]; then echo "on"; else echo "off"; fi
}

cmd="${1:---state}"
case "$cmd" in
  --install)
    cp -p "${BASHRC}" "${BASHRC}.prompt-starship.$(date +%Y%m%d-%H%M%S).bak" 2>/dev/null || true
    ensure_block
    ensure_wrapper
    echo "install: OK (Managed-Block + Wrapper in ~/.bashrc)."
    ;;
  --on)
    ensure_block; ensure_wrapper; set_state 1
    echo "on"
    ;;
  --off)
    ensure_block; ensure_wrapper; set_state 0
    echo "off"
    ;;
  --state)
    ensure_block; ensure_wrapper; show_state
    ;;
  *)
    echo "Usage: prompt-starship --install | --on | --off | --state"
    exit 2
    ;;
esac
