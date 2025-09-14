#!/usr/bin/env bash
# proj_logger.sh — einfache Logger-Library für Projekt-Skripte
# Ziel: <project>/.wiki/logs/<YYYY-MM-DD>.{log|md}
# Retention: 30 Tage (löscht alte Logs leise)
# Format: PROJ_LOG_FORMAT=txt|md  (Default: txt)
# Einbindung:  source ~/bin/proj_logger.sh
# Version: v1.2.1

: "${PROJ_LOG_RETENTION_DAYS:=30}"
: "${PROJ_LOG_STDERR:=0}"
: "${PROJ_LOG_PREFIX:=""}"
: "${PROJ_LOG_LEVEL_DEFAULT:=INFO}"
: "${PROJ_LOG_FORMAT:=txt}"     # txt | md

PROJ_LOG_FILE=""
PROJ_LOG_DIR=""
PROJ_LOG_SESSION_ID="${PROJ_LOG_SESSION_ID:-$(date +%Y%m%dT%H%M%S)-$$}"

_proj_log_ts() { date "+%F %T%z"; }

_proj_log_md_escape() {
  sed -e 's/\\/\\\\/g' -e 's/|/\\|/g' -e 's/`/\\`/g' -e ':a;N;$!ba;s/\n/<br\/>/g'
}

_proj_log_md_header_if_needed() {
  [[ -n "$PROJ_LOG_FILE" ]] || return 0
  [[ "$PROJ_LOG_FORMAT" == "md" ]] || return 0
  if [[ ! -s "$PROJ_LOG_FILE" ]]; then
    {
      printf "# Log %s\n\n" "$(date +%F)"
      printf "| Zeit | Level | Quelle | Nachricht |\n"
      printf "|---|---|---|---|\n"
    } >> "$PROJ_LOG_FILE" 2>/dev/null || true
  fi
}

_proj_log_write_file() {
  local lvl="$1" msg="$2"
  [[ -n "$PROJ_LOG_FILE" ]] || return 0
  if [[ "$PROJ_LOG_FORMAT" == "md" ]]; then
    _proj_log_md_header_if_needed
    local ts src m
    ts="$(date "+%F %T")"
    src="${PROJ_LOG_PREFIX:-${0##*/}}"
    m="$(printf "%s" "$msg" | _proj_log_md_escape)"
    printf "| %s | %s | %s | %s |\n" "$ts" "$lvl" "$src" "$m" >> "$PROJ_LOG_FILE" 2>/dev/null || true
  else
    printf "%s [%s] %s %s\n" "$(_proj_log_ts)" "$lvl" "${PROJ_LOG_PREFIX:+$PROJ_LOG_PREFIX }" "$msg" >> "$PROJ_LOG_FILE" 2>/dev/null || true
  fi
}

_proj_log_printf() {
  local lvl="$1"; shift || true
  local ts line; ts="$(_proj_log_ts)"
  if [[ -n "$PROJ_LOG_PREFIX" ]]; then
    line="${ts} [${lvl}] ${PROJ_LOG_PREFIX} $*"
  else
    line="${ts} [${lvl}] $*"
  fi
  if [[ "${PROJ_LOG_STDERR}" == "1" ]]; then
    printf "%s\n" "$line" >&2
  else
    printf "%s\n" "$line"
  fi
  _proj_log_write_file "$lvl" "$*"
}

log_init() {
  local dir="${1:-}"
  if [[ -z "$dir" ]]; then
    dir="${PWD}/.wiki/logs"
  fi
  PROJ_LOG_DIR="$dir"
  mkdir -p "$PROJ_LOG_DIR" 2>/dev/null || true

  local today ext
  ext=$([[ "$PROJ_LOG_FORMAT" == "md" ]] && echo "md" || echo "log")
  today="$(date +%F)"
  PROJ_LOG_FILE="${PROJ_LOG_DIR}/${today}.${ext}"

  if [[ "$PROJ_LOG_FORMAT" == "md" ]]; then
    _proj_log_md_header_if_needed
    {
      printf "\n\n> _Session start:_ **%s**  \n" "$(_proj_log_ts)"
      printf "> script: \`%s\` • user: \`%s\` • sessid: \`%s\`\n\n" "${0##*/}" "${USER:-unknown}" "$PROJ_LOG_SESSION_ID"
    } >> "$PROJ_LOG_FILE" 2>/dev/null || true
  else
    {
      printf "==== SESSION START %s ====\n" "$(_proj_log_ts)"
      printf "project: %s\n" "$(basename "$PWD")"
      printf "path:    %s\n" "$PWD"
      printf "script:  %s\n" "${0##*/}"
      printf "user:    %s\n" "${USER:-unknown}"
      printf "sessid:  %s\n" "$PROJ_LOG_SESSION_ID"
      printf "=========================================\n"
    } >> "$PROJ_LOG_FILE" 2>/dev/null || true
  fi

  find "$PROJ_LOG_DIR" -type f \( -name "*.log" -o -name "*.md" \) -mtime +"$PROJ_LOG_RETENTION_DAYS" -delete 2>/dev/null || true
}

log()       { local lvl="${1:-$PROJ_LOG_LEVEL_DEFAULT}"; shift || true; _proj_log_printf "$lvl" "$*"; }
log_info()  { _proj_log_printf "INFO"  "$*"; }
log_warn()  { _proj_log_printf "WARN"  "$*"; }
log_error() { _proj_log_printf "ERROR" "$*"; }
log_debug() { _proj_log_printf "DEBUG" "$*"; }
log_dry()   { _proj_log_printf "DRY"   "$*"; }

log_cmd() {
  local desc="$1"; shift || true
  if [[ -z "$desc" || $# -eq 0 ]]; then
    _proj_log_printf "ERROR" "log_cmd: Beschreibung oder Befehl fehlt"
    return 2
  fi
  _proj_log_printf "INFO" "RUN: ${desc} — cmd: $*"
  set +e; "$@"; local rc=$?; set -e
  if [[ $rc -eq 0 ]]; then
    _proj_log_printf "INFO" "OK: ${desc} (rc=${rc})"
  else
    _proj_log_printf "ERROR" "FAIL: ${desc} (rc=${rc})"
  fi
  return $rc
}

log_file()   { printf "%s\n" "${PROJ_LOG_FILE:-}"; }

# FIXED: sauberes if/else/fi ohne Extraklammern
log_section() {
  local title="${1:-Section}"
  if [[ "$PROJ_LOG_FORMAT" == "md" ]]; then
    [[ -n "$PROJ_LOG_FILE" ]] || return 0
    {
      printf "\n\n### %s — %s\n\n" "$title" "$(date "+%H:%M:%S")"
      printf "| Zeit | Level | Quelle | Nachricht |\n"
      printf "|---|---|---|---|\n"
    } >> "$PROJ_LOG_FILE" 2>/dev/null || true
  else
    _proj_log_printf "INFO" "---------- ${title} ----------"
  fi
}

log_format() {
  case "${1:-}" in
    txt|md) PROJ_LOG_FORMAT="$1" ;;
    *) _proj_log_printf "WARN" "log_format: unbekanntes Format '$1' (erlaubt: txt|md)";;
  esac
}
