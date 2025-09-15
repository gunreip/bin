#!/usr/bin/env bash
# =====================================================================
#  _git_sync_bin.sh — Sync ~/bin mit Remote (fetch/pull ff-only, optional push)
#  SCRIPT_VERSION="v0.1.4"
# =====================================================================
# CHANGELOG
# v0.1.4 (2025-09-15) ✅
# - Preflight: 'git ls-remote' mit Timeout → frühe Netz/Auth-Diagnose
# - No-Prompt: GIT_TERMINAL_PROMPT=0, SSH BatchMode=yes (+ConnectTimeout)
# - Timeout für alle Git-Calls (default 8s), --timeout=N
# - Klare Fehlerausgaben (inkl. Timeout=124), Git-Kommandos bei --steps>=2
#
# v0.1.3 (2025-09-15) ✅
# - Robust: ahead/behind parsing, verlässlicher stash-pop
#
# v0.1.2 (2025-09-14) ✅
# - [[ .. ]], Quoting, gepufferte Reads
#
# v0.1.1 (2025-09-14) ✅
# - Icons/if-else, SC2155 entflechtet
#
# v0.1.0 (2025-09-14) ✅
# - Erstversion
#
# shellcheck disable=
# =====================================================================

set -euo pipefail
IFS=$'\n\t'

on_err(){
  ec=$?; ln=${BASH_LINENO[0]:-?}; cmd=${BASH_COMMAND:-?}
  printf 'ERROR (exit=%s) at line %s: %s\n' "${ec}" "${ln}" "${cmd}" >&2
  exit "${ec}"
}
trap on_err ERR

PROG_ID="git_sync_bin"
ICON_OK="✅"; ICON_WARN="⚡"; ICON_FAIL="❌"; ICON_UNKNOWN="⁉️"

BRANCH="main"
MODE="ff"          # ff | rebase | merge
AUTO_STASH="no"
DO_PUSH="no"
DRYRUN="yes"
STEPS=0
NET_TIMEOUT=8

# Colors (TTY)
if [[ -t 1 ]]; then C0=$'\033[0m'; Cb=$'\033[34m'; Cg=$'\033[32m'; Cy=$'\033[33m'; Cr=$'\033[31m'; else C0=""; Cb=""; Cg=""; Cy=""; Cr=""; fi
step(){ [[ "${STEPS}" -ge 1 ]] && printf '%b%s\n' "${Cb}▶${C0} " "$*"; }
note(){ [[ "${STEPS}" -ge 2 ]] && printf '%s\n' "  - $*"; }
dbg(){  [[ "${STEPS}" -ge 3 ]] && printf '%s\n' "    · $*"; }
ok(){   printf '%b%s\n' "${Cg}${ICON_OK}${C0} " "$*"; }
warn(){ printf '%b%s\n' "${Cy}${ICON_WARN}${C0} " "$*"; }
die(){  printf '%b%s\n' "${Cr}${ICON_FAIL}${C0} ERROR:" "$*" >&2; exit 1; }
unknown(){ printf '%s\n' "${ICON_UNKNOWN} $*"; }

gatekeeper(){
  local cwd; cwd="$(pwd -P)"
  if [[ "${cwd%/}" != "${HOME}/bin" ]]; then
    printf '%b%s\n' "${Cr}Gatekeeper:${C0} " "Bitte aus \`~/bin\` ausführen. Aktuell: \`${cwd}\`" >&2
    exit 2
  fi
}

