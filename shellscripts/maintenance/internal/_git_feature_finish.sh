#!/usr/bin/env bash
# =====================================================================
#  _git_feature_finish.sh — Feature-Branch abschließen (update, push, PR-URL)
#  SCRIPT_VERSION="v0.1.5"
# =====================================================================
# CHANGELOG
# v0.1.5 (2025-09-15) ✅
# - Preflight: 'git ls-remote' gegen origin
# - Klare Git-Fehler: Exitcode + Hinweis (inkl. Timeout=124)
# - steps>=2 zeigt Git-Commands; Warnung wenn BASE lokal ahead
#
# v0.1.4 (2025-09-15) ✅ No-Prompt + Timeout
# v0.1.3 (2025-09-15) ✅ Robust ahead/behind
#
# shellcheck disable=
# =====================================================================
set -euo pipefail
IFS=$'\n\t'

on_err(){ ec=$?; ln=${BASH_LINENO[0]:-?}; cmd=${BASH_COMMAND:-?}; printf 'ERROR (exit=%s) at line %s: %s\n' "${ec}" "${ln}" "${cmd}" >&2; exit "${ec}"; }
trap on_err ERR

PROG_ID="git_feature_finish"
ICON_OK="✅"; ICON_WARN="⚡"; ICON_FAIL="❌"

# Defaults
BASE="main"; BRANCH=""; MODE="ff"; PUSH="yes"; DRYRUN="yes"; STEPS=0; NET_TIMEOUT=8

# Colors
if [[ -t 1 ]]; then C0=$'\033[0m'; Cb=$'\033[34m'; Cg=$'\033[32m'; Cy=$'\033[33m'; Cr=$'\033[31m'; else C0=""; Cb=""; Cg=""; Cy=""; Cr=""; fi
step(){ [[ "${STEPS}" -ge 1 ]] && printf '%b%s\n' "${Cb}▶${C0} " "$*"; }
note(){ [[ "${STEPS}" -ge 2 ]] && printf '%s\n' "  - $*"; }
dbg(){  [[ "${STEPS}" -ge 3 ]] && printf '%s\n' "    · $*"; }
ok(){   printf '%b%s\n' "${Cg}${ICON_OK}${C0} " "$*"; }
die(){  printf '%b%s\n' "${Cr}${ICON_FAIL}${C0} ERROR:" "$*" >&2; exit 1; }

gatekeeper(){ local cwd; cwd="$(pwd -P)"; if [[ "${cwd%/}" != "${HOME}/bin" ]]; then printf '%b%s\n' "${Cr}Gatekeeper:${C0} " "Bitte aus \`~/bin\` ausführen. Aktuell: \`${cwd}\`" >&2; exit 2; fi; }

usage(){
  cat <<USAGE
git_feature_finish — bereitet Feature-Branch für PR/Merge vor

Nutzung:
  git_feature_finish [--branch=<aktuell>] [--base=main] [--mode=ff|rebase|merge]
                     [--push|--no-push] [--no-dry-run] [--steps=0|1|2|3] [--timeout=N]
USAGE
}

export GIT_TERMINAL_PROMPT=0
HAVE_TIMEOUT=0; command -v timeout >/dev/null 2>&1 && HAVE_TIMEOUT=1
set_ssh_batch(){ if [[ -z "${GIT_SSH_COMMAND:-}" ]]; then export GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=${NET_TIMEOUT}"; fi; }
_run_git(){ local rc=0
  if [[ "${HAVE_TIMEOUT}" -eq 1 ]]; then [[ "${STEPS}" -ge 2 ]] && echo "  - git(≤${NET_TIMEOUT}s): $*" >&2; timeout "${NET_TIMEOUT}s" git "$@" || rc=$?
  else [[ "${STEPS}" -ge 2 ]] && echo "  - git: $*" >&2; git "$@" || rc=$?; fi
  if [[ "${rc}" -ne 0 ]]; then
    if [[ "${rc}" -eq 124 ]]; then die "Timeout (${NET_TIMEOUT}s) bei: git $*"; else die "git-Fehler ($rc) bei: git $*"; fi
  fi
}

slug_from_origin(){ local url slug; url="$(git remote get-url origin 2>/dev/null || true)"; [[ -z "${url}" ]] && { echo ""; return; }
  case "${url}" in git@github.com:*) slug="${url#git@github.com:}";; https://github.com/*) slug="${url#https://github.com/}";; *) slug="";; esac
  printf '%s\n' "${slug%.git}"
}
current_branch(){ git rev-parse --abbrev-ref HEAD; }
ahead_behind(){ local up lb rb base; up="$(git rev-parse --abbrev-ref --symbolic-full-name @{u} 2>/dev/null || true)"
  if [[ -z "${up}" ]]; then echo "0 0"; return; fi
  lb="$(git rev-parse @)"; rb="$(git rev-parse @{u})"; base="$(git merge-base @ @{u})"
  if [[ "${lb}" = "${rb}" ]]; then echo "0 0"; return; fi
  if [[ "${lb}" = "${base}" ]]; then echo "0 1"; return; fi
  if [[ "${rb}" = "${base}" ]]; then echo "1 0"; return; fi
  local a b; a="$(git rev-list --left-right --count @{u}...@ | awk '{print $2}')"; b="$(git rev-list --left-right --count @{u}...@ | awk '{print $1}')"
  printf '%s %s\n' "${a}" "${b}"
}

