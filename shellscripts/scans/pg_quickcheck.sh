#!/usr/bin/env bash
SCRIPT_STATE=1
# pg_quickcheck.sh — PostgreSQL Quick-Diagnose (WSL/Ubuntu)
# v0.5.4  (Patch: robuste Defaults; keine "unbound variable" mehr)
set -u

VERSION="0.5.4"

# ----------------- Defaults & Flags (robust) -----------------
USER_NAME="${USER:-postgres}"
DB_NAME="${USER_NAME}"

PORT_DEFAULT=""
UNIT_DEFAULT=""
VERBOSE=0
WIKI=1
PROJLOG=1
DO_FIX_AUTH=0
DO_SET_PASS=0

# Früh initialisieren (wegen set -u)
TCP_OK=0
EXIT_CODE=0
HOST="127.0.0.1"
PORT="${PORT_DEFAULT:-}"
CLUSTER_VER=""
CLUSTER_NAME=""
CLUSTER_PORT=""
CL_STATUS="unknown"
UNIT_NAME=""
UNIT_STATUS="unknown"
UNIT_STATUS_OUT=""
CONFIG_PATH=""
CONF_LINES=""
LISTEN_OUT=""
LOG_TAIL=""
PROJ_ROOT=""
REPORT_DIR=""
MD_FILE=""
JSON_FILE=""
JSONL_FILE=""

# Argumente (original) für LOG merken
ARGV_ORIG="$*"

show_help(){ cat <<EOF
pg_quickcheck.sh v${VERSION}
Checks: Clusterstatus, Logs, Konfig (listen/port), TCP-Listener, TCP-Login.
Schreibt Reports nach <project>/.wiki/pg_quickcheck/ und Tages-LOG (Sub-Chapter „Run-ID“).
Options:
  --user NAME  --db NAME  --port N  --unit UNIT
  --fix-auth   --set-pass
  --no-wiki    --no-projlog
  --verbose    --version  --help
EOF
}

# ----------------- CLI-Parsing -----------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --user) USER_NAME="${2:-$USER_NAME}"; DB_NAME="$USER_NAME"; shift 2;;
    --db) DB_NAME="${2:-$DB_NAME}"; shift 2;;
    --port) PORT_DEFAULT="${2:-}"; shift 2;;
    --unit) UNIT_DEFAULT="${2:-}"; shift 2;;
    --fix-auth) DO_FIX_AUTH=1; shift;;
    --set-pass) DO_SET_PASS=1; shift;;
    --no-wiki) WIKI=0; shift;;
    --no-projlog) PROJLOG=0; shift;;
    --verbose) VERBOSE=1; shift;;
    --version) echo "pg_quickcheck.sh v${VERSION}"; exit 0;;
    --help|-h) show_help; exit 0;;
    *) echo "Unbekanntes Argument: $1"; show_help; exit 2;;
  esac
done

# ----------------- Helpers -----------------
ok(){ printf "\033[1;32m%s\033[0m\n" "$*"; }
warn(){ printf "\033[1;33m%s\033[0m\n" "$*"; }
err(){ printf "\033[1;31m%s\033[0m\n" "$*"; }
info(){ printf "\033[1;34m%s\033[0m\n" "$*"; }
print_cmd(){ printf "\033[1;31m\$ %s\033[0m\n" "$*"; }  # rotes "$ "
run(){ local c="$*"; [[ $VERBOSE -eq 1 ]] && print_cmd "$c"; bash -c "$c"; }
bool(){ [[ "${1:-0}" -eq 1 ]] && echo true || echo false; }
md_escape(){ sed 's/\\/\\\\/g; s/`/\\`/g'; }
json_escape(){ sed -e ':a;N;$!ba' -e 's/\\/\\\\/g;s/"/\\"/g;s/\t/\\t/g;s/\r/\\r/g;s/\n/\\n/g'; }

find_proj_root(){ local d="$PWD"; while [[ "$d" != "/" ]]; do
  [[ -f "$d/.env" || -d "$d/.wiki" ]] && { echo "$d"; return; }; d="$(dirname "$d")"; done; echo "$PWD"; }

