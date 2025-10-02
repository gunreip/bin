#!/usr/bin/env bash
# git-tag.sh — Tags listen/erstellen/löschen mit SemVer-Bump & Audit
# Version: v0.2.2
set -Eeuo pipefail; IFS=$'\n\t'
[ -z "${BASH_VERSION:-}" ] && exec /usr/bin/env bash "$0" "$@"

SCRIPT_ID="git-tag"
VERSION="v0.2.2"

trap 'rc=$?; echo "ERROR: ${BASH_SOURCE##*/}:${LINENO}: exit $rc while running: ${BASH_COMMAND:-<none>}"; exit $rc' ERR

# ---------- Defaults ----------
DRY_RUN="no"
ACTION="list"            # list|create|delete
TAG_NAME=""              # --tag=
BUMP=""                  # patch|minor|major
ANNOTATED="yes"          # --annotated=yes|no
MESSAGE=""               # --message="..."
PUSH="no"                # --push
REMOTE="origin"          # --remote=
DELETE_NAME=""           # --delete=<tag>
DELETE_MATCH=""          # --delete-matching=<glob>
FORCE="no"               # --force
PREFIX="v"               # --prefix=
AUDIT="yes"              # Default: Audit an
DEBUG_MODE=""            # --debug=dbg|trace|xtrace (oder via .debug.conf.json)

# Pfade
ROOT="$HOME/code/bin/shellscripts"
RUNS_DIR="$ROOT/runs/$SCRIPT_ID"
AUDIT_DIR="$ROOT/audits/$SCRIPT_ID"
DEBUG_DIR="$ROOT/debugs/$SCRIPT_ID"
TRASH_DIR="$ROOT/trash/$SCRIPT_ID"
CSS_FILE="$AUDIT_DIR/$SCRIPT_ID.css"
MD_FILE="$AUDIT_DIR/latest.md"
HTML_FILE="$AUDIT_DIR/latest.html"

# ---------- Helpers ----------
short(){ printf '%s' "${1/#$HOME/~}"; }
now_ts(){ date +%Y%m%d-%H%M%S; }
now_iso(){ date '+%Y-%m-%d %H:%M:%S'; }  # ohne Offset
usage(){ cat <<USAGE
$SCRIPT_ID $VERSION
Git-Tags listen/erstellen/löschen mit SemVer-Helfern und optionalem Push.
Audit (append MD + Pandoc->HTML) ist per Default aktiv.

Aufruf:
  $SCRIPT_ID [--list] [--create [--tag=NAME | --bump=patch|minor|major] [--annotated=yes|no] [--message=TEXT]] \\
            [--delete=NAME | --delete-matching=GLOB] [--force] [--push [--remote=origin]] \\
            [--prefix=v] [--dry-run] [--no-audit] [--debug=dbg|trace|xtrace] [--help|--version]
USAGE
}
die(){ echo "ERR: $*"; exit 2; }

# Gatekeeper: im Repo?
ensure_repo(){ git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "Kein Git-Repository (hier: $(pwd))"; }

# Debug-Config laden (~/code/bin/.debug.conf.json)
DEBUG_CONFIG_PATH="${DEBUG_CONFIG_PATH:-$HOME/code/bin/.debug.conf.json}"
load_debug_config(){
  local cfg="$DEBUG_CONFIG_PATH" val=""
  [ -f "$cfg" ] || return 0
  # overrides für dieses Skript
  val="$(sed -n '/"overrides"[[:space:]]*:/,/\}/p' "$cfg" \
        | sed -n "/\"$SCRIPT_ID\"[[:space:]]*:/,/\}/p" \
        | sed -n 's/.*"mode"[[:space:]]*:[[:space:]]*"\([^"]\+\)".*/\1/p' | head -n1)"
  # defaults, falls leer
  if [ -z "${val:-}" ]; then
    val="$(sed -n '/"defaults"[[:space:]]*:/,/\}/p' "$cfg" \
          | sed -n 's/.*"mode"[[:space:]]*:[[:space:]]*"\([^"]\+\)".*/\1/p' | head -n1)"
  fi
  case "$val" in
    off|"") : ;;
    dbg|trace|xtrace)
      if [ -z "${DEBUG_MODE:-}" ]; then DEBUG_MODE="$val"; fi
      ;;
  esac
}

