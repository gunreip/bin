# `git_repo_clean_old_remote.sh` - Doku (v0.4.0)

```markdown
# `git_repo_clean_old_remote.sh` — Remote prüfen/aufräumen
```

## Kurzüberblick

Zeigt Remote-Info an und führt optional `--remove`, `--rename` oder `--url` aus — in genau dieser Reihenfolge. Mit Logging und optionalem HTML-Render.

- **Version:** 0.4.0
- **Gatekeeper:** `.env` im Projekt-Root (oder via `-p` wechseln).
- **Logs:** via `log_core.part` + Debug unter `~/bin/debug/`.

## Aufruf

```bash
git_repo_clean_old_remote.sh [OPTS]
```

## Optionen (Defaults in Klammern)

* `-p <path>` — Projektpfad (aktuelles Verzeichnis)
* `--remote <name>` — Remote-Name (**origin**)
* `--remove` — Remote entfernen (aus)
* `--rename <new_name>` — Remote umbenennen (leer)
* `--url <new_url>` — Remote-URL setzen (leer)
* `--dry-run` — Nur anzeigen (aus)
* `--do-log-render=ON|OFF` — HTML-Render (**ON**)
* `--render-delay=<sec>` — Verzögerung vor Render (**1**)
* `--debug=OFF|ON|TRACE` — (**OFF**)
* `--version` / `-h, --help`

## Verhalten

* Prüft Existenz des Remotes, zeigt aktuelle URL.
* Führt Aktionen **remove → rename → set-url** aus (sofern angefordert).
* Logt Inspect/Action/Summary mit **Optionen-Zelle**.

## Beispiele

```bash
git_repo_clean_old_remote.sh
git_repo_clean_old_remote.sh --rename upstream
git_repo_clean_old_remote.sh --url https://example.com/repo.git
git_repo_clean_old_remote.sh --remove --dry-run
```

## Exit-Codes

* `0` — Erfolgreich
* `2` — Remote oder Gatekeeper-Fehler
* `3` — `git` nicht gefunden
* `1` — Einzelne Aktion fehlgeschlagen (Details im LOG)

---

*Last updated: 2025-09-04 16:05 UTC*

---
