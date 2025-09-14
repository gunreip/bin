#!/usr/bin/env bash
# systemd_timer_status — Status-Report für systemd-Timer (+ Validierung der .service-Units)
# Version: 0.1.7
#
# Exit-Codes:
#   0  OK
#   2  Gatekeeper (nicht im Projekt-Root / .env fehlt)
#   3  systemctl fehlt
#   10 Sonstiger Fehler beim Abfragen

# shellcheck disable=

# ───────────────────────── Shell-Safety ─────────────────────────
if [ -z "${BASH_VERSION-}" ]; then exec bash "$0" "$@"; fi
set -Euo pipefail

SCRIPT_NAME="systemd_timer_status"
SCRIPT_VERSION="0.1.7"
VERSION="${SCRIPT_VERSION}"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
ORIG_CWD="$(pwd)"
ORIG_ARGS=("$@")

# ───────────────────────── Defaults ─────────────────────────
DEBUG="OFF"              # OFF|ON|TRACE (nur für dieses Skript)
DO_LOG_RENDER="ON"       # ON|OFF
RENDER_DELAY=1           # Sekunden
LR_DEBUG="OFF"           # OFF|ON|TRACE (nur für log_render_html)
SCOPE_USER=1             # User-Timer prüfen
SCOPE_SYSTEM=1           # System-Timer prüfen
PATTERN="*"              # Glob-Filter auf Timer-Namen (z.B. "*backup*")
VERIFY_SERVICE=1         # Zugehörige .service-Unit validieren
FORMAT="md"              # reserviert; Report-Format (später nutzbar)

# ───────────────────────── Usage ─────────────────────────
usage(){ cat <<'EOF'
systemd_timer_status — Status-Report für systemd-Timer (user & system) mit Validierung der .service-Units.

Usage:
  systemd_timer_status [--user-only] [--system-only]
                       [--pattern <glob>]          # default: "*"
                       [--no-verify-service]       # .service nicht prüfen
                       [--debug=OFF|ON|TRACE]      # default: OFF
                       [--do-log-render=ON|OFF]    # default: ON
                       [--render-delay=<sec>]      # default: 1
                       [--lr-debug=OFF|ON|TRACE]   # default: OFF
                       [--version] [--help]

Hinweise:
- Default ist: user **und** system Timer prüfen.
- Pattern ist ein Shell-Glob (z.B. "*backup*"); Match auf Timer-Namen (ohne Pfad).
EOF
}

# ───────────────────────── Parse Args ─────────────────────────
ARGS=()
while (($#)); do
  case "$1" in
    --user-only) SCOPE_USER=1; SCOPE_SYSTEM=0 ;;
    --system-only) SCOPE_USER=0; SCOPE_SYSTEM=1 ;;
    --pattern) PATTERN="${2:-*}"; shift ;;
    --no-verify-service) VERIFY_SERVICE=0 ;;
    --do-log-render=*) DO_LOG_RENDER="${1#*=}"; DO_LOG_RENDER="${DO_LOG_RENDER^^}" ;;
    --render-delay=*) RENDER_DELAY="${1#*=}" ;;
    --lr-debug=*) LR_DEBUG="${1#*=}"; LR_DEBUG="${LR_DEBUG^^}" ;;
    --debug|--debug=*) if [[ "$1" == --debug=* ]]; then DEBUG="${1#*=}"; else DEBUG="${2:-OFF}"; shift; fi; DEBUG="${DEBUG^^}" ;;
    --version) echo "${SCRIPT_VERSION}"; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    --) shift; ARGS+=("$@"); break ;;
    *) echo "Unbekannter Parameter: $1" >&2; usage; exit 2 ;;
  esac
  shift || true
done

# ───────────────────────── Debug-Setup ─────────────────────────
DEBUG_DIR="${HOME}/bin/debug"; mkdir -p "${DEBUG_DIR}"
DBG_TXT="${DEBUG_DIR}/systemd_timer_status.debug.log"
DBG_JSON="${DEBUG_DIR}/systemd_timer_status.debug.jsonl"
XTRACE="${DEBUG_DIR}/systemd_timer_status.xtrace.log"
: > "${DBG_TXT}"; : > "${DBG_JSON}"
if [[ "${DEBUG}" == "TRACE" ]]; then
  : > "${XTRACE}"
  exec 19>>"${XTRACE}"
  export BASH_XTRACEFD=19
  export PS4='+ systemd_timer_status:${LINENO}:${FUNCNAME[0]-main} '
  set -x