# Debug-Logging (keine nackten Tests mit set -e)
setup_debug(){
  if [ -z "${DEBUG_MODE:-}" ]; then
    return 0
  fi
  mkdir -p "$DEBUG_DIR"
  ts="$(now_ts)"
  case "$DEBUG_MODE" in
    dbg)
      : > "$DEBUG_DIR/$SCRIPT_ID.dbg.$ts"
      ;;
    trace)
      : > "$DEBUG_DIR/$SCRIPT_ID.trace.$ts"
      exec 19> "$DEBUG_DIR/$SCRIPT_ID.trace.$ts"
      BASH_XTRACEFD=19
      set -o functrace
      ;;
    xtrace)
      : > "$DEBUG_DIR/$SCRIPT_ID.xtrace.$ts"
      exec 19> "$DEBUG_DIR/$SCRIPT_ID.xtrace.$ts"
      BASH_XTRACEFD=19
      set -x
      ;;
    *)
      : ;; # ignorieren
  esac
}

# SemVer ermitteln (letzter Tag)
latest_semver(){
  local pat="^${PREFIX}?([0-9]+)\\.([0-9]+)\\.([0-9]+)$"
  git tag --list "${PREFIX}*.*.*" | grep -E "$pat" | sort -V | tail -n1
}

# Bump
bump_tag(){
  local base="$1" bump="$2" pat="^${PREFIX}?([0-9]+)\\.([0-9]+)\\.([0-9]+)$"
  local maj=0 min=0 patc=0
  if [[ "$base" =~ $pat ]]; then maj="${BASH_REMATCH[1]}"; min="${BASH_REMATCH[2]}"; patc="${BASH_REMATCH[3]}"; fi
  case "$bump" in
    ""|patch) patc=$((patc+1));;
    minor)    min=$((min+1)); patc=0;;
    major)    maj=$((maj+1)); min=0; patc=0;;
    *) die "Ungültiges --bump=$bump (patch|minor|major)";;
  esac
  echo "${PREFIX}${maj}.${min}.${patc}"
}

# Safe create tag
create_tag(){
  local name="$1" annotated="$2" msg="$3" dry="$4" force="$5"
  if git show-ref --tags --quiet -- "refs/tags/$name"; then
    if [ "$force" = "yes" ]; then
      if [ "$dry" != "yes" ]; then git tag -d "$name" >/dev/null; fi
    else
      die "Tag existiert bereits: $name (nutze --force)"
    fi
  fi
  if [ "$dry" = "yes" ]; then
    echo "plan: create $name (${annotated})"
  else
    if [ "$annotated" = "yes" ]; then
      if [ -z "${msg:-}" ]; then msg="Release $name"; fi
      git tag -a "$name" -m "$msg"
    else
      git tag "$name"
    fi
  fi
}

# Safe delete tag
delete_one(){
  local name="$1" dry="$2" force="$3"
  if git show-ref --tags --quiet -- "refs/tags/$name"; then
    if [ "$dry" != "yes" ]; then git tag -d "$name" >/dev/null; fi
    echo "plan: delete $name"
  else
    if [ "$force" = "yes" ]; then
      echo "note: $name existiert lokal nicht (force: ok)"
    else
      echo "note: $name existiert lokal nicht (übersprungen)"
    fi
  fi
}

# Push helper
push_tags(){
  local remote="$1" what="$2" dry="$3"
  if [ "$dry" = "yes" ]; then echo "plan: push ($what) to $remote"; return 0; fi
  case "$what" in
    all) git push "$remote" --tags;;
    name:*) git push "$remote" "refs/tags/${what#name:}";;
    delete:*) git push "$remote" ":refs/tags/${what#delete:}";;
    *) die "Unbekannte push-Aktion: $what";;
  esac
}

# ---------- CLI ----------
for arg in "$@"; do
  case "$arg" in
    --help) usage; exit 0;;
    --version) echo "$VERSION"; exit 0;;
    --list) ACTION="list";;
    --create) ACTION="create";;
    --delete=*) ACTION="delete"; DELETE_NAME="${arg#*=}";;
    --delete-matching=*) ACTION="delete"; DELETE_MATCH="${arg#*=}";;
    --tag=*) TAG_NAME="${arg#*=}";;
    --bump=patch|--bump=minor|--bump=major) BUMP="${arg#*=}";;
    --annotated=yes|--annotated=no) ANNOTATED="${arg#*=}";;
    --message=*) MESSAGE="${arg#*=}";;
    --push) PUSH="yes";;
    --remote=*) REMOTE="${arg#*=}";;
    --prefix=*) PREFIX="${arg#*=}";;
    --force) FORCE="yes";;
    --dry-run) DRY_RUN="yes";;
    --no-audit) AUDIT="no";;
    --audit) AUDIT="yes";;
    --debug=*) DEBUG_MODE="${arg#*=}";;
    *) die "Unbekannte Option: $arg (siehe --help)";;
  esac
