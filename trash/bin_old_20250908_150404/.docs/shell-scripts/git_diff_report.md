# `git_diff_report.sh` - Doku (v0.6.0)

```bash
# `git_diff_report.sh` — Diff-Report als Markdown
```

## Kurzüberblick

Erzeugt einen Diff-Report (Git) und legt ihn unter `.wiki/git_diffs/` ab. Alte Reports werden auf `--max` begrenzt. Mit Logging + optionalem HTML-Render.

- **Version:** 0.6.0
- **Gatekeeper:** `.env` im Projekt-Root erforderlich.
- **Logs:** Markdown/JSON via `log_core.part` + Debug unter `~/bin/debug/`.
- **Auto-Render:** Standard **ON**.

## Aufruf

```bash
git_diff_report.sh [OPTS]
```

## Optionen (Defaults in Klammern)

* `--against <ref>` — Vergleichsbasis (Upstream, sonst `origin/<branch>`, sonst `HEAD~1`)
* `--staged` — Nur staged Änderungen (aus)
* `--format <summary|name-only|full>` — Ausgabeformat (**summary**)
* `--max <N>` — Anzahl Reports behalten (**5**)
* `--dry-run` — Nur anzeigen, nicht schreiben (aus)
* `--do-log-render=ON|OFF` — HTML-Render nachlaufend (**ON**)
* `--render-delay=<sec>` — Verzögerung vor Render (**1**)
* `--debug=OFF|ON|TRACE` — (**OFF**)
* `--version` / `--help`

## Verhalten

* Schreibt (oder simuliert bei `--dry-run`) `diff_YYYYMMDD_HHMMSS.md` in `.wiki/git_diffs/`.
* **Pruning**: behält **MAX** neueste Dateien, löscht ältere.
* Logt Start, Write, Prune, Summary inkl. **Optionen-Zelle**.

## Beispiele

```bash
git_diff_report.sh
git_diff_report.sh --staged --format name-only
git_diff_report.sh --against v1.2.3
git_diff_report.sh --dry-run --do-log-render=OFF
```

## Exit-Codes

* `0` — Erfolgreich
* `2` — Gatekeeper: `.env` fehlt
* `3` — `git` nicht gefunden
* `4` — Fehler beim Schreiben/Generieren

---

*Last updated: 2025-09-04 15:50 UTC*

---