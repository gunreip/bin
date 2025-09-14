# log\_render\_html – Doku (v0.6.6)

## Kurzüberblick

`log_render_html.sh` rendert die tagesaktuelle Markdown-Logdatei `LOG-YYYYMMDD.md` zu HTML – sowohl **im Projekt** als auch in **\~/bin** – und bindet CSS nach einer **Auto-Policy** ein (deine Styles bevorzugt, sonst Pandoc-Default). Es räumt Pandoc-Artefakte auf (z. B. `<colgroup>`) und wrappt Tabellen für horizontales Scrollen.

## Features

* **Zwei Wurzeln:** Projekt-Root (per `.env` ermittelt) **und** `~/bin`.
* **Auto-CSS-Policy:**
  – Wenn `.markdownpdf-*.css` oder `.shell_script_styles.logs.css` in `/.wiki/logs` existieren → **diese** Styles verwenden (standard: **inline** eingebettet).
  – Sonst → **Pandoc-Default-CSS**.
* **HTML-Aufräumen:**
  Entfernt `<colgroup>…</colgroup>`, `style="width:%"` aus Tabellen/Spalten und wrappt **jede Tabelle** in `<div class="overflowx">…</div>`.
* **Kein Syntax-Highlight** (standard) → kein extra CSS nötig.
* **Logging (über `log_core.part`):** Start-Event + je Root ein „render html“-Event, inkl. CSS-Kette (Modus + Dateinamen).

## Voraussetzungen

* `pandoc` installiert
* (Optional) `~/bin/parts/log_core.part` mit **lc\_init\_ctx**, **lc\_log\_event\_all**, **lc\_finalize**, **lc\_set\_opt\_cell**
* Projekt-Root mit `.env` (für die Projekt-Seite)

## Aufruf & Optionen

```bash
log_render_html.sh [--all] [--root=PATH] [--date=YYYY-MM-DD]
                   [--css=auto|inline|link|none]
                   [--no-default-css|--with-default-css]
                   [--keep-table-widths] [--no-strip-md-style]
                   [--keep-colgroup] [--no-wrap-tables]
                   [--highlight|--no-highlight]
                   [--debug=OFF|ON|TRACE] [--version] [--help]
```

**Defaults (Autopolicy)**

* CSS: **auto** (eigene CSS vorhanden → **inline**; sonst Pandoc-Default)
* Default-CSS: **auto** (nur wenn keine eigenen CSS existieren)
* Strip Markdown `<style>…</style>`: **an**
* Strip Tabellenbreiten (`style="width:%"`): **an**
* Entferne `<colgroup>`: **an**
* Wrap Tabellen: **an** (`<div class="overflowx">…</div>`)
* Highlighting: **aus**

**Beispiele**

```bash
# Standardlauf (Projekt + ~/bin)
log_render_html.sh

# Nur für einen Root
log_render_html.sh --root=~/code/mein_projekt

# CSS-Kette verlinken statt inline einbetten
log_render_html.sh --css=link

# Pandoc-Default-CSS erzwingen (auch wenn eigene vorhanden sind)
log_render_html.sh --with-default-css

# Debug/Trace
log_render_html.sh --debug=TRACE
```

## Ein-/Ausgabeorte

* **Markdown-Quelle:** `<root>/.wiki/logs/YYYY/LOG-YYYYMMDD.md`
* **HTML-Ziel:** `<root>/.wiki/logs/YYYY/LOG-YYYYMMDD.html`
* **CSS-Suchpfad:** `<root>/.wiki/logs/`
  – `.markdownpdf-*.css` (alphabetisch sortiert)
  – `.shell_script_styles.logs.css` (am Ende)

## CSS-Einbindung (Autopolicy)

* **Eigene CSS vorhanden** → verwendet **nur** diese (Default: **inline** via `--embed-resources`; alternativ `--css=link`).
* **Keine eigenen CSS** → **Pandoc-Default-CSS**.
* In den Logs („Skript-Meldungen“) siehst du:

  ```
  CSS:&nbsp;1&nbsp;(inline)&nbsp;`.shell_script_styles.logs.css`
  <br />CSS:&nbsp;2&nbsp;(inline)&nbsp;`.markdownpdf-markdown.css`
  ```

  oder `CSS: Pandoc-Default`.

## HTML-Nachbearbeitung

* Entfernt komplette `<colgroup>…</colgroup>`-Blöcke (Standard).
* Entfernt `style="…width:%…"` aus `<table>`/`<col>` (Standard).
* Wrappt **jede** `<table>` in `<div class="overflowx">…</div>` (Standard).

## Logging (über `log_core.part`)