done

# ---------- Gatekeeper & Debug ----------
ensure_repo
load_debug_config
setup_debug

# ---------- Repo-Kontext ----------
REPO_ROOT="$(git rev-parse --show-toplevel)"
HEAD_SHA="$(git rev-parse --short=12 HEAD)"
HEAD_REF="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || echo "(detached)")"

mkdir -p "$RUNS_DIR" "$AUDIT_DIR" "$DEBUG_DIR" "$TRASH_DIR"

# ---------- Aktionen ----------
created=0; deleted=0; pushed=0; listed=0
created_names=""; deleted_names=""; list_out=""

case "$ACTION" in
  list)
    list_out="$(git tag --list | sort -V)"
    listed=$(printf '%s\n' "$list_out" | sed '/^$/d' | wc -l | tr -d ' ')
    ;;
  create)
    if [ -n "$TAG_NAME" ]; then
      NEW_TAG="$TAG_NAME"
    else
      base="$(latest_semver || true)"
      NEW_TAG="$(bump_tag "${base:-${PREFIX}0.0.0}" "$BUMP")"
    fi
    create_tag "$NEW_TAG" "$ANNOTATED" "$MESSAGE" "$DRY_RUN" "$FORCE"
    created=$((created+1))
    created_names="${created_names:+$created_names; }$NEW_TAG"
    if [ "$PUSH" = "yes" ]; then
      push_tags "$REMOTE" "name:$NEW_TAG" "$DRY_RUN"
      pushed=$((pushed+1))
    fi
    ;;
  delete)
    if [ -n "$DELETE_NAME" ]; then
      to_del="$DELETE_NAME"
    elif [ -n "$DELETE_MATCH" ]; then
      to_del="$(git tag --list "$DELETE_MATCH" || true)"
    else
      die "Für --delete ist --delete=<name> oder --delete-matching=<glob> nötig."
    fi
    OLD_IFS="$IFS"; IFS=$'\n'
    for t in $to_del; do
      if [ -n "$t" ]; then
        delete_one "$t" "$DRY_RUN" "$FORCE"
        deleted=$((deleted+1))
        deleted_names="${deleted_names:+$deleted_names; }$t"
        if [ "$PUSH" = "yes" ]; then
          push_tags "$REMOTE" "delete:$t" "$DRY_RUN"
          pushed=$((pushed+1))
        fi
      fi
    done
    IFS="$OLD_IFS"
    ;;
  *) die "Unbekannte Aktion";;
esac

# ---------- Terminal-Ausgabe ----------
echo "target(s): $(short "$REPO_ROOT")"
printf "%-6s %-13s %s\n" "repo:" "head:" "$HEAD_REF@$HEAD_SHA"
printf "%-6s %-13s %s\n" "mode:" "" "$([ "$DRY_RUN" = "yes" ] && echo dry-run || echo apply)"

