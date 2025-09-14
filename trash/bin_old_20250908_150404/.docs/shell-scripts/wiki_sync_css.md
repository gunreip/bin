# `wiki_sync_css` – Doku (v0.10.10)

## Kurzüberblick

`wiki_sync_css.sh` verteilt CSS-Dateien aus `~/bin/css` an Ziele, die in den Dateien selbst per `@dest:`-Zeilen angegeben sind. Es loggt sauber in dein Markdown+JSON-Log (über `log_core.part`), schützt Projekte via Gatekeeper (`.env` im Projekt-Root) und zeigt alle übergebenen Optionen non-breaking an.

## Features

* **Quelle → Ziele per Annotation:** Liest `@dest:`-Zeilen aus jeder `*.css` im Quellordner.
* **Pfadauflösung:**
  `~/…` → `$HOME/…` · `/…` → absolut · sonst relativ zu `<project-root>` (Gatekeeper).
* **Policy:** Default **no-create** (legt fehlende Ziele nicht an). Mit `--allow-create` werden sie erstellt.
* **Logging (falls `log_core.part` vorhanden):**
  – „Optionen“-Spalte: alle CLI-Args eine Zeile, mit non-breaking hyphen
  – Per-File-Zeile: „Notiz“ zeigt **alle Targets** als `Target 1: \`…\``<br />…
  – Summary: keine `Source=…\`-Vorläufe, nur Plan-Zahlen.
* **Debug/XTrace:** Schreibt frische Debugfiles pro Lauf in `~/bin/debug/`.

## Voraussetzungen

* Bash 4+, Standard-Coreutils (`cp`, `cmp`, `mkdir`, `find`, `awk`, `sed`)
* (Optional) `~/bin/parts/log_core.part` mit **lc\_init\_ctx**, **lc\_log\_event\_all**, **lc\_finalize**, **lc\_set\_opt\_cell**
* Projekt-Root mit `.env` (Gatekeeper)

## @dest-Annotationen (in der CSS-Datei)

Erlaubte Formen (eine pro Zeile):

```css
@dest: .wiki/logs/.shell_script_styles.logs.css
/* @dest: ~/bin/.wiki/logs/.shell_script_styles.logs.css */
/* @dest: .wiki/logs/.markdownpdf-markdown.css */  /* Kommentar erlaubt */
# @dest: /abs/pfad/zum/stylesheet.css
```

## Aufruf & Optionen

```bash
wiki_sync_css.sh [--dry-run] [--debug=OFF|ON|TRACE] [--src-dir=PATH]
                 [--allow-create] [--render-html]
                 [--help] [--version]
```

### Defaults

* `--dry-run` = aus
* `--debug` = `OFF`  (→ `ON` schreibt Text/JSON; `TRACE` zusätzlich `xtrace`)
* `--src-dir` = `~/bin/css`
* `--allow-create` = aus
* `--render-html` = aus  (führt bei Erfolg `log_render_html.sh` aus)

### Beispiele

```bash
# Trockentest + Trace
wiki_sync_css.sh --dry-run --debug=TRACE

# Erstellt fehlende Ziele
wiki_sync_css.sh --allow-create

# Andere Quelle + HTML danach rendern
wiki_sync_css.sh --src-dir=~/bin/css --allow-create --render-html
```

## Terminalausgabe (Beispiele)

```bash
→ CREATE(DIR) /home/USER/code/proj/.wiki/logs
→ CREATE      /home/USER/code/proj/.wiki/logs/.shell_script_styles.logs.css
→ UPDATE      /home/USER/bin/.wiki/logs/.shell_script_styles.logs.css
→ SKIP        /home/USER/... (identisch)
→ SKIP(CREATE) /home/USER/... (Policy: default no-create; use --allow-create)
❌ copy failed: /src.css → /dest.css
OK: created 1, updated 2, identisch 3, nodest 0, errors 0
```

## Logging (über `log_core.part`)

* **Version-Spalte:** wird über `export SCRIPT_VERSION` korrekt befüllt.
* **Optionen-Spalte:** jede Option als `code` mit non-breaking hyphen; eine Zeile pro Option.
* **Per-File-Zeile:**
  * **Grund:** Basename der Quelle (in Backticks).
  * **Notiz:** Aufgelöste Zielpfade als
    Target 1: `/abs/pfad1/...`
    Target 2: `/abs/pfad2/...`
  * **Skript-Meldungen:** `created=x; updated=y; identical=z`.
* **Summary-Zeile:** `plan_create=…; plan_update=…; identical=…; pruned=0; nodest=…; errors=…`

## Gatekeeper

Wird das Skript **nicht** aus einem Projekt-Root mit `.env` gestartet → sauberer Fehler (`Exit 2`) + Logeintrag (wenn `log_core.part` vorhanden).

## Exit-Codes

* `0` Erfolg (auch wenn alles identisch war)
* `2` Gatekeeper-Fehler (keine `.env`)
* `64` Falsche/Unbekannte Option
* `>0` interne Kopierfehler werden gezählt, Skript endet dennoch i. d. R. mit `0` – Status siehst du in Summary/Logs.

## Debugdateien (pro Lauf frisch)

```bash
~/bin/debug/wiki_sync_css.debug.log
~/bin/debug/wiki_sync_css.debug.jsonl
~/bin/debug/wiki_sync_css.xtrace.log   # nur bei --debug=TRACE
```

## Tipps

* Willst du **nur** geplante Änderungen sehen: `--dry-run`.
* Neue Ziele zulassen: `--allow-create`.
* Direkt HTML bauen lassen: `--render-html` (ruft dein `log_render_html.sh` auf).

---

*Last updated: 2025-09-04 15:45 UTC*

---
