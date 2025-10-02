#!/usr/bin/env bash
# _bin-no-comment-txt.sh — v0.4.0
# 1) Legt fehlende comment-bin-tree.txt an (mit <span class="no-comment">…</span>)
# 2) Migriert bestehende comment-bin-tree.txt mit EXAKT "Noch kein Kommentar!" auf <span …>
# 3) --report-only / --dry-run: Nur berichten, keine Änderungen
# 4) Scope-Default: ganzer Tree unter ~/code/bin (Root nur innerhalb dieses Baums erlaubt)

set -euo pipefail
IFS=$'\n\t'
umask 022

DEFAULT_ROOT="${HOME}/code/bin"
REPORT_ONLY="no"
ROOT="${DEFAULT_ROOT}"
declare -a EXCLUDES
EXCLUDES=()   # optionale Glob-Pattern (z. B. '*/.git/*', '*/node_modules/*')

# --- Args --------------------------------------------------------------------
for arg in "$@"; do
  case "$arg" in
    --report-only|--dry-run) REPORT_ONLY="yes" ;;
    --root=*) ROOT="${arg#*=}"; ROOT="${ROOT%/}" ;;
    --exclude=*) EXCLUDES+=("${arg#*=}") ;;
    /*) ROOT="${arg%/}" ;;  # (Kompat: alter Stil mit bare-AbsPath)
    *)  ;;
  esac
done

# Root-Sanity: Muss innerhalb von ~/code/bin liegen
case "${ROOT}" in
  "${HOME}/code/bin"|${HOME}/code/bin/*) : ;;
  *) echo "ABBRUCH: Unerwarteter Root: ${ROOT} (erlaubt ist nur ${HOME}/code/bin bzw. Unterordner davon)" >&2; echo "Hinweis: Dieses Skript schreibt kein Audit!"; exit 3 ;;
esac
[ -d "${ROOT}" ] || { echo "Hinweis: Root nicht gefunden: ${ROOT}"; echo "Hinweis: Dieses Skript schreibt kein Audit!"; exit 0; }

PLACEHOLDER_TXT='Noch kein Kommentar!'
PLACEHOLDER_HTML='<span class="no-comment">Noch kein Kommentar!</span>'

have_cmd(){ command -v "$1" >/dev/null 2>&1; }

# --- Helfer: Exclude-Matching ------------------------------------------------
is_excluded(){
  local path="$1"
  local pat
  for pat in "${EXCLUDES[@]:-}"; do
    case "$path" in
      $pat) return 0 ;;
    esac
  done
  return 1
}

# kleine Reporter
dir_meta(){
  local d="$1"
  local mode perms owner group acl="-" immut="-"
  mode="$(stat -c '%a' "$d" 2>/dev/null || echo '?')"
  perms="$(stat -c '%A' "$d" 2>/dev/null || echo '?')"
  owner="$(stat -c '%U' "$d" 2>/dev/null || echo '?')"
  group="$(stat -c '%G' "$d" 2>/dev/null || echo '?')"
  if have_cmd getfacl; then
    if getfacl -p "$d" 2>/dev/null | sed -n '1,3p' | grep -q '^# file:'; then acl="y"; else acl="n"; fi
  fi
  if have_cmd lsattr; then
    if lsattr -d "$d" 2>/dev/null | awk '{print $1}' | grep -q 'i'; then immut="y"; else immut="n"; fi
  fi
  printf 'owner:%s group:%s mode:%s perms:%s acl:%s immut:%s w:%s' \
    "${owner}" "${group}" "${mode}" "${perms}" "${acl}" "${immut}" $([ -w "$d" ] && echo yes || echo no)
}
file_meta(){
  local f="$1"
  local mode perms owner group acl="-" immut="-"
  mode="$(stat -c '%a' "$f" 2>/dev/null || echo '?')"
  perms="$(stat -c '%A' "$f" 2>/dev/null || echo '?')"
  owner="$(stat -c '%U' "$f" 2>/dev/null || echo '?')"
  group="$(stat -c '%G' "$f" 2>/dev/null || echo '?')"
  if have_cmd getfacl; then
    if getfacl -p "$f" 2>/dev/null | sed -n '1,3p' | grep -q '^# file:'; then acl="y"; else acl="n"; fi
  fi
  if have_cmd lsattr; then
    if lsattr "$f" 2>/dev/null | awk '{print $1}' | grep -q 'i'; then immut="y"; else immut="n"; fi
  fi
  printf 'owner:%s group:%s mode:%s perms:%s acl:%s immut:%s w:%s' \
    "${owner}" "${group}" "${mode}" "${perms}" "${acl}" "${immut}" $([ -w "$f" ] && echo yes || echo no)
}

is_exact_placeholder(){
  local f="$1"
  local content lines
  content="$(tr -d '\r' < "$f" 2>/dev/null || true)"
  lines="$(tr -d '\r' < "$f" 2>/dev/null | wc -l | tr -d ' ' || echo 0)"
  [ "${lines:-0}" -le 1 ] && [ "$content" = "${PLACEHOLDER_TXT}" ]
}

# Zähler (normal)
created=0; skipped_have=0; skipped_nowrite=0; create_denied=0
upgraded=0; kept=0; upgrade_nowrite=0; upgrade_denied=0

# Zähler (report)
would_create=0; would_upgrade=0; would_skip_have=0; would_nowrite_dir=0; would_nowrite_file=0

# --- 1) Ordner durchgehen ----------------------------------------------------
while IFS= read -r -d '' d; do
  # Excludes?
  if is_excluded "$d"; then
    continue
  fi

  f_new="${d}/comment-bin-tree.txt"
  f_old="${d}/comment-bin.tree.txt"   # Legacy-Name

  if [ -f "${f_new}" ] || [ -f "${f_old}" ]; then
    if [ "${REPORT_ONLY}" = "yes" ]; then
      would_skip_have=$((would_skip_have+1))
      if [ -f "${f_new}" ] && is_exact_placeholder "${f_new}"; then
        would_upgrade=$((would_upgrade+1))
        echo "report upgrade: ${f_new}  ($(file_meta "${f_new}"))"
      fi
    else
      skipped_have=$((skipped_have+1))
    fi
    continue
  fi

  if [ "${REPORT_ONLY}" = "yes" ]; then
    would_create=$((would_create+1))
    echo "report create: ${f_new}  ($(dir_meta "${d}"))"
    [ -w "${d}" ] || would_nowrite_dir=$((would_nowrite_dir+1))
    continue
  fi

  if [ ! -w "${d}" ]; then
    echo "skip (no write perms on dir): ${d}"
    skipped_nowrite=$((skipped_nowrite+1))
    continue
  fi
  if ! printf '%s\n' "${PLACEHOLDER_HTML}" > "${f_new}" 2>/dev/null; then
    echo "warn (create failed): ${f_new}  [permission/acl?]"
    create_denied=$((create_denied+1))
    continue
  fi
  created=$((created+1))
  echo "created: ${f_new}"
done < <(find "${ROOT}" -type d -print0)

# --- 2) Migration vorhandener comment-bin-tree.txt ---------------------------
while IFS= read -r -d '' f; do
  # Excludes?
  if is_excluded "$f"; then
    continue
  fi

  if [ "${REPORT_ONLY}" = "yes" ]; then
    if is_exact_placeholder "$f"; then
      would_upgrade=$((would_upgrade+1))
      echo "report upgrade: $f  ($(file_meta "$f"))"
      [ -w "$f" ] || would_nowrite_file=$((would_nowrite_file+1))
    fi
    continue
  fi

  if [ ! -w "$f" ]; then
    echo "skip (no write perms on file): $f"
    upgrade_nowrite=$((upgrade_nowrite+1))
    continue
  fi
  if is_exact_placeholder "$f"; then
    if ! printf '%s\n' "${PLACEHOLDER_HTML}" > "$f" 2>/dev/null; then
      echo "warn (upgrade failed): $f  [permission/acl?]"
      upgrade_denied=$((upgrade_denied+1))
      continue
    fi
    upgraded=$((upgraded+1))
    echo "upgraded: $f"
  else
    kept=$((kept+1))
  fi
done < <(find "${ROOT}" -type f -name 'comment-bin-tree.txt' -print0)

# --- Summary -----------------------------------------------------------------
if [ "${REPORT_ONLY}" = "yes" ]; then
  echo "Report only — no changes done."
  echo " would_create=${would_create} would_upgrade=${would_upgrade} would_skip_have=${would_skip_have} would_nowrite_dir=${would_nowrite_dir} would_nowrite_file=${would_nowrite_file}"
  echo " root=${ROOT}"
  echo "Hinweis: Dieses Skript schreibt kein Audit!"
else
  echo "Done."
  echo " create:  created=${created} skipped_have=${skipped_have} skipped_nowrite=${skipped_nowrite} create_denied=${create_denied}"
  echo " upgrade: upgraded=${upgraded} kept=${kept} upgrade_nowrite=${upgrade_nowrite} upgrade_denied=${upgrade_denied}"
  echo " root:    ${ROOT}"
  echo "Hinweis: Dieses Skript schreibt kein Audit!"
fi