W=34
pad_kv(){ local pfx="$1" lbl="$2" val="$3"; local n=${#lbl}; local pad=$(( W - n )); (( pad<1 )) && pad=1; printf "%-6s %s%*s %6d\n" "$pfx" "$lbl" "$pad" "" "$val"; }

if [ "$ACTION" = "list" ]; then
  pad_kv "scan:" "tags (gesamt):" "$listed"
else
  pad_kv "act:" "created:" "$created"
  pad_kv ""     "deleted:" "$deleted"
  if [ "$PUSH" = "yes" ]; then pad_kv "" "pushed:" "$pushed"; fi
fi

# ---------- Audit ----------
if [ "$AUDIT" = "yes" ]; then
  ts_id="$(now_ts)"; ts_human="$(now_iso)"
  css_status="kept"
  if [ ! -f "$CSS_FILE" ]; then
    mkdir -p "$AUDIT_DIR"
    cat > "$CSS_FILE" <<'CSS'
:root{--fg:#222;--bg:#fff;--muted:#666;--accent:#0a7;}
body{font-family:system-ui,Arial,sans-serif;color:var(--fg);background:var(--bg);line-height:1.5;margin:2rem;}
h1{margin:0 0 .25rem 0;font-weight:700}
h2{margin:.25rem 0 1rem 0;color:var(--muted);font-weight:500}
table{border-collapse:collapse;width:100%;margin:1rem 0}
th,td{border:1px solid #ddd;padding:.5rem .6rem;text-align:left}
th{background:#f5f5f5}
code,pre{font-family:ui-monospace,Menlo,Consolas,monospace;font-size:.95em}
details{margin:.4rem 0}
summary{cursor:pointer;color:var(--accent)}
CSS
    css_status="wrote"
  fi

  mkdir -p "$AUDIT_DIR"
  [ -s "$MD_FILE" ] && printf "\n" >> "$MD_FILE"
  {
    echo "### Run-Id: $ts_id"
    echo ""
    echo "| Script | Version | Mode | Repo | HEAD | Action | Created | Deleted | Pushed |"
    echo "|-------:|:-------:|:----:|:-----|:-----|:------:|-------:|-------:|-------:|"
    if [ "$ACTION" = "list" ]; then
      echo "| \`$SCRIPT_ID\` | \`$VERSION\` | \`$([ "$DRY_RUN" = "yes" ] && echo dry-run || echo apply)\` | \`$(short "$REPO_ROOT")\` | \`$HEAD_REF@$HEAD_SHA\` | \`list\` | 0 | 0 | 0 |"
    else
      echo "| \`$SCRIPT_ID\` | \`$VERSION\` | \`$([ "$DRY_RUN" = "yes" ] && echo dry-run || echo apply)\` | \`$(short "$REPO_ROOT")\` | \`$HEAD_REF@$HEAD_SHA\` | \`$ACTION\` | $created | $deleted | $([ "$PUSH" = "yes" ] && echo $pushed || echo 0) |"
    fi
    echo ""
    echo "<details class=\"details-list\"><summary>Summary:</summary>"
    echo "  <details><summary>Created</summary><code>${created_names}</code></details>"
    echo "  <details><summary>Deleted</summary><code>${deleted_names}</code></details>"
    if [ "$ACTION" = "list" ]; then
      compact="$(printf '%s' "$list_out" | sed '/^$/d' | paste -sd '; ' -)"
      echo "  <details><summary>List</summary><code>${compact}</code></details>"
    fi
    echo "  <details><summary>Annotated</summary><code>$ANNOTATED</code></details>"
    if [ -n "${MESSAGE:-}" ]; then
      safe_msg="$(printf '%s' "$MESSAGE" | sed 's/&/&amp;/g;s/</\&lt;/g;s/>/\&gt;/g')"
      echo "  <details><summary>Message</summary><code>$safe_msg</code></details>"
    else
      echo "  <details inert><summary>Message</summary><code></code></details>"
    fi
    echo "  <details><summary>Push</summary><code>$([ "$PUSH" = "yes" ] && echo "yes ($REMOTE)" || echo no)</code></details>"
    echo "  <details><summary>Prefix</summary><code>$PREFIX</code></details>"
    echo "  <details><summary>Debugs</summary><code>$(short "$DEBUG_DIR")</code></details>"
    echo "</details>"
  } >> "$MD_FILE"
  echo "md:    appended:   $(short "$MD_FILE")"

  if command -v pandoc >/dev/null 2>&1; then
    tmp_html="$(mktemp)"
    pandoc --from gfm --to html5 --standalone \
      --metadata title="Audit \`$SCRIPT_ID\` — $ts_human" \
      --output "$tmp_html" "$MD_FILE"
    {
      awk -v css="$(basename "$CSS_FILE")" -v sid="$SCRIPT_ID" -v ver="$VERSION" -v canon="$HOME/code/bin/shellscripts/$SCRIPT_ID.sh" -v ts="$ts_human" '
        BEGIN{ins=0}
        /<head>/ && ins==0 { print; print "  <link rel=\"stylesheet\" href=\"" css "\"/>"; ins=1; next }
        /<body[^>]*>/ && !seen_body { print; print "<h1>Audit <code>" sid "</code> — " ts "</h1>"; print "<h2 id=\"" sid "-subheader\">" canon " - " ver "</h2>"; seen_body=1; next }
        { print }
      ' "$tmp_html" > "$HTML_FILE"
    }
    rm -f "$tmp_html"
    echo "html:  overwrote:  $(short "$HTML_FILE")"
  else
    echo "html:  skipped:    pandoc not found"
  fi

  if [ "$css_status" = "wrote" ]; then
    echo "css:   wrote:      $(short "$CSS_FILE")"
  else
    echo "css:   kept:       $(short "$CSS_FILE") (linked-ok)"
  fi
fi

exit 0
