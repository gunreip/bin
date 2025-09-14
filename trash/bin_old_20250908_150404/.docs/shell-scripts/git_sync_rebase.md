# `git_sync_rebase.sh` - Doku (0.5.0)

```markdown
# `git_sync_rebase.sh` — Fetch + Rebase auf Remote
```

## Kurzüberblick

Holt Änderungen vom Remote und **rebased** den lokalen Branch auf `<remote>/<branch>`. Optional wird ein schmutziger Arbeitsbaum automatisch **gestashed** und anschließend wiederhergestellt.

- **Version:** 0.5.0
- **Gatekeeper:** `.env` im Projekt-Root erforderlich.
- **Logs:** via `log_core.part` + Debug unter `~/bin/debug/`.

## Aufruf

```bash
git_sync_rebase.sh [OPTS]
```

## Optionen (Defaults in Klammern)

* `--remote <name>` — Remote-Name (**origin**)
* `--branch <name>` — Branch (aktueller Branch)
* `--stash` — Vor Rebase automatisch stashen & danach poppen (aus)
* `--dry-run` — Nur anzeigen (aus)
* `--do-log-render=ON|OFF` — HTML-Render (**ON**)
* `--render-delay=<sec>` — Verzögerung (**1**)
* `--debug=OFF|ON|TRACE` — (**OFF**)
* `--version` / `-h, --help`

## Verhalten

1. Branch bestimmen; Abbruch bei detached HEAD.
2. Optional `git stash push -u` (bei `--stash` und schmutzigem Baum).
3. `git fetch <remote> --prune`.
4. `git rebase <remote>/<branch>` (Konflikthinweis bei Fehler).
5. Optional `git stash pop`.
6. Logt Start/Fetch/Rebase/Stash/Summary + Optionen-Zelle.

## Beispiele

```bash
git_sync_rebase.sh
git_sync_rebase.sh --stash
git_sync_rebase.sh --dry-run --debug=TRACE
```

## Exit-Codes

* `0` — Erfolgreich
* `2` — Gatekeeper: `.env` fehlt
* `3` — `git` nicht gefunden
* `4` — Branch konnte nicht ermittelt werden
* `5` — Arbeitsbaum schmutzig ohne `--stash`
* `6` — Stash fehlgeschlagen
* `7` — Remote-Branch nicht vorhanden
* `>0` — Rebase-/Stash-Pop-Fehler (Details im LOG)

---

*Last updated: 2025-09-04 19:05 UTC*

```
