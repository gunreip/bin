# `git_status_short.sh` - Doku (v0.5.0)

```bash
# `git_status_short.sh` — kompakter Status + optionaler Datei-Output
```

## Kurzüberblick

Zeigt einen knappen Status (branch/commit/upstream/ahead-behind etc.). Optional in `.wiki/git_status/` schreiben und alte Dateien auf `--max` begrenzen. Mit Logging + Auto-Render.

- **Version:** 0.5.0
- **Gatekeeper:** `.env` im Projekt-Root erforderlich.
- **Logs:** via `log_core.part` + Debug unter `~/bin/debug/`.

## Aufruf

```bash
git_status_short.sh [OPTS]
```

## Optionen (Defaults in Klammern)

* `--out` — Datei-Output aktivieren (aus)
* `--format <txt|md>` — Ausgabeformat (**txt**)
* `--max <N>` — Anzahl Dateien behalten (**10**)
* `--dry-run` — Nur anzeigen, nicht schreiben (aus)
* `--do-log-render=ON|OFF` — HTML-Render (**ON**)
* `--render-delay=<sec>` — Verzögerung (**1**)
* `--debug=OFF|ON|TRACE` — (**OFF**)
* `--version` / `-h, --help`

## Inhalte

* Branch, Commit, Upstream
* Ahead/Behind (relativ zu Upstream, falls vorhanden)
* Anzahl Stashes, Last Tag, Remote-URL
* Staged/Unstaged/Untracked/Conflicts (summarisch)

## Beispiele

```bash
git_status_short.sh
git_status_short.sh --out --format md --max 5
```

## Exit-Codes

* `0` — immer (Statusanzeige soll nicht „rot“ werden)

---

*Last updated: 2025-09-04 19:00 UTC*

---
