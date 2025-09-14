# 1. `git_repo_setup.sh` - Doku (v0.4.0)

```bash
# `git_repo_setup.sh` — Repo initialisieren/vereinheitlichen
```

## 1.1. Kurzüberblick

Initialisiert ein Git-Repository (oder richtet es um) mit Ziel-Branch, optionalem Re-Init, Remote-URL und Push. Logging + HTML-Render inklusive.

- **Version:** 0.4.0
- **Gatekeeper:** `.env` im Projekt-Root (oder via `--path`).
- **Logs:** via `log_core.part` + Debug unter `~/bin/debug/`.

## 1.2. Aufruf

```bash
git_repo_setup.sh [OPTS]
```

## 1.3. Optionen (Defaults in Klammern)

* `-p, --path <dir>` — Projektpfad (aktuelles Verzeichnis)
* `--branch <name>` — Ziel-Branch (**main**)
* `-r, --remote <url>` — Remote-URL setzen (leer = unverändert)
* `--remote-name <name>` — Remote-Name (**origin**)
* `--reinit` — `.git` neu anlegen (löscht `.git`) (aus)
* `--no-push` — Kein Push nach dem Setup (aus)
* `--dry-run` — Nur anzeigen (aus)
* `--do-log-render=ON|OFF` — HTML-Render (**ON**)
* `--render-delay=<sec>` — Verzögerung (**1**)
* `--debug=OFF|ON|TRACE` — (**OFF**)
* `--version` / `-h, --help`

## 1.4. Ablauf

1. Optional **Reinit**: `.git` löschen.
2. `git init -b <branch>` bzw. `git checkout -B <branch>`.
3. `git add -A` → initialer Commit (falls Änderungen).
4. Optional Remote **add/set-url**.
5. Optional **Push** (`-u <remote-name> <branch>`).
6. Einheitliche LOG-Einträge (Init/Checkout/Commit/Remote/Push/Summary).

## 1.5. Beispiele

```bash
git_repo_setup.sh --reinit --branch main --remote https://example.com/repo.git
git_repo_setup.sh --branch main --no-push
```

## 1.6. Exit-Codes

* `0` — Erfolgreich
* `2` — Gatekeeper: `.env` fehlt
* `3` — `git` nicht gefunden
* `1` — Einzelschritt fehlgeschlagen (siehe LOG)

---

*Last updated: 2025-09-04 18:50 UTC*

---