report_write(){ local d now; d="${HOME}/bin/reports/${PROG_ID}"; mkdir -p "${d}"; now="$(date +%F' '%T%z)"
  printf '# %s — Report (%s)\n' "git_feature_finish" "${now}" > "${d}/latest.md"
  printf '%s\n' "$1" >> "${d}/latest.md"; printf '%s\n' "$2" >  "${d}/latest.json"
}

preflight_origin(){
  step "Preflight: origin erreichbar? (ls-remote, timeout=${NET_TIMEOUT}s)"
  _run_git ls-remote --heads origin >/dev/null 2>&1
}

main(){
  gatekeeper; command -v git >/dev/null 2>&1 || die "'git' nicht gefunden."; [[ -d .git ]] || die "Kein Git-Repository unter \`~/bin\`."

  for arg in "$@"; do
    case "${arg}" in
      --branch=*) BRANCH="${arg#*=}" ;;
      --base=*) BASE="${arg#*=}" ;;
      --mode=*) MODE="${arg#*=}" ;;
      --push) PUSH="yes" ;;
      --no-push) PUSH="no" ;;
      --no-dry-run) DRYRUN="no" ;;
      --dry-run) DRYRUN="yes" ;;
      --timeout=*) NET_TIMEOUT="${arg#*=}" ;;
      --steps=*) STEPS="${arg#*=}" ;;
      -h|--help) usage; exit 0 ;;
      *) ;;
    esac
  done
  set_ssh_batch
  if [[ -z "${BRANCH}" ]]; then BRANCH="$(current_branch)"; fi
  [[ "${BRANCH}" != "${BASE}" ]] || die "Aktueller Branch ist \`${BASE}\`. Bitte Feature-Branch aktivieren."

  preflight_origin

  step "Fetch origin (--prune, timeout=${NET_TIMEOUT}s)"
  if [[ "${DRYRUN}" = "yes" ]]; then echo "  - dry-run"; else _run_git fetch --prune; fi

  step "Aktualisiere ${BASE}"
  if [[ "${DRYRUN}" = "yes" ]]; then echo "  - dry-run"; else
    _run_git switch "${BASE}" 2>/dev/null || _run_git checkout -B "${BASE}" "origin/${BASE}"
    _run_git pull --ff-only
    if git rev-list --left-right --count origin/"${BASE}"..."${BASE}" | awk '{exit !($2>0)}'; then
      printf '⚡ %s ist lokal vor origin/%s. Falls gewollt: `git push origin %s`.\n' "${BASE}" "${BASE}" "${BASE}" >&2
    fi
  fi

  step "Zurück auf ${BRANCH}"
  if [[ "${DRYRUN}" = "yes" ]]; then echo "  - dry-run"; else _run_git switch "${BRANCH}"; fi

  step "Update-Strategie: ${MODE}"
  if [[ "${DRYRUN}" = "yes" ]]; then echo "  - dry-run"; else
    case "${MODE}" in
      ff)     : ;;
      rebase) _run_git rebase "${BASE}" ;;
      merge)  _run_git merge --no-ff "${BASE}" ;;
      *)      die "Unbekannter mode: ${MODE}" ;;
    esac
  fi

  local ahead=0 behind=0 out=""; out="$(ahead_behind 2>/dev/null || echo '0 0')"
  IFS=' ' read -r ahead behind <<<"${out}"
  note "Status vs upstream: ahead=${ahead} behind=${behind}"
  if [[ "${PUSH}" = "yes" ]] && [[ "${DRYRUN}" = "no" ]] && [[ "${ahead:-0}" -gt 0 ]]; then
    step "Push ${BRANCH} → origin/${BRANCH}"
    _run_git push -u origin "${BRANCH}"
  fi

  local slug pr_url; slug="$(slug_from_origin)"
  if [[ -n "${slug}" ]]; then pr_url="https://github.com/${slug}/compare/${BASE}...${BRANCH}?expand=1"; note "PR-URL: ${pr_url}"; else pr_url="<no-origin>"; fi

  ok "Feature-Branch bereit für PR/Merge."
  report_write \
"- base: \`${BASE}\`  
- branch: \`${BRANCH}\`  
- mode: \`${MODE}\` · push: ${PUSH}  
- pr_url: ${pr_url}  
- ahead: ${ahead} · behind: ${behind}  
" \
"{\"base\":\"${BASE}\",\"branch\":\"${BRANCH}\",\"mode\":\"${MODE}\",\"push\":\"${PUSH}\",\"pr_url\":\"${pr_url}\",\"ahead\":${ahead},\"behind\":${behind}}"
}

main "$@"
