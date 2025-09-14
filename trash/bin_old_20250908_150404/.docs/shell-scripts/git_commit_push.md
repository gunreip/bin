# `git_commit_push.sh` - Doku (0.4.0)


```bash
# `git_commit_push.sh` — Commit & Push mit Logging
```

## Kurzüberblick

**Commitet** (staged) Änderungen und pusht auf den gewählten **Remote**/**Branch**. Integriert das einheitliche Logging und kann am Ende automatisch die HTML-Logansicht aktualisieren.

- **Version:** 0.4.0
- **Gatekeeper:** Skript muss im **Projekt-Root** (mit vorhandener `.env`) laufen.
- **Logs:** Markdown/JSON via `log_core.part` + Debug unter `~/bin/debug/`.
- **Auto-Render:** `log_render_html(.sh)` wird standardmäßig nachlaufend ausgeführt.

## Aufruf

```bash
git_commit_push.sh [OPTS]
```

## Optionen (Defaults in Klammern)

* `--all` — Alle Änderungen stagen (`git add -A`) (aus)
* `--add "<paths>"` — Bestimmte Pfade stagen (leer)
* `-m "<message>"` — Commit-Message (Pflicht, außer bei `--amend`)
* `--amend` — Letzten Commit ändern (aus)
* `--no-verify` — Git-Hooks beim Commit/Push überspringen (aus)
* `--remote <name>` — Remote-Name (**origin**)
* `--branch <name>` — Ziel-Branch (aktueller Branch)
* `--dry-run` — Nur anzeigen, keine Ausführung (aus)
* `--do-log-render=ON|OFF` — HTML-Log nachlaufend rendern (**ON**)
* `--render-delay=<sec>` — Verzögerung vor Render-Aufruf (**1**)
* `--debug=OFF|ON|TRACE` — Debug-Level (**OFF**)
* `--version` / `-h, --help`

## Verhalten

1. Gatekeeper prüft `.env` im Projekt-Root.
2. Optionales Staging gemäß `--all`/`--add`.
3. Commit: normal mit `-m` **oder** `--amend` (mit/ohne `-m`).
4. Push mit `git push -u <remote> <branch>`.
5. Einheitliche **LOG-Zeilen** (Beginn/Commit/Push/Summary) + **Optionen-Zelle**.
6. Optionales **HTML-Rendern** der Logdateien am Ende.

## Beispiele

```bash
git_commit_push.sh -m "fix: correct CSS class"
git_commit_push.sh --amend --no-verify
git_commit_push.sh --add "README.md docs/*.md" -m "docs: refresh" --dry-run
git_commit_push.sh --remote upstream --branch main -m "feat: add feature"
```

## Logging

* Debug: `~/bin/debug/git_commit_push.debug.log`, `.jsonl`, `.xtrace.log` (bei `TRACE`).
* Markdown/JSON-Log: via `lc_log_event_all` (Spalten gemäß Projektvorgabe).
* **Optionen-Zelle:** alle CLI-Optionen als non-breaking `code` (mehrzeilig).

## Exit-Codes

* `0` — Erfolgreich
* `2` — Gatekeeper: `.env` fehlt
* `3` — `git` nicht gefunden
* `4` — Commit-Fehler (z. B. fehlende Message ohne `--amend`)
* `5` — Push-Fehler (Remote fehlt o. ä.)

---

*Last updated: 2025-09-04 15:00 UTC*

````