* **Version-Spalte:** via export (`SCRIPT_VERSION`) korrekt gesetzt.
* **Optionen-Spalte:** alle CLI-Args (non-breaking) jeweils in eigener Zeile.
* **Events:**

  * **Begin:** `render/start` mit Policy/Flags (`strip-md-style`, `wrap-tables`, …).
  * **Je Root:** `render/html` mit Root-Pfad & CSS-Kette.
  * **Finalize:** am Ende.

## Debugdateien

```
~/bin/debug/log_render_html.debug.log
~/bin/debug/log_render_html.xtrace.log   # nur bei --debug=TRACE
```

## Exit-Codes

* `0` Erfolg (für beide Roots)
* `64` Falsche/Unbekannte Option
* `127` Fehlende Abhängigkeit (`pandoc`)
* `1` Pandoc-Fehler beim Rendern eines Roots (der andere kann trotzdem erfolgreich sein)

## Tipps

* Wenn du in den Markdown-Logs bereits `<style>…</style>` eingebettet hast, übernimmt `--no-strip-md-style` deren Inhalt (kann unerwünschte Defaults reaktivieren).
* Für maximale Portabilität in HTML: **inline** (Default) lassen – dann ist alles in **einer** Datei.

---

```mermaid
flowchart TD
  %% log_render_html.sh v0.6.6 — Gesamtfluss inkl. Render-Schritte

  start["Start"]
  parse["Argumente parsen: --all | --root | --date | --css | --debug | ..."]
  debug["Debug-Init (TRACE ⇒ xtrace nach ~/bin/debug)"]
  lc["log_core.part laden (optional)"]
  datevars["Datum ableiten: y, md_day, md_name, html_name"]

  main["main()"]
  roots{"Roots bestimmen: DO_ALL?"}
  mkdirs["mk_log_dirs_for_root (project_root & ~/bin)"]
  ctx["lc_init_ctx + lc_set_opt_cell (falls vorhanden)"]
  beginlog["BEGIN-Event: safe_log_all(INFO, render/start)"]
  loop{"Weitere Roots?"}
  finalize["safe_finalize()"]
  done["Ende"]

  %% Render-Schritte (inline statt Subgraph)
  r_paths["Pfadaufbau: log_dir=.wiki/logs/<year>, md=LOG-YYYYMMDD.md, out=LOG-YYYYMMDD.html"]
  r_nomd{"Markdown vorhanden?"}
  r_warn["⚠️ missing Markdown → return 0"]

  r_srcprep["Quelle wählen: strip_md_style_file (AUTO_STRIP_MD_STYLE) oder md"]
  r_csslist["CSS ermitteln: .markdownpdf-*.css, .shell_script_styles.logs.css"]
  r_mode{"CSS_MODE: auto | inline | link | none"}
  r_defcss{"NO_DEFAULT_CSS: auto | 0 | 1"}

  r_pandocargs["PANDOC-Argumente: --standalone, --from gfm, --to html5, ..."]
  r_template["make_min_template() (wenn Default-CSS aus)"]
  r_inline["--embed-resources (bei inline)"]
  r_cssargs["CSS_ARGS: -c <css> … (bei inline/link & vorhandener CSS)"]

  r_runpandoc["pandoc ausführen → tmp_html"]
  r_ok{"pandoc erfolgreich?"}

  r_postproc["postprocess_cleanup_html(tmp_html) → out (atomisch via tmp_out + mv)"]
  r_cleanup["Cleanup: rm -f tmp_html, tmp_src, tmpl"]
  r_echo_ok["✅ HTML gerendert: out"]
  r_log_ok["safe_log_all(INFO, render/html)"]

  r_echo_fail["❌ pandoc failed"]
  r_log_fail["safe_log_all(ERROR, render/html)"]

  %% Hauptfluss
  start --> parse --> debug --> lc --> datevars --> main --> roots --> mkdirs --> ctx --> beginlog --> loop
  %% Abzweig: wenn noch Roots → Render-Sequenz
  loop -- "ja" --> r_paths --> r_nomd
  r_nomd -- "nein" --> r_warn --> loop
  r_nomd -- "ja" --> r_srcprep --> r_csslist --> r_mode --> r_defcss --> r_pandocargs
  r_defcss -- "Default-CSS aus" --> r_template --> r_pandocargs
  r_mode -- "inline" --> r_inline --> r_pandocargs
  r_csslist --> r_cssargs --> r_pandocargs
  r_pandocargs --> r_runpandoc --> r_ok
  r_ok -- "ja" --> r_postproc --> r_cleanup --> r_echo_ok --> r_log_ok --> loop
  r_ok -- "nein" --> r_cleanup --> r_echo_fail --> r_log_fail --> loop
  %% Abzweig: keine Roots mehr → Finalize
  loop -- "nein" --> finalize --> done
```