#!/usr/bin/env bash
# logfx.sh — gemeinsame Logger-Library
# Version: v0.4.0
# Features:
# - dbg/trace JSONL mit Scopes (begin/end, Dauer ms), KVs, var-dumps
# - logfx_run: Kommandos mit RC, Dauer, Stdout/Stderr-Preview (zeilenbegrenzt)
# - Dry-run-Unterstützung
# - xtrace (separate Datei)
# - Rotation (>=2 behalten, löschen >12h)
set -Eeuo pipefail
IFS=$'\n\t'

: "${LOGFX_ROTATE_MAX_AGE_H:=12}"
: "${LOGFX_ROTATE_MIN_KEEP:=2}"
: "${LOG_LEVEL:=trace}"     # off|dbg|trace|xtrace
: "${NO_COLOR:=}"
: "${DRY_RUN:=}"            # "", "yes"
: "${LOGFX_CMD_PREVIEW_OUT:=12}"   # Zeilen-Preview stdout
: "${LOGFX_CMD_PREVIEW_ERR:=12}"   # Zeilen-Preview stderr
: "${LOGFX_REDACT:=}"       # Regex; wird in Preview durch "***" ersetzt

FX_BOLD=""; FX_YEL=""; FX_RED=""; FX_GRN=""; FX_RST=""
if [ -z "${NO_COLOR:-}" ] && [ -t 1 ]; then
  FX_BOLD=$'\033[1m'; FX_YEL=$'\033[33m'; FX_RED=$'\033[31m'; FX_GRN=$'\033[32m'; FX_RST=$'\033[0m'
fi

LOGFX_ID=""; LOGFX_DIR=""; LOGFX_FILE=""; LOGFX_TS_RUN=""
LOGFX_XTRACE_FILE=""