ensure_hba_scram(){ local hba="$1"
  sudo cp -a "$hba" "${hba}.bak-$(date +%F_%H%M%S)"
  sudo sed -i -E \
    -e "s/^[[:space:]]*host[[:space:]]+all[[:space:]]+all[[:space:]]+127\.0\.0\.1\/32[[:space:]]+\w+/host    all     all     127.0.0.1\/32    scram-sha-256/" \
    -e "s/^[[:space:]]*host[[:space:]]+all[[:space:]]+all[[:space:]]+::1\/128[[:space:]]+\w+/host    all     all     ::1\/128           scram-sha-256/" "$hba"
  grep -Eq '^[[:space:]]*host[[:space:]]+all[[:space:]]+all[[:space:]]+127\.0\.0\.1/32' "$hba" || \
    echo "host    all     all     127.0.0.1/32    scram-sha-256" | sudo tee -a "$hba" >/dev/null
  grep -Eq '^[[:space:]]*host[[:space:]]+all[[:space:]]+all[[:space:]]+::1/128' "$hba" || \
    echo "host    all     all     ::1/128         scram-sha-256" | sudo tee -a "$hba" >/dev/null
}

# Lauf-IDs
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$((RANDOM%90000+10000))"
TS_ISO="$(date -Iseconds)"
T0_MS="$(date +%s%3N)"

# ----------------- 1) Cluster & Port -----------------
echo "----------------------------------------"
echo "1) Cluster & Port ermitteln"
if ! command -v pg_lsclusters >/dev/null 2>&1; then
  err "pg_lsclusters fehlt (postgresql-common)"; exit 3
fi
line="$(pg_lsclusters 2>/dev/null | awk 'NR==2{print $0}')"
if [[ -n "$line" ]]; then
  read -r CLUSTER_VER CLUSTER_NAME CLUSTER_PORT CL_STATUS _ <<<"$line"
  [[ -n "$PORT_DEFAULT" ]] && CLUSTER_PORT="$PORT_DEFAULT"
  ok "Gefunden: ${CLUSTER_VER}-${CLUSTER_NAME} (Port ${CLUSTER_PORT}, Status ${CL_STATUS})"
else
  warn "Keine Cluster gefunden (pg_lsclusters leer)."
  [[ -z "$PORT_DEFAULT" ]] && PORT_DEFAULT="5432"
  CLUSTER_PORT="$PORT_DEFAULT"; CL_STATUS="unknown"
fi
UNIT_NAME="${UNIT_DEFAULT:-}"; [[ -z "$UNIT_NAME" && -n "$CLUSTER_VER" && -n "$CLUSTER_NAME" ]] && UNIT_NAME="postgresql@${CLUSTER_VER}-${CLUSTER_NAME}"
[[ -z "$UNIT_NAME" ]] && UNIT_NAME="postgresql"

# ----------------- 2) Unit-Status -----------------
echo "----------------------------------------"
echo "2) systemd-Status (${UNIT_NAME})"
UNIT_STATUS="$(systemctl is-active "$UNIT_NAME" 2>/dev/null || true)"
UNIT_STATUS_OUT="$(systemctl status "$UNIT_NAME" --no-pager 2>/dev/null | sed -n '1,12p')"
[[ -n "$UNIT_STATUS_OUT" ]] && printf "%s\n" "$UNIT_STATUS_OUT" || warn "Unit ${UNIT_NAME} nicht verfügbar."

# ----------------- 3) Letzte Logs -----------------
echo "----------------------------------------"
echo "3) Letzte Logs"
LOG_TAIL="$(journalctl -u "$UNIT_NAME" -n 25 --no-pager 2>/dev/null || true)"
[[ -n "$LOG_TAIL" ]] && printf "%s\n" "$LOG_TAIL" | sed 's/^/  /' || warn "Keine journalctl-Einträge."

