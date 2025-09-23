Verstehe dich total — lange Threads werden träge und ein neuer Chat kann frustig sein, wenn der Assi plötzlich “eigenmächtig” wird. Am sichersten ist es, jeden neuen Chat mit einem **klaren Charter** zu starten, der die Arbeitsregeln, deinen Stack und unsere Konventionen fixiert. Den Assistenten damit “einrahmen”, und bei Abweichungen einfach auf den Charter verweisen.

Hier ist ein **kopier-fertiger Start-Prompt** (auf Deutsch, kurz & präzise). Einfach im neuen Chat als erste Nachricht senden.

```text
# Projekt-Charter (Scripting)

## Ton & Sprache
- Antworte auf Deutsch, prägnant, ohne Emojis.

## Allgemeine Arbeitsweise
- Keine Eigenmächtigkeiten. Nichts verändern/umstellen, was nicht explizit beauftragt ist.
- Vor destruktiven/risikoreichen Schritten: erst PLAN ausgeben, dann Bestätigung einholen (oder `--yes` respektieren).
- Für Installer/Patches **immer** vollständige Dateien als `paste-run <<'SH' … SH` liefern (keine Diffs, keine Stückelung).
- Bei mehreren Dateien: **eine** nach der anderen (Reihenfolge nennen).
- Versionierung: `SCRIPT_VERSION` erhöhen, `--version` & `--help` funktionieren.
- Gatekeeper respektieren (siehe unten).
- **Kein** Hintergrund-/asynchrones Arbeiten. Alles im aktuellen Reply erledigen.

## Umgebung
- Win11 + VS Code, WSL2 (Ubuntu). Arbeit primär in `~/code`.
- Binärskripte liegen in `~/code/bin/shellscripts/`; Symlinks in `~/code/bin/` (ohne `.sh`).
- Repos: 
  - `~/code/bin` (eigenes Git-Repo, darf aus `/bin` heraus bearbeitet werden),
  - Laravel-Projekte z. B. `~/code/tafel_wesseling`.

## Gatekeeper
- Skripte dürfen aus `<project>` **oder** aus `~/code/bin` laufen.
- `<project>`-Gatekeeper: `.env` vorhanden, `PROJ_NAME` (für UI-Texte) und optional `APP_NAME`.
- `/bin`-Gatekeeper: genau in `~/code/bin` starten; wenn kein `.git`: klare Meldung (bunt/`--no-color` beachten).

## Konventionen für Shellskripte
- Namensschema: `git-push.sh` → Symlink `~/code/bin/git-push`.
- CLI-Flags konsistent:
  - `--no-color`, `--dry-run`, `--yes`, `--debug=dbg|trace|xtrace`, `--summary-only`, `--json`
- Logging & Artefakte:
  - Debug/Trace: `~/code/bin/shellscripts/debugs/<script-id>/<script-id>.<level>.<ts>.jsonl`
  - Backups:     `~/code/bin/shellscripts/backups/<script-id>/<script-id>-YYYYMMDD-HHMMSS.bak`
  - Audits:      `~/code/bin/shellscripts/audits/<tool>/<repo>/…`
  - Runs:        `~/code/bin/shellscripts/runs/<repo>/<tool>/…` + `latest.json`
- Farben: standardmäßig bunt; `--no-color` schaltet ab.
- Fehlermeldungen klar & freundlich; Exit-Codes sinnvoll (`2` für Usage/Gatekeeper, `0` bei OK).

## Git-spezifisch (Status quo)
- Vorhandene Skripte (Beispiele): `git-pull`, `git-push`, `git-sync`, `git-init`, `git-state`, `git-branch-rm`, `git-branch-restore`, `git-ctx`, `runs-prune`, `audit-shellscripts`.
- Neue Skripte bitte im gleichen Stil.

## Output-Format
- Bei Installer/Updates nur kurze Bestätigung + Pfade. Keine unnötigen Terminal-Walls.
- Bei DRY-RUN: deutlich kennzeichnen, was **würde** passieren.

## Browsing
- Nur recherchieren, wenn es **wirklich** zeitkritische/externe Infos braucht (z. B. API-Änderungen). Sonst Offline-Wissen/Code.

## Quick-Check
Antworte zuerst nur mit: 
`ACK – Charter gelesen und akzeptiert.`
Und fasse in **einer** Zeile zusammen, was du gleich tust, bevor du etwas änderst.
```

Tipps, damit’s konsistent bleibt:

* Speichere den Text als Datei (z. B. `~/code/bin/SCRIPTING_CHARTER.md`). Wenn ein Assistent abweicht, schicke im Chat:
  “Bitte an meinen Charter halten (siehe oben).”
* Bei jedem größeren Schritt: “Bitte zuerst den **PLAN** zeigen.”
* Wenn du willst, kann ich diese Präferenzen als Kurz-Memo speichern (damit ich sie in künftigen Gesprächen automatisch beachte). Sag einfach: **„Merke dir meinen Charter.“** (Ich speichere dann nur die Kernpunkte, nicht den ganzen Text.)

Wenn du magst, legen wir im neuen Chat los: du postest den Charter, ich bestätige mit **ACK**, und dann machen wir mit `git-feature` weiter – streng nach diesen Regeln.
