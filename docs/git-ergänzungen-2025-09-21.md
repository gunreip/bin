Nice — der Kern steht. Ich würde das Git-Set jetzt so ergänzen (kurz & praxisnah), priorisiert von „als Nächstes“ → „nice to have“. Keinen Code, nur Vorschläge.

# Als Nächstes (MVP)

* **git-feature**
  Neue Feature-/Bugfix-Branches anlegen (Konvention: `feat/<slug>`, `fix/<slug>`), Abzweig von `main`, optional `--ticket=ID`, Schutz gegen „schon vorhanden“, optionaler First-Commit-Stub.
* **git-branch-prune-local**
  Lokale, gemergte Branches nach Regeln löschen (`--only-merged-to=main`, `--min-age-days=N`, Schutzlisten, Dry-Run, Audit).
* **git-tag**
  Tags listen/erstellen/löschen mit SemVer-Helfern (`--bump=patch|minor|major`, `--annotated`, `--message=…`), Schutz vor Duplikaten, optional Push, Audit.
* **git-release**
  Release-Workflow: Changelog aus Commits (Conventional Commits), Version bump, Tag pushen, optional GitHub-Release-Draft (nur lokal vorbereiten), Audit-Log.

# Remote/Repo-Management

* **git-remote-set**
  Origin/Upstream komfortabel anzeigen/setzen/wechseln (inkl. Validierung), Dry-Run.
* **git-clone**
  Standardisierter Clone in `~/code/<repo>` (SSH/HTTPS), optional `--sparse`, `--depth`, Gatekeeper auf Zielpfad.
* **git-worktree**
  `add/switch/list/prune` für Worktrees (saubere Trennung langer Features), mit Schutzregeln.

# Verlauf & Sicherheit

* **git-merge-safe**
  Vor Merge Checkliste (clean working tree, Tests optional, up-to-date), Merge-Strategie `--ff-only|--no-ff`, Auto-Abort bei Konflikten, Audit.
* **git-rebase-onto-main**
  „Feature rebasen“ mit Vor-/Nach-Checks, Autostash, Abbruch & Restore, Audit.
* **git-squash**
  Letzte *n* Commits squashen (`--count=N`) mit Preview (`git log --oneline -N`), Abbruch sicher.
* **git-reset-safe**
  `--soft|--mixed|--hard` mit vorher/nachher Snapshot (Bundle & Tag), starke Warnbanner, Audit.

# Aufräumen & Zustand

* **git-clean**
  Untracked/ignored aufräumen mit Stufen (`--preview`, `--only-ignored`, Schutzmuster), Audit.
* **git-fetch-all**
  Alle Remotes fetch+prune, kurzreport (neue Branches/Tags), ideal für CI/periodisch.
* **git-log-pretty**
  Kuratierte Log-Ansichten: „seit letztem Tag“, „seit main“, „nur feat/\*“, JSON/Markdown-Ausgabe (für Release-Notes).

# QA & Hooks

* **git-hooks-install**
  Standard-Hooks einrichten (pre-commit: `shellcheck`, `shfmt` optional; commit-msg: Conventional-Commit-Check; pre-push: „clean working tree“), `--install|--uninstall|--status`.
* **git-verify**
  Vor Push: Linter, Tests optional (`--run-tests`), `git-state` sauber, Branch-Policy (kein Push direkt auf `main`), Exit-Codes strikt.

# Wiederherstellung & Audit

* **git-branch-restore** (bereits da, jetzt „Finish“)
  Ergänzen: Restore aus Tag/Bundle fallback, Konflikt-Handling, Erfolgsmeldung mit Checkout-Shortcut.
* **git-audit-read** (habt ihr)
  Mini-Erweiterung: `--grep=…`, `--since=…`, `--tool=…`, `--to-md` (Export als Markdown-Report).

# Qualität/Architektur (gemeinsame Basis)

* **lib/gitsh.sh** (Mini-Shared-Lib)
  Zentralisieren, was sich wiederholt: Repo-Slug, Protected-Branches, ahead/behind, Merge-Check, Age-Days, Remote-URL-Parsing.
  Ziel: weniger Duplikate in `git-ctx/state/pull/push/sync/branch-*`.
* **Konventionen (bestätigt)**
  Einheitliche Flags: `--no-color`, `--debug=dbg|trace|xtrace`, `--dry-run`, `--yes`, `--summary-only`, `--json`.
  Gatekeeper: `/bin` vs. `<project>` konsistent.
  Audits/Backups: `audits/<tool>/<repo>/…`, `backups/branches/<repo>/…`, Runs mit `latest.json` (habt ihr).

---

## Roadmap-Vorschlag (kurz)

1. **git-feature**, **git-branch-prune-local**, **git-tag** → direkt Nutzen im Alltag.
2. **git-release**, **git-merge-safe**, **git-rebase-onto-main** → stabiler Flow.
3. **git-hooks-install**, **git-verify**, **git-clean** → Qualität & Hygiene.
4. **git-worktree**, **git-log-pretty**, **git-fetch-all** → Komfort & Übersicht.

Sag mir, mit welchem wir starten — ich setze es im vorhandenen Stil (Gatekeeper, logfx, Dry-Run, Audit) sofort um.