# ----------------- 4) Konfiguration -----------------
echo "----------------------------------------"
echo "4) Konfiguration (listen_addresses / port)"
CONFIG_PATH=""
[[ -n "$CLUSTER_VER" ]] && CONFIG_PATH="/etc/postgresql/${CLUSTER_VER}/${CLUSTER_NAME}/postgresql.conf"
[[ -f "$CONFIG_PATH" ]] || CONFIG_PATH="$(ls /etc/postgresql/*/main/postgresql.conf 2>/dev/null | head -n1 || true)"
CONF_LINES=""
if [[ -n "$CONFIG_PATH" ]]; then
  echo "Config: $CONFIG_PATH"
  CONF_LINES="$(grep -nE '^\s*#?\s*(listen_addresses|port)\s*=' "$CONFIG_PATH" || true)"
  printf "%s\n" "$CONF_LINES"
else
  warn "postgresql.conf nicht gefunden."
fi

# ----------------- 5) Lauscht der Server? -----------------
echo "----------------------------------------"
echo "5) Lauscht der Server auf TCP?"
LISTEN_OUT="$(ss -ltnp 2>/dev/null | grep -E '127\.0\.0\.1:|:5432|:5433' || true)"
[[ -n "$LISTEN_OUT" ]] && { echo "$LISTEN_OUT"; ok "TCP-Listener gefunden."; } || warn "Kein TCP-Listener sichtbar."

# ----------------- 6) User/DB prüfen -----------------
echo "----------------------------------------"
echo "6) User/DB prüfen (Auto-Fallback)"
F_USER="$USER_NAME"; F_DB="$DB_NAME"
role_exists="$(sudo -u postgres psql -XAtqc "select 1 from pg_roles where rolname='${USER_NAME}'" 2>/dev/null || true)"
db_exists="$(sudo -u postgres psql -XAtqc "select 1 from pg_database where datname='${DB_NAME}'" 2>/dev/null || true)"
[[ -z "$role_exists" ]] && { warn "DB-User '${USER_NAME}' existiert nicht."; F_USER="postgres"; }
[[ -z "$db_exists"  ]] && { warn "DB '${DB_NAME}' existiert nicht.";   F_DB="postgres"; }
[[ "$F_USER" != "$USER_NAME" || "$F_DB" != "$DB_NAME" ]] && info "Fallback: User='${F_USER}', DB='${F_DB}'"

# ----------------- 7) Fix-Auth (optional) -----------------
if [[ $DO_FIX_AUTH -eq 1 ]]; then
  echo "----------------------------------------"
  echo "7) Auth fixen (pg_hba.conf -> scram-sha-256 für 127.0.0.1/::1)"
  HBA_FILE="$(sudo -u postgres psql -XAtqc "show hba_file;" 2>/dev/null || true)"
  [[ -z "$HBA_FILE" ]] && HBA_FILE="/etc/postgresql/${CLUSTER_VER}/${CLUSTER_NAME}/pg_hba.conf"
  if [[ -f "$HBA_FILE" ]]; then
    echo "hba_file: $HBA_FILE"
    ensure_hba_scram "$HBA_FILE"
    run "sudo systemctl reload postgresql"
    ok "pg_hba.conf aktualisiert & Config neu geladen."
    if [[ $DO_SET_PASS -eq 1 ]]; then
      printf "\033[1;31m%s\033[0m\n" "Interaktiver Passwort-Prompt folgt (psql \password ${F_USER}) …"
      if [[ -t 1 ]]; then sudo -u postgres psql -v ON_ERROR_STOP=1 -c "\password ${F_USER}"; else
        warn "Kein TTY für Passwort-Prompt. Manuell:"
        echo "  sudo -u postgres psql -c \"\\password ${F_USER}\""
      fi
    else
      info "Hinweis: Passwort setzen (empfohlen):"
      echo "  sudo -u postgres psql -c \"\\password ${F_USER}\""
    fi
  else
    err "hba_file nicht gefunden: $HBA_FILE"
  fi
fi