usage(){
  cat <<USAGE
git_sync_bin — Synchronisiert \`~/bin\` mit origin (fetch + pull, optional push)

Nutzung:
  git_sync_bin [--branch=main] [--mode=ff|rebase|merge] [--auto-stash]
               [--push] [--no-dry-run] [--steps=0|1|2|3] [--timeout=N]
USAGE
}

# Git-Umgebung: keine Prompts + Timeout
export GIT_TERMINAL_PROMPT=0
HAVE_TIMEOUT=0; command -v timeout >/dev/null 2>&1 && HAVE_TIMEOUT=1
set_ssh_batch(){
  if [[ -z "${GIT_SSH_COMMAND:-}" ]]; then
    export GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=${NET_TIMEOUT}"
  fi
}
_run_git(){  # _run_git <args...>
  local rc=0
  if [[ "${HAVE_TIMEOUT}" -eq 1 ]]; then
    [[ "${STEPS}" -ge 2 ]] && echo "  - git(≤${NET_TIMEOUT}s): $*" >&2
    timeout "${NET_TIMEOUT}s" git "$@" || rc=$?
  else
    [[ "${STEPS}" -ge 2 ]] && echo "  - git: $*" >&2
    git "$@" || rc=$?
  fi
  if [[ "${rc}" -ne 0 ]]; then
    if [[ "${rc}" -eq 124 ]]; then
      die "Timeout (${NET_TIMEOUT}s) bei: git $*"
    else
      die "git-Fehler (${rc}) bei: git $*"
    fi
  fi
}

current_branch(){ git rev-parse --abbrev-ref HEAD; }

ahead_behind(){
  local up lb rb base
  up="$(git rev-parse --abbrev-ref --symbolic-full-name @{u} 2>/dev/null || true)"
  if [[ -z "${up}" ]]; then echo "0 0"; return; fi
  lb="$(git rev-parse @)"
  rb="$(git rev-parse @{u})"
  base="$(git merge-base @ @{u})"
  if [[ "${lb}" = "${rb}" ]]; then echo "0 0"; return; fi
  if [[ "${lb}" = "${base}" ]]; then echo "0 1"; return; fi
  if [[ "${rb}" = "${base}" ]]; then echo "1 0"; return; fi
  local a b
  a="$(git rev-list --left-right --count @{u}...@ | awk '{print $2}')"
  b="$(git rev-list --left-right --count @{u}...@ | awk '{print $1}')"
  printf '%s %s\n' "${a}" "${b}"
}

report_write(){
  local md json now
  md="${HOME}/bin/reports/${PROG_ID}/latest.md"
  json="${HOME}/bin/reports/${PROG_ID}/latest.json"
  mkdir -p "$(dirname "${md}")"
  now="$(date +%F' '%T%z)"
  printf '# %s — Report (%s)\n' "git_sync_bin" "${now}" > "${md}"
  printf '%s\n' "$1" >> "${md}"
  printf '%s\n' "$2" > "${json}"
}

preflight_origin(){
  step "Preflight: origin erreichbar? (ls-remote, timeout=${NET_TIMEOUT}s)"
  _run_git ls-remote --heads origin >/dev/null 2>&1
}

main(){
  gatekeeper
  command -v git >/dev/null 2>&1 || die "'git' nicht gefunden."

  for arg in "$@"; do
    case "${arg}" in
      --branch=*) BRANCH="${arg#*=}" ;;
      --mode=ff) MODE="ff" ;;
      --mode=rebase) MODE="rebase" ;;
      --mode=merge) MODE="merge" ;;
      --auto-stash) AUTO_STASH="yes" ;;
      --push) DO_PUSH="yes" ;;
      --no-dry-run) DRYRUN="no" ;;
      --dry-run) DRYRUN="yes" ;;
      --timeout=*) NET_TIMEOUT="${arg#*=}" ;;
      --steps=*) STEPS="${arg#*=}" ;;
      -h|--help) usage; exit 0 ;;
      *) ;;
    esac
  done

  [[ -d .git ]] || die "Kein Git-Repository unter \`~/bin\`."
  set_ssh_batch

  preflight_origin

  step "Fetch origin (--prune, timeout=${NET_TIMEOUT}s)"
  if [[ "${DRYRUN}" = "yes" ]]; then
    warn "dry-run: fetch nur simuliert"
  else
    _run_git fetch --prune
  fi

  # Branch wechseln falls nötig
  local cur; cur="$(current_branch)"
  if [[ "${cur}" != "${BRANCH}" ]]; then
    step "Wechsle Branch: ${cur} → ${BRANCH}"
    if [[ "${DRYRUN}" = "yes" ]]; then
      warn "dry-run: checkout nur simuliert"
    else
      _run_git switch "${BRANCH}" 2>/dev/null || _run_git checkout -B "${BRANCH}" "origin/${BRANCH}"
    fi
  fi

  # Working tree prüfen
  if ! git diff --quiet || ! git diff --cached --quiet; then
    if [[ "${AUTO_STASH}" = "yes" ]]; then
      step "Änderungen vorhanden → auto-stash"
      if [[ "${DRYRUN}" = "yes" ]]; then
        warn "dry-run: stash nur simuliert"
      else
        ts="$(date +%F_%T)"
        git stash push -u -m "git_sync_bin ${ts}" || true
        stashed="yes"
        stash_ref="$(git stash list -n 1 | sed -n '1{s/:.*$//;p}')" || stash_ref=""
        [[ -n "${stash_ref:-}" ]] && note "Stash: ${stash_ref}"
      fi
    else
      die "Uncommitted Änderungen vorhanden. Abbruch (ohne --auto-stash)."
    fi
  fi

  # Pull
  step "Pull (${MODE})"
  if [[ "${DRYRUN}" = "yes" ]]; then
    warn "dry-run: pull nur simuliert"
  else
    case "${MODE}" in
      ff)     _run_git pull --ff-only ;;
      rebase) _run_git pull --rebase ;;
      merge)  _run_git pull ;;
      *)      die "Unbekannter mode: ${MODE}" ;;
    esac
  fi

  # Upstream-Status robust ermitteln
  local ahead=0 behind=0 out=""
  out="$(ahead_behind 2>/dev/null || echo '')"
  if [[ -n "${out}" ]]; then
    IFS=' ' read -r ahead behind <<<"${out}" || { ahead=0; behind=0; }
  else
    ahead=0; behind=0
  fi
  note "Status vs upstream: ahead=${ahead} behind=${behind}"

  # Optional Push
  if [[ "${DO_PUSH}" = "yes" ]] && [[ "${DRYRUN}" = "no" ]] && [[ "${ahead:-0}" -gt 0 ]]; then
    step "Push local → origin/${BRANCH}"
    _run_git push
  fi

  # Stash zurück
  if [[ "${stashed:-no}" = "yes" ]] && [[ "${DRYRUN}" = "no" ]]; then
    step "Stash zurückspielen"
    git stash pop || warn "Stash-Pop mit Konflikten — bitte manuell prüfen."
  fi

  ok "Sync abgeschlossen."
  report_write \
"- Branch: \`${BRANCH}\`  
- Mode: \`${MODE}\` · auto-stash: ${AUTO_STASH} · push: ${DO_PUSH}  
- DRYRUN: ${DRYRUN} · ahead=${ahead} · behind=${behind}  
" \
"{\"branch\":\"${BRANCH}\",\"mode\":\"${MODE}\",\"auto_stash\":\"${AUTO_STASH}\",\"push\":\"${DO_PUSH}\",\"dryrun\":\"${DRYRUN}\",\"ahead\":${ahead},\"behind\":${behind}}"
}

main "$@"
