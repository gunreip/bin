#!/usr/bin/env bash
# =====================================================================
#  _git_feature_start.sh — neuen Feature-Branch von main erstellen
#  SCRIPT_VERSION="v0.1.5"
# =====================================================================
# CHANGELOG
# v0.1.5 (2025-09-15) ✅
# - Preflight: 'git ls-remote' gegen origin mit Timeout -> frühe Diagnose
# - Klare Git-Fehler: Exitcode + Hinweis (inkl. Timeout=124)
# - Mehr Ausgaben bei steps>=2 (zeigt Git-Commands)
#
# v0.1.4 (2025-09-15) ✅ No-Prompt + Timeout
# v0.1.3 (2025-09-15) ✅ Robust Stash
#
# shellcheck disable=
# =====================================================================
set -euo pipefail
IFS=$'\n\t'

on_err(){ ec=$?; ln=${BASH_LINENO[0]:-?}; cmd=${BASH_COMMAND:-?}; printf 'ERROR (exit=%s) at line %s: %s\n' "${ec}" "${ln}" "${cmd}" >&2; exit "${ec}"; }
trap on_err ERR

PROG_ID="git_feature_start"
ICON_OK="✅"; ICON_WARN="⚡"; ICON_FAIL="❌"

# Defaults
BASE="main"; PREFIX="feat"; NAME=""; PUSH="no"; AUTO_STASH="no"; DRYRUN="yes"; STEPS=0; NET_TIMEOUT=8

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
git_feature_start — legt Feature-Branch von \`main\` an

Nutzung:
  git_feature_start --name="kurz-beschreibung" [--prefix=feat|fix|chore] [--base=main]
                    [--push] [--auto-stash] [--no-dry-run] [--steps=0|1|2|3] [--timeout=N]
USAGE
}

# Git env
export GIT_TERMINAL_PROMPT=0
HAVE_TIMEOUT=0; command -v timeout >/dev/null 2>&1 && HAVE_TIMEOUT=1
set_ssh_batch(){ if [[ -z "${GIT_SSH_COMMAND:-}" ]]; then export GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=${NET_TIMEOUT}"; fi; }

_run_git(){ # _run_git <args...>
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
      die "git-Fehler ($rc) bei: git $*"
    fi
  fi
}

slug_from_origin(){ local url slug; url="$(git remote get-url origin 2>/dev/null || true)"; [[ -z "${url}" ]] && { echo ""; return; }
  case "${url}" in git@github.com:*) slug="${url#git@github.com:}";; https://github.com/*) slug="${url#https://github.com/}";; *) slug="";; esac
  printf '%s\n' "${slug%.git}"
}
sanitize(){ printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[[:space:]]+/-/g; s/[^a-z0-9._-]+/-/g; s/-+/-/g; s/^-+|-+$//g'; }

report_write(){ local d now; d="${HOME}/bin/reports/${PROG_ID}"; mkdir -p "${d}"; now="$(date +%F' '%T%z)"
  printf '# %s — Report (%s)\n' "git_feature_start" "${now}" > "${d}/latest.md"
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
      --name=*) NAME="${arg#*=}" ;;
      --prefix=*) PREFIX="${arg#*=}" ;;
      --base=*) BASE="${arg#*=}" ;;
      --push) PUSH="yes" ;;
      --auto-stash) AUTO_STASH="yes" ;;
      --no-dry-run) DRYRUN="no" ;;
      --dry-run) DRYRUN="yes" ;;
      --timeout=*) NET_TIMEOUT="${arg#*=}" ;;
      --steps=*) STEPS="${arg#*=}" ;;
      -h|--help) usage; exit 0 ;;
      *) ;;
    esac
  done
  set_ssh_batch
  [[ -n "${NAME}" ]] || die "--name=... fehlt."
  local base branch slug pr_url; base="$(sanitize "${BASE}")"; branch="$(sanitize "${PREFIX}/${NAME}")"

  preflight_origin

  step "Fetch origin (--prune, timeout=${NET_TIMEOUT}s)"
  if [[ "${DRYRUN}" = "yes" ]]; then echo "  - dry-run"; else _run_git fetch --prune; fi

  # Working tree
  if ! git diff --quiet || ! git diff --cached --quiet; then
    if [[ "${AUTO_STASH}" = "yes" ]]; then
      step "Änderungen vorhanden → auto-stash"
      if [[ "${DRYRUN}" = "yes" ]]; then echo "  - dry-run"; else
        ts="$(date +%F_%T)"; git stash push -u -m "git_feature_start ${ts}" || true; stashed="yes"
        stash_ref="$(git stash list -n 1 | sed -n '1{s/:.*$//;p}')" || stash_ref=""
        [[ -n "${stash_ref:-}" ]] && note "Stash: ${stash_ref}"
      fi
    else
      die "Uncommitted Änderungen vorhanden. Abbruch (ohne --auto-stash)."
    fi
  fi

  # base aktualisieren
  step "Wechsle & aktualisiere ${base}"
  if [[ "${DRYRUN}" = "yes" ]]; then echo "  - dry-run"; else
    _run_git switch "${base}" 2>/dev/null || _run_git checkout -B "${base}" "origin/${base}"
    _run_git pull --ff-only
  fi

  # Branch erstellen
  step "Erstelle Branch: ${branch}"
  if [[ "${DRYRUN}" = "yes" ]]; then echo "  - dry-run"; else _run_git switch -c "${branch}"; fi

  # Optional push
  if [[ "${PUSH}" = "yes" ]]; then
    step "Push -u origin ${branch}"
    if [[ "${DRYRUN}" = "yes" ]]; then echo "  - dry-run"; else _run_git push -u origin "${branch}"; fi
  fi

  slug="$(slug_from_origin)"
  if [[ -n "${slug}" ]]; then pr_url="https://github.com/${slug}/compare/${base}...${branch}?expand=1"; note "PR-URL: ${pr_url}"; else pr_url="<no-origin>"; fi
  [[ "${stashed:-no}" = "yes" ]] && { echo "⚡ Es liegt ein Stash an. \`git stash pop\` nicht vergessen."; [[ -n "${stash_ref:-}" ]] && echo "  - Letzter Stash: ${stash_ref}"; }

  ok "Branch bereit: ${branch}"
  report_write \
"- base: \`${base}\`  
- branch: \`${branch}\`  
- pushed: ${PUSH}  
- stashed: ${stashed:-no}  
- pr_url: ${pr_url}  
" \
"{\"base\":\"${base}\",\"branch\":\"${branch}\",\"pushed\":\"${PUSH}\",\"stashed\":\"${stashed:-no}\",\"pr_url\":\"${pr_url}\"}"
}

main "$@"