# ----------------- 8) TCP-Login-Test -----------------
echo "----------------------------------------"
echo "8) TCP-Login-Test"
PORT="${PORT_DEFAULT:-${CLUSTER_PORT:-5432}}"
HOST="127.0.0.1"
PSQL_CMD=(psql -h "$HOST" -p "$PORT" -U "$F_USER" -d "$F_DB" -c "select current_user, current_database(), inet_server_addr(), inet_server_port(), now();")
[[ $VERBOSE -eq 1 ]] && print_cmd "${PSQL_CMD[*]}"
if command -v psql >/dev/null 2>&1; then
  if "${PSQL_CMD[@]}"; then ok "TCP-Verbindung erfolgreich."; TCP_OK=1
  else
    warn "TCP-Verbindung fehlgeschlagen.
  - Cluster down → 'sudo systemctl restart ${UNIT_NAME}'
  - listen_addresses falsch → 'localhost'
  - Auth (pg_hba.conf) → 127.0.0.1/32 auf 'scram-sha-256' + Passwort
  - Falscher Port → ${PORT}"
    EXIT_CODE=10
  fi
else
  err "psql nicht gefunden."
  EXIT_CODE=4
fi

# ----------------- 9) Reports (.wiki/pg_quickcheck/) -----------------
echo "----------------------------------------"
[[ $WIKI -eq 1 ]] && echo "9) Reports schreiben"
PROJ_ROOT="$(find_proj_root)"
REPORT_DIR="${PROJ_ROOT}/.wiki/pg_quickcheck"
if [[ $WIKI -eq 1 ]]; then
  mkdir -p "$REPORT_DIR"
  MD_FILE="${REPORT_DIR}/latest.md"
  JSON_FILE="${REPORT_DIR}/latest.json"
  JSONL_FILE="${REPORT_DIR}/history.jsonl"

  {
    echo "# pg_quickcheck Report"
    echo ""; echo "- Run-ID: \`${RUN_ID}\`"; echo "- Zeitpunkt: \`$(date +"%F %T %Z")\`"
    echo "- Host: \`${HOST}\`  Port: \`${PORT}\`"; echo ""; echo "## Zusammenfassung"; echo ""
    echo "| Schlüssel | Wert |"; echo "|---|---|"
    echo "| Cluster | ${CLUSTER_VER:-?}-${CLUSTER_NAME:-?} |"
    echo "| Cluster-Status | ${CL_STATUS} |"
    echo "| Unit | ${UNIT_NAME} |"
    echo "| Unit active | ${UNIT_STATUS:-unknown} |"
    echo "| Config | ${CONFIG_PATH:-?-} |"
    echo "| listen/port (conf) | $(printf "%s" "$CONF_LINES" | tr '\n' ' ' | md_escape) |"
    echo "| TCP Listener | $(printf "%s" "$LISTEN_OUT" | tr '\n' ' ' | md_escape) |"
    echo "| Test-User/DB | ${F_USER}/${F_DB} |"
    echo "| TCP-Test | $( [[ ${TCP_OK} -eq 1 ]] && echo "✅ Erfolgreich" || echo "❌ Fehlgeschlagen" ) |"
    [[ $DO_FIX_AUTH -eq 1 ]] && echo "| Aktion | pg_hba.conf → scram-sha-256 (reload) |"
  } >"$MD_FILE"

  {
    printf '{\n'
    printf '  "run_id":"%s",\n' "$RUN_ID"
    printf '  "timestamp":"%s",\n' "$TS_ISO"
    printf '  "host":"%s","port":%s,\n' "$HOST" "$PORT"
    printf '  "cluster":{"version":"%s","name":"%s","status":"%s"},\n' "${CLUSTER_VER:-}" "${CLUSTER_NAME:-}" "${CL_STATUS:-}"
    printf '  "unit":{"name":"%s","is_active":"%s"},\n' "${UNIT_NAME:-}" "${UNIT_STATUS:-unknown}"
    printf '  "config":{"path":"%s","listen_port_lines":"%s"},\n' "${CONFIG_PATH:-}" "$(printf "%s" "$CONF_LINES" | json_escape)"
    printf '  "tcp_listener":"%s",\n' "$(printf "%s" "$LISTEN_OUT" | json_escape)"
    printf '  "test":{"user":"%s","db":"%s","tcp_ok":%s,"exit_code":%s},\n' "$F_USER" "$F_DB" "$(bool "$TCP_OK")" "${EXIT_CODE:-0}"
    printf '  "actions":{"fix_auth":%s,"set_pass":%s},\n' "$(bool "$DO_FIX_AUTH")" "$(bool "$DO_SET_PASS")"
    printf '  "argv":"%s",\n' "$(printf "%s" "$ARGV_ORIG" | json_escape)"
    printf '  "logs_tail":"%s"\n' "$(printf "%s" "$LOG_TAIL" | json_escape)"
    printf '}\n'
  } >"$JSON_FILE"

  cat "$JSON_FILE" >>"$JSONL_FILE"
  ok "Markdown: $MD_FILE"
  ok "JSON:     $JSON_FILE"
  ok "History:  $JSONL_FILE (append)"