fi
dbg_line(){ [[ "${DEBUG}" != "OFF" ]] && printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "${DBG_TXT}"; }
dbg_json(){ [[ "${DEBUG}" != "OFF" ]] && printf '{"ts":"%s","event":"%s"%s}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "${2:+,$2}" >> "${DBG_JSON}"; }
dbg_line "START ${SCRIPT_NAME} v${SCRIPT_VERSION} run_id=${RUN_ID} cwd=${ORIG_CWD} debug=${DEBUG}"
dbg_json "start" "\"script\":\"${SCRIPT_NAME}\",\"version\":\"${SCRIPT_VERSION}\",\"run_id\":\"${RUN_ID}\",\"cwd\":\"${ORIG_CWD}\",\"debug\":\"${DEBUG}\""
cleanup(){ set +e; exec 19>&- 2>/dev/null; }
trap cleanup EXIT

# ───────────────────────── Optionen-Zelle (non-breaking hyphen) ─────────────────────────
nbhy_all(){ printf '%s' "${1//-/$'\u2011'}"; }  # U+2011
render_opt_cell_html_multiline(){
  local out=() t
  for t in "${ORIG_ARGS[@]}"; do
    out+=( "<span style=\"white-space:nowrap\"><code>$(nbhy_all "$t")</code></span>" )
  done
  if ((${#out[@]}==0)); then printf '%s' "keine"
  else
    local i; for ((i=0;i<${#out[@]};i++)); do printf '%s' "${out[i]}"; ((i<${#out[@]}-1)) && printf '<br />'; done
  fi
}
LC_OPT_CELL="keine"; LC_OPT_CELL_IS_HTML=1
LC_OPT_CELL="$(render_opt_cell_html_multiline)"

# ───────────────────────── Gatekeeper & Tools ─────────────────────────
PROJECT_ROOT="$ORIG_CWD"
if [[ ! -f "${PROJECT_ROOT}/.env" ]]; then
  echo "Fehler: .env fehlt (im Projekt-Root ausführen)" >&2
  GATE_ERR=".env missing"; GATE_FAIL=1
else
  GATE_FAIL=0
fi
if ! command -v systemctl >/dev/null 2>&1; then
  echo "Fehler: systemctl nicht gefunden" >&2
  GATE_ERR="${GATE_ERR:-} systemctl missing"; GATE_FAIL=1
fi
if (( GATE_FAIL==1 )); then EXIT=2; else EXIT=0; fi

# ───────────────────────── log_core.part (optional) ─────────────────────────
export SCRIPT_NAME SCRIPT_VERSION VERSION SCRIPT
SCRIPT="${SCRIPT_NAME}"
export LC_OPT_CELL LC_OPT_CELL_IS_HTML
LC_OK=0; LC_HAS_INIT=0; LC_HAS_FINALIZE=0; LC_HAS_SETOPT=0
if [[ -r "${HOME}/bin/parts/log_core.part" ]]; then
  # shellcheck disable=SC1090
  . "${HOME}/bin/parts/log_core.part" || true
  set +u; LC_ORIG_ARGS=("${ORIG_ARGS[@]}"); set -u
  command -v lc_log_event_all >/dev/null 2>&1 && LC_OK=1 || LC_OK=0
  command -v lc_init_ctx     >/dev/null 2>&1 && LC_HAS_INIT=1 || true
  command -v lc_finalize     >/dev/null 2>&1 && LC_HAS_FINALIZE=1 || true
  command -v lc_set_opt_cell >/dev/null 2>&1 && LC_HAS_SETOPT=1 || true
  if [[ "${LC_OK}" -eq 1 && "${LC_HAS_INIT}" -eq 1 ]]; then
    set +u
    lc_init_ctx "PRIMARY" "${PROJECT_ROOT}" "${RUN_ID}" "${SCRIPT_NAME}" "${SCRIPT_VERSION}" "${ORIG_CWD}" "systemd,timer,status"
    if declare -p CTX_NAMES >/dev/null 2>&1; then :; else declare -g -a CTX_NAMES; fi
    CTX_NAMES=("PRIMARY")
    [[ "${LC_HAS_SETOPT}" -eq 1 ]] && lc_set_opt_cell "${LC_OPT_CELL}" "${LC_OPT_CELL_IS_HTML}"
    set -u
  fi
else
  echo "⚠️ log_core.part nicht geladen → kein Markdown/JSON-Lauf-Log (nur Debugfiles)."
fi
safe_log(){ if [[ "${LC_OK}" -eq 1 ]]; then set +u; lc_log_event_all "$@"; set -u; fi; }

# Gatekeeper-Exit (geloggt)
if (( GATE_FAIL==1 )); then
  safe_log ERROR "timer" "gate" "\`strict-root\`" "❌" 0 2 "Root=\`${PROJECT_ROOT}\`" "systemd,timer,gatekeeper$([ "${DEBUG}" = "TRACE" ] && echo ',trace')" "${GATE_ERR:-missing prerequisites}"
  exit 2
fi

# ───────────────────────── Hilfsfunktionen ─────────────────────────
show_prop(){ grep -E "^$1=" | sed -E "s/^$1=//"; }

# scope_exec <scope_label> <systemctl args...>
scope_exec(){ # stderr ins Debug
  local label="$1"; shift
  systemctl "$@" 2>>"${DBG_TXT}"
}

# ns_to_iso <usec>  (systemd liefert *USec in µs)
# robuste µs/Datum → ISO mit TRACE-Diagnose
usec_to_iso(){
  # Achtung: set -u aktiv → defensiv expandieren
  local v="${1-}"

  # Hilfslogger (benutzt vorhandenes dbg(), fällt sonst stumm)
  __u2i_log(){
    if LC_ALL=C type -t dbg >/dev/null 2>&1; then
      dbg "$*"
    fi
  }

  # Null-/Leerfälle: "-", "", "0"
  if [[ -z "${v-}" || "${v}" == "-" || "${v}" == "0" ]]; then
    [[ "${DEBUG:-OFF}" == "TRACE" ]] && __u2i_log "XTRACE usec_to_iso IN='${v}' → '-' (null/leer)"
    echo "-"
    return
  fi

  # Reiner µs-Wert?
  if [[ "${v}" =~ ^[0-9]+$ ]]; then
    # WICHTIG: nur hier arithm. Division – sonst nie!
    local sec=$(( v/1000000 ))
    local out
    if out="$(date -d "@${sec}" +"%Y-%m-%d %H:%M:%S%z" 2>/dev/null)"; then
      [[ "${DEBUG:-OFF}" == "TRACE" ]] && __u2i_log "XTRACE usec_to_iso IN='${v}' (µs) sec='${sec}' OUT='${out}'"
      printf '%s\n' "${out}"
    else
      [[ "${DEBUG:-OFF}" == "TRACE" ]] && __u2i_log "XTRACE usec_to_iso IN='${v}' (µs) sec='${sec}' → Fallback='${sec}s'"
      printf '%ss\n' "${sec}"
    fi
    return
  fi

  # Menschlich lesbares Datum (systemd liefert z.B. 'Fri 2025-09-05 12:34:56 CEST')
  local out
  if out="$(date -d "${v}" +"%Y-%m-%d %H:%M:%S%z" 2>/dev/null)"; then
    [[ "${DEBUG:-OFF}" == "TRACE" ]] && __u2i_log "XTRACE usec_to_iso IN='${v}' (human) OUT='${out}'"
    printf '%s\n' "${out}"
  else
    [[ "${DEBUG:-OFF}" == "TRACE" ]] && __u2i_log "XTRACE usec_to_iso IN='${v}' (human) → passthrough"
    printf '%s\n' "${v}"
  fi
}

inspect_scope(){ # <label: user|system>
  local label="$1"
  local user_flag=()
  [[ "$label" == "user" ]] && user_flag=(--user)

  # Timer-Liste möglichst vollständig: list-unit-files (zeigt auch disabled/static), Fallback: list-units
  local timers=()
  local line
  while IFS= read -r line; do
    # Format: <UNIT> <STATE>
    local unit state
    unit="${line%% *}"
    [[ -z "$unit" ]] && continue
    timers+=("$unit")
  done < <(scope_exec "$label" "${user_flag[@]}" list-unit-files --type=timer --no-legend --no-pager 2>/dev/null | awk 'NF>=1{print $1}')

  if ((${#timers[@]}==0)); then
    while IFS= read -r line; do
      local unit
      unit="${line%% *}"
      [[ -z "$unit" ]] && continue
      timers+=("$unit")
    done < <(scope_exec "$label" "${user_flag[@]}" list-units --type=timer --all --no-legend --no-pager 2>/dev/null | awk 'NF>=1{print $1}')
  fi

  local total=0 ok=0 warn=0 err=0 disabled=0 missing_service=0
  safe_log INFO "timer" "scan" "\`${label}\`" "✅" 0 0 "pattern=\`${PATTERN}\`" "systemd,timer,scan,${label}$([ "${DEBUG}" = "TRACE" ] && echo ',trace')" "found=${#timers[@]}"

  local t
  for t in "${timers[@]}"; do
    # Skip template timer units without instance (e.g., pg_dump@.timer)
    if [[ "$t" == *@.timer ]]; then
      safe_log INFO "timer" "template/${label}" "<code>${t}</code>" "ℹ️" 0 0 \
        "Template ohne Instanz – übersprungen" \
        "systemd,timer,${label}" \
        "template unit"
      continue
    fi

    [[ "$t" != *.timer ]] && continue
    local base="${t##*/}"
    # Pattern-Filter
    case "$base" in
      ${PATTERN}) : ;;
      *) continue ;;
    esac

    total=$((total+1))

    # Properties via systemctl show
    local SHOW
    if ! SHOW="$(scope_exec "$label" "${user_flag[@]}" show "$t" --no-pager 2>/dev/null)"; then
      err=$((err+1))
      safe_log ERROR "timer" "unit" "\`$base\`" "❌" 0 10 "" "systemd,timer,${label}" "show failed"
      continue
    fi
    local Id LoadState ActiveState SubState Unit Desc OnCal NextUS LastUS
    Id="$(printf '%s\n' "$SHOW" | show_prop Id)"
    LoadState="$(printf '%s\n' "$SHOW" | show_prop LoadState)"
    ActiveState="$(printf '%s\n' "$SHOW" | show_prop ActiveState)"
    SubState="$(printf '%s\n' "$SHOW" | show_prop SubState)"
    Unit="$(printf '%s\n' "$SHOW" | show_prop Unit)"
    Desc="$(printf '%s\n' "$SHOW" | show_prop Description)"
    OnCal="$(printf '%s\n' "$SHOW" | show_prop OnCalendar)"
    NextUS="$(printf '%s\n' "$SHOW" | show_prop NextElapseUSecRealtime)"
    LastUS="$(printf '%s\n' "$SHOW" | show_prop LastTriggerUSec)"
    [[ -z "$OnCal" ]] && OnCal="$(printf '%s\n' "$SHOW" | show_prop TimersCalendar || true)"

    local next_h last_h
    next_h="$(usec_to_iso "${NextUS:-0}")"
    last_h="$(usec_to_iso "${LastUS:-0}")"

    # Enabled-Status
    local is_enabled is_active
    is_enabled="$(scope_exec "$label" "${user_flag[@]}" is-enabled "$t" 2>/dev/null || true)"
    is_active="$(scope_exec "$label" "${user_flag[@]}" is-active "$t" 2>/dev/null || true)"

    # Service-Validierung (optional)
    local svc_ok="n/a"
    if (( VERIFY_SERVICE==1 )); then
      if [[ -n "$Unit" ]]; then
        if scope_exec "$label" "${user_flag[@]}" show "$Unit" --no-pager >/dev/null 2>&1; then
          svc_ok="ok"
        else
          svc_ok="missing"
          missing_service=$((missing_service+1))
        fi
      else
        svc_ok="unknown"
      fi
    fi

    # Ergebnis-Icon & Zählung
    local icon="✅" level="INFO"
    if [[ "$is_active" != "active" && "$is_enabled" != "enabled" && "$is_enabled" != "static" ]]; then
      icon="⚠️"; level="WARN"; disabled=$((disabled+1))
    fi
    if [[ "$svc_ok" == "missing" ]]; then
      icon="⚠️"; level="WARN"; warn=$((warn+1))
    elif [[ "$ActiveState" == "failed" || "$SubState" == "failed" ]]; then
      icon="❌"; level="ERROR"; err=$((err+1))
    else
      ok=$((ok+1))
    fi

    # Notiz / Meldungen
    local note="next=\`${next_h}\`; last=\`${last_h}\`"
    local msg="enabled=${is_enabled}; active=${is_active}; load=${LoadState}; sub=${SubState}; service=${Unit:-"-"} (${svc_ok})"
    # Tags
    local tags="systemd,timer,${label}"
    [[ -n "$OnCal" ]] && tags="${tags},calendar"

    safe_log "${level}" "timer" "unit" "\`$base\`" "${icon}" 0 0 \
      "Desc=\`${Desc:-"-"}\`; OnCalendar=\`${OnCal:-"-"}\`" \
      "${tags}" \
      "${msg}"
  done

  # Summary je Scope
  local summary="total=${total}; ok=${ok}; $((warn>0?1:0))"
  summary="total=${total}; $( ((ok>0)) && printf '*ok=%d*' "$ok" || printf 'ok=0' ); \
$( ((warn>0)) && printf '***warn=%d***' "$warn" || printf 'warn=0' ); \
$( ((disabled>0)) && printf '***disabled=%d***' "$disabled" || printf 'disabled=0' ); \
$( ((missing_service>0)) && printf '***missing_service=%d***' "$missing_service" || printf 'missing_service=0' ); \
$( ((err>0)) && printf '***errors=%d***' "$err" || printf 'errors=0' )"

  safe_log INFO "timer" "summary" "\`${label}\`" "✅" 0 0 \
    "pattern=\`${PATTERN}\`; verify_service=\`$((VERIFY_SERVICE))\`" \
    "systemd,timer,summary,${label}" \
    "${summary}"
}

# ───────────────────────── Start-Log ─────────────────────────
safe_log INFO "timer" "scan" "\`start\`" "✅" 0 0 \
  "Scopes=\`$((SCOPE_USER)) user / $((SCOPE_SYSTEM)) system\`" \
  "systemd,timer,begin$([ "${DEBUG}" = "TRACE" ] && echo ',trace')" \
  "pattern=\`${PATTERN}\`; verify_service=\`$((VERIFY_SERVICE))\`"

# ───────────────────────── Inspect Scopes ─────────────────────────
(( SCOPE_USER==1 ))   && inspect_scope "user"
(( SCOPE_SYSTEM==1 )) && inspect_scope "system"

# ───────────────────────── finalize & optional HTML-Render ─────────────────────
command -v lc_finalize >/dev/null 2>&1 && [[ "${LC_OK}" -eq 1 ]] && lc_finalize || true

if [[ "${DO_LOG_RENDER}" == "ON" ]]; then
  sleep "${RENDER_DELAY}" || true
  LR_CMD=""
  if command -v log_render_html >/dev/null 2>&1; then
    LR_CMD="log_render_html"
  elif command -v log_render_html.sh >/dev/null 2>&1; then
    LR_CMD="log_render_html.sh"
  fi
  if [[ -n "${LR_CMD}" ]]; then
    LR_ARGS=()
    case "${LR_DEBUG}" in
      ON|TRACE) LR_ARGS+=(--debug="${LR_DEBUG}") ;;
      OFF|*) : ;;
    esac
    if "${LR_CMD}" "${LR_ARGS[@]}"; then
      echo "✅ LOG wurde gerendert!"
    else
      echo "⚠️ LOG-Rendering fehlgeschlagen (\"${LR_CMD} ${LR_ARGS[*]-}\")."
    fi
  else
    echo "ℹ️ log_render_html(.sh) nicht gefunden – Rendern übersprungen."
  fi
fi

exit 0

# patched: robuste µs/Datum → ISO, tolerant ggü. set -u und Newlines; mit Trace-Hinweis
usec_to_iso () {
  # set -u-sicheres Lesen des Args:
  local v="${1-}"
  # Normalisieren: Zeilenumbrüche raus, trim
  v="${v//$'\r'/ }"; v="${v//$'\n'/ }"; v="${v## }"; v="${v%% }"
  # Trace-Hint (nur wenn xtrace aktiv ist)
  if [[ $- == *x* ]]; then
    local kind="text"; [[ "$v" =~ ^[0-9]+$ ]] && kind="number"
    printf 'XTRACE usec_to_iso: input=<%s> kind=%s\n' "$v" "$kind" >&2
  fi
  # Guards
  [[ -z "${v+x}" || -z "$v" || "$v" == "0" || "$v" == "-" || "$v" == "(null)" ]] && { echo "-"; return; }
  if [[ "$v" =~ ^[0-9]+$ ]]; then
    # µs → Sek
    local sec=$(( v / 1000000 ))
    date -d "@$sec" +"%Y-%m-%d %H:%M:%S%z" 2>/dev/null || { printf '%s' "$sec"; return; }
  else
    # Datumstext direkt parsen (z. B. "Fri 2025-09-05 12:20:32 CEST")
    date -d "$v" +"%Y-%m-%d %H:%M:%S%z" 2>/dev/null || { printf '%s' "$v"; return; }
  fi
}