_ts(){ date -u +"%Y-%m-%dT%H:%M:%SZ"; }
_ms(){ date +%s%3N; } # GNU date (WSL/Ubuntu)
_esc(){ local s=${1//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\n'/\\n}; printf '%s' "$s"; }
_base_noext(){ local b; b="$(basename "$1")"; printf '%s' "${b%.*}"; }

_rotate(){
  local dir="$1" ; [ -d "$dir" ] || return 0
  mapfile -t files < <(ls -1t "$dir"/* 2>/dev/null || true)
  local n="${#files[@]}"; [ "$n" -le "$LOGFX_ROTATE_MIN_KEEP" ] && return 0
  local cutoff=$(( $(date +%s) - LOGFX_ROTATE_MAX_AGE_H*3600 ))
  local kept=0
  for f in "${files[@]}"; do
    [ -f "$f" ] || continue
    if [ "$kept" -lt "$LOGFX_ROTATE_MIN_KEEP" ]; then kept=$((kept+1)); continue; fi
    local mt; mt="$(stat -c %Y "$f" 2>/dev/null || echo 9999999999)"
    [ "$mt" -lt "$cutoff" ] && rm -f -- "$f" 2>/dev/null || true
  done
}

logfx_init(){ # $1=id  $2=level
  LOGFX_ID="${1:-$(_base_noext "${BASH_SOURCE[-1]}")}"
  LOG_LEVEL="${2:-${LOG_LEVEL:-trace}}"
  LOGFX_TS_RUN="$(date +%Y%m%d-%H%M%S)"
  LOGFX_DIR="${HOME}/code/bin/shellscripts/debugs/${LOGFX_ID}"
  mkdir -p "$LOGFX_DIR"
  local suffix="${LOG_LEVEL}"; [ "$LOG_LEVEL" = "xtrace" ] && suffix="trace"
  LOGFX_FILE="${LOGFX_DIR}/${LOGFX_ID}.${suffix}.${LOGFX_TS_RUN}.jsonl"; : > "$LOGFX_FILE"
  if [ -t 1 ]; then
    if [ -n "$DRY_RUN" ]; then
      printf "%sDEBUG%s %s(dry-run)%s: %s%s%s\n" "$FX_YEL$FX_BOLD" "$FX_RST" "$FX_GRN" "$FX_RST" "$FX_RED" "$LOGFX_FILE" "$FX_RST"
    else
      printf "%sDEBUG%s: %s%s%s\n" "$FX_YEL$FX_BOLD" "$FX_RST" "$FX_RED" "$LOGFX_FILE" "$FX_RST"
    fi
  else
    echo "DEBUG: $LOGFX_FILE"
  fi
  trap 'logfx__err $? "${BASH_COMMAND:-}" "${BASH_SOURCE[0]}" "${LINENO}"' ERR
  trap 'logfx_event "exit" "rc" "$?"' EXIT
  _rotate "$LOGFX_DIR"
  [ "$LOG_LEVEL" = "xtrace" ] && logfx_xtrace_on
  logfx_event "boot" "level" "$LOG_LEVEL"
}

logfx_file(){ printf '%s\n' "$LOGFX_FILE"; }
_emit(){ # $1=level $2=event $3=msg [kv...]
  [ "${LOG_LEVEL}" = "off" ] && return 0
  local lvl="$1" evt="$2" msg="$3"; shift 3 || true
  local ts="$(_ts)" pid="$$" scr="${BASH_SOURCE[1]:-main}" lin="${BASH_LINENO[0]:-0}" fn="${FUNCNAME[2]:-main}"
  local kv=""; while [ "$#" -gt 0 ]; do local k="$1"; shift || true; local v="${1:-}"; shift || true
    [ -z "$kv" ] && kv="\"$(_esc "$k")\":\"$(_esc "$v")\"" || kv="$kv, \"$(_esc "$k")\":\"$(_esc "$v")\""; done
  [ -n "$kv" ] && kv=", $kv"
  printf '{"ts":"%s","level":"%s","event":"%s","msg":"%s","script":"%s","line":%s,"func":"%s","pid":%s%s}\n' \
    "$ts" "$lvl" "$(_esc "$evt")" "$(_esc "$msg")" "$(_esc "$scr")" "$lin" "$(_esc "$fn")" "$pid" "$kv" >> "$LOGFX_FILE"
}
logfx_event(){ _emit "dbg" "event" "$1" "${@:2}"; }
logfx_dbg(){   _emit "dbg" "dbg"   "$1" "${@:2}"; }
logfx_trace(){ [ "$LOG_LEVEL" = "trace" ] || [ "$LOG_LEVEL" = "xtrace" ] || return 0; _emit "trace" "trace" "$1" "${@:2}"; }

# ----- Scopes / Sections -----
logfx_scope_begin(){ # $1=name [kv...]
  local name="$1"; shift || true
  local id="${name}-$(date +%s%3N)"
  _emit "dbg" "scope-begin" "$name" "scope" "$id" "${@}"
  printf '%s' "$id"
}
logfx_scope_end(){ # $1=scope-id $2=status(ok|warn|fail) [kv...]
  local id="$1"; shift || true
  local status="${1:-ok}"; shift || true
  _emit "dbg" "scope-end" "$status" "scope" "$id" "${@}"
}

# ----- Vars / KVs -----
logfx_kv(){ # [k v]...
  [ "$#" -lt 2 ] && return 0
  _emit "trace" "kv" "" "${@}"
}
logfx_var(){ # name value [name value]...
  logfx_kv "${@}"
}

# ----- Redaction helper -----
__redact(){
  if [ -n "${LOGFX_REDACT:-}" ]; then sed -E "s/${LOGFX_REDACT}/***/g"
  else cat
  fi
}

# ----- Commands -----
logfx_run(){ # label -- cmd args...
  local lbl="$1"; shift
  [ "${1:-}" = "--" ] && shift || true
  local cwd; cwd="$(pwd -P)"
  if [ -n "$DRY_RUN" ]; then
    _emit "dbg" "run" "dry" "label" "$lbl" "cwd" "$cwd" "cmd" "$*"
    return 0
  fi
  local t0 t1 rc out err; t0="$(_ms)"
  local of ef; of="$(mktemp)"; ef="$(mktemp)"
  set +e
  "$@" >"$of" 2>"$ef"; rc=$?
  set -e
  t1="$(_ms)"; local dur=$((t1 - t0))
  local pn_out="${LOGFX_CMD_PREVIEW_OUT:-12}" pn_err="${LOGFX_CMD_PREVIEW_ERR:-12}"
  local p_out p_err
  if [ -s "$of" ]; then p_out="$(head -n "$pn_out" "$of" | __redact)"; else p_out=""; fi
  if [ -s "$ef" ]; then p_err="$(head -n "$pn_err" "$ef" | __redact)"; else p_err=""; fi
  _emit "trace" "run" "$lbl" \
    "cwd" "$cwd" "rc" "$rc" "dur_ms" "$dur" \
    "cmd" "$*" \
    "stdout_preview" "$p_out" "stderr_preview" "$p_err"
  rm -f "$of" "$ef" || true
  return "$rc"
}

# ----- Error trap -----
logfx__err(){ # rc cmd file line
  _emit "error" "trap" "error" "rc" "$1" "cmd" "$2" "file" "$3" "line" "$4"
}

# ----- xtrace -----
logfx_xtrace_on(){
  export PS4='+ ${EPOCHREALTIME} ${BASH_SOURCE##*/}:${LINENO}:${FUNCNAME[0]:-main}: '
  LOGFX_XTRACE_FILE="${LOGFX_DIR}/${LOGFX_ID}.xtrace.${LOGFX_TS_RUN}.log"
  exec 9>"$LOGFX_XTRACE_FILE"; export BASH_XTRACEFD=9; set -x
  _emit "dbg" "xtrace" "on" "file" "$LOGFX_XTRACE_FILE"
}
logfx_xtrace_off(){ { set +x; } 2>/dev/null || true; [ -n "${BASH_XTRACEFD:-}" ] && exec 9>&- || true; unset BASH_XTRACEFD || true; [ -n "$LOGFX_XTRACE_FILE" ] && _emit "dbg" "xtrace" "off" "file" "$LOGFX_XTRACE_FILE"; }