fi

# ----------------- 10) Tages-LOG (mit „LOG-Ausgabe“) -----------------
echo "----------------------------------------"
echo "10) Projekt-LOG schreiben"
YEAR="$(date +%Y)"; LOGDIR="${PROJ_ROOT}/.wiki/logs/${YEAR}"; mkdir -p "$LOGDIR"
LOGFILE="${LOGDIR}/LOG-$(date +%Y%m%d).md"

# Kopf beim ersten Anlegen
if [[ ! -s "$LOGFILE" ]]; then
  {
    echo "# Log - $(basename "$PROJ_ROOT") -  $(date +%d.%m.%Y)"
    echo ""; echo "- Pfad: \`${PROJ_ROOT}\`"
    echo "- Host: \`${HOSTNAME:-$(hostname)}\`"
    echo "- Zeitzone: \`$(timedatectl 2>/dev/null | awk -F': ' '/Time zone/ {print $2}' | cut -d' ' -f1 || echo Europe/Berlin)\`"
    git -C "$PROJ_ROOT" rev-parse --short HEAD >/dev/null 2>&1 && \
      echo "- Git: \`$(git -C "$PROJ_ROOT" rev-parse --short HEAD)\`"
    echo ""
  } >>"$LOGFILE"
fi

# Neues Run-Subchapter
{
  echo ""; echo "## Run-ID: \`${RUN_ID}\`"; echo ""
  echo "| Zeit | Script | Version | Optionen | Sektion | Action | Grund | tags | Ergebnis | Dauer (ms) | Exit | User | Notiz | Skript-Meldungen | LOG-Ausgabe |"
  echo "| --- | --- | ---: | --- | --- | --- | --- | --- | :---: | ---: | :---: | --- | --- | --- | --- |"
} >>"$LOGFILE"

NOW_HMS="$(date +%T)"
DURATION_MS="$(( $(date +%s%3N) - T0_MS ))"
RESULT_EMOJI=$([[ ${TCP_OK} -eq 1 ]] && echo "✅" || echo "❌")
OPTS_MD=$([[ -n "$ARGV_ORIG" ]] && echo "\`$ARGV_ORIG\`" || echo "keine")
NOTIZ="Host=${HOST}; Port=${PORT}"
MSG="Unit=${UNIT_NAME}; listen=$(echo "$CONF_LINES" | tr '\n' ' ' | sed 's/|/\\|/g');"

# LOG-Ausgabe (immer in Backticks)
LOG_OUT_CELL=""
if [[ $WIKI -eq 1 ]]; then
  LOG_OUT_CELL="\`$MD_FILE\`<br/>\`$JSON_FILE\`"
fi

printf '| %s | `pg_quickcheck.sh` | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | `%s` | %s |\n' \
  "$NOW_HMS" "$VERSION" "$OPTS_MD" "pg" "tcp-test" "auto" "pg, check" "$RESULT_EMOJI" \
  "$DURATION_MS" "$EXIT_CODE" "$(id -un)" "$NOTIZ" "$MSG" "$LOG_OUT_CELL" >>"$LOGFILE"
ok "Projekt-LOG aktualisiert: $LOGFILE"

# HTML-Render (best-effort)
if command -v log_render_html >/dev/null 2>&1; then
  ( cd "$PROJ_ROOT" && log_render_html )
else
  warn "log_render_html nicht gefunden – HTML-Render übersprungen."
fi

echo "----------------------------------------"
echo "Fertig. Host=${HOST} Port=${PORT} User=${USER_NAME} DB=${DB_NAME}"
exit "${EXIT_CODE:-0}"
