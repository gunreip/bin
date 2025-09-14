#!/usr/bin/env bash
set -euo pipefail

TARGET="${1:-$HOME/bin/systemd_timer_status.sh}"
[[ -f "$TARGET" ]] || { echo "❌ Datei nicht gefunden: $TARGET" >&2; exit 1; }

ts="$(date +%Y%m%d_%H%M%S)"
cp -a -- "$TARGET" "${TARGET}.bak.${ts}"

# ── Version ermitteln & Patch-Level +1 ────────────────────────────────────────────
cur_ver="$(grep -E '^SCRIPT_VERSION="' "$TARGET" | head -n1 | sed -E 's/.*"([^"]+)".*/\1/')"
if [[ -z "${cur_ver:-}" ]]; then
  cur_ver="$(grep -E '^# Version: ' "$TARGET" | head -n1 | awk '{print $3}')"
fi
cur_ver="${cur_ver:-0.1.0}"
IFS='.' read -r vMA vMI vPA <<<"$cur_ver"
vMA="${vMA:-0}"; vMI="${vMI:-1}"; vPA="${vPA:-0}"
new_ver="${vMA}.${vMI}.$(( vPA + 1 ))"

# in Header & Variable ersetzen
sed -i -E "s/^(# Version: )[0-9]+\.[0-9]+\.[0-9]+/\1${new_ver}/" "$TARGET"
sed -i -E "s/^(SCRIPT_VERSION=\")[^\"]+\"/\1${new_ver}\"/" "$TARGET"

# ── usec_to_iso robust ersetzen/ergänzen (nur wenn nötig) ─────────────────────────
need_date_parse_fix=1
grep -q 'usec_to_iso' "$TARGET" || need_date_parse_fix=1
# Wenn bereits die Text-Datumsvariante vorhanden ist, kein Replace
grep -q 'date -d "\$v"' "$TARGET" && need_date_parse_fix=0 || true

if [[ $need_date_parse_fix -eq 1 ]]; then
  tmp="$(mktemp)"
  cat >"$tmp" <<'EOF_FUNC'
usec_to_iso(){
  local v="${1:-}"
  [[ -z "$v" || "$v" == "0" || "$v" == "-" || "$v" == "(null)" ]] && { echo "-"; return; }
  if [[ "$v" =~ ^[0-9]+$ ]]; then
    local sec=$(( v/1000000 ))
    date -d "@${sec}" +"%Y-%m-%d %H:%M:%S%z" 2>/dev/null || echo "${sec}s"
  else
    date -d "$v" +"%Y-%m-%d %H:%M:%S%z" 2>/dev/null || echo "$v"
  fi
}
EOF_FUNC

  if grep -q '^usec_to_iso\(\)\{' "$TARGET"; then
    # Funktion ersetzen (bis zur nächsten alleinstehenden '}')
    awk -v repl="$(sed 's/[&/\]/\\&/g' "$tmp" | tr '\n' '\r')" '
      BEGIN{in=0}
      /^usec_to_iso\(\)\{/ {print ""; print "# patched: robuste µs/Datum → ISO"; print ""; print gensub(/\r/,"\n","g",repl); in=1; next}
      in==1 && /^[[:space:]]*\}[[:space:]]*$/ {in=0; next}
      in==0 {print}
    ' "$TARGET" > "$TARGET.tmp" && mv "$TARGET.tmp" "$TARGET"
  else
    # Nach esc_html() oder vor scope_exec() einfügen
    awk -v repl="$(sed 's/[&/\]/\\&/g' "$tmp" | tr '\n' '\r')" '
      {print}
      /^esc_html\(\)/ {post=1}
      post==1 && /^[[:space:]]*\}[[:space:]]*$/ {print ""; print "# patched: robuste µs/Datum → ISO"; print ""; print gensub(/\r/,"\n","g",repl); post=0}
    ' "$TARGET" > "$TARGET.tmp" && mv "$TARGET.tmp" "$TARGET"
  fi
  rm -f "$tmp"
fi

# ── Template-Units (@.timer) einmalig überspringen ────────────────────────────────
if ! grep -q 'Template ohne Instanz' "$TARGET"; then
  tmp2="$(mktemp)"
  cat >"$tmp2" <<'EOF_SNIP'
    # Skip template timer units without instance (e.g., pg_dump@.timer)
    if [[ "$t" == *@.timer ]]; then
      safe_log INFO "timer" "template/${label}" "<code>${t}</code>" "ℹ️" 0 0 \
        "Template ohne Instanz – übersprungen" \
        "systemd,timer,${label}" \
        "template unit"
      continue
    fi
EOF_SNIP
  awk -v ins="$(sed 's/[&/\]/\\&/g' "$tmp2" | tr '\n' '\r')" '
    {
      print
      if ($0 ~ /for[[:space:]]+t[[:space:]]+in[[:space:]]+"\$\{timers\[@\]\}";[[:space:]]*do/ && done==0) {
        print gensub(/\r/,"\n","g",ins)
        done=1
      }
    }
  ' "$TARGET" > "$TARGET.tmp" && mv "$TARGET.tmp" "$TARGET"
  rm -f "$tmp2"
fi

echo "✅ Gepatcht: $TARGET  → Version ${new_ver}"
echo "🧾 Backup:  ${TARGET}.bak.${ts}"
