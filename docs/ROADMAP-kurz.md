<!-- code/bin/docs/ROADMAP-kurz.md -->

Alles klar. Kein Patch-Gefrickel – wenn wir Code anfassen, liefere ich künftig **immer** einen kompletten Einspieler (mit Backup, chmod, Symlink). Für jetzt nur die **ultraknappe Implementierungs-Notiz** für `_audits-main` (ohne Code), inkl. *Why/What/Impact/Risk*.

# Kurz-Roadmap (Default-CSS/JS einbinden)

**Why**

* Einheitliches Fallback, weniger doppelte Configs, klare Terminal-Meldungen.
  **What**
* Wenn für `<script-id>` **keine** CSS/JS-Assets in der jeweiligen Config-Sektion gefunden werden, nutze `vars.css_default` bzw. `vars.js_default`.
  **Impact**
* Stabilere Audits, weniger Sonderfälle.
  **Risks**
* Falsche Defaults → „verlinkt, aber fehlt“. Mit Existenz-Check + Warnung abfangen.

---

# Implementierungs-Notiz (4 Schritte)

1. **Config laden & Variablen expandieren**

* Lade `~/code/bin/templates/css/.css.conf.json` und `~/code/bin/templates/js/.js.conf.json`.
* `vars` → per `envsubst` expandieren (inkl. `css_root_*`, `css_default`, analog `js_*`).
* Gatekeeper sicherstellen: Kontext `~/code/bin` (bei `_…`-Skripten zwingend).

2. **Asset-Liste je Typ (CSS/JS) aufbauen**

* Suche in `audits["<script-id>"].files` für `_audits-main`.
* **Wenn leer/nicht vorhanden** → setze **genau ein** Asset aus `vars.css_default` (Label `DEFAULT`). Analog für JS mit `vars.js_default`.
* **Wenn vorhanden** → benutze **nur** diese Liste (Defaults **nicht** zusätzlich anhängen).

3. **Auflösen & prüfen (pro Asset)**

* Pipeline je Asset:
  `raw` (aus Config) → **expand (envsubst)** → **abs** (abspath) → **href** (relativ zum Ziel-HTML-Verzeichnis) → **exists** (Datei vorhanden?).
* **Policy:**

  * `exists=true` → normal verlinken.
  * `exists=false` → *nicht* verlinken, aber **Warnung loggen** (Terminal + JSONL).

4. **Terminal-Echos & Logging**

* **Terminal (Minimal-Echo):**

  * Bei Default-Treffer:

    * `CSS:        DEFAULT verlinkt!  <href>`
    * `JS:         DEFAULT verlinkt!  <href>`
* **Terminal (Verbose, z. B. mit `--with-assets`):**

  * `CSS:        DEFAULT  HREF=<href>  ABS=<abs>  Exists=OK|ERR`
  * `JS:         DEFAULT  HREF=<href>  ABS=<abs>  Exists=OK|ERR`
* **JSONL-Debug (pro Asset):**

  * Felder: `type=css|js`, `label=DEFAULT|SECTION`, `raw`, `abs`, `href`, `exists=true|false`, `script_id`, `ts`.
  * Pfad gemäß deiner Struktur: `~/code/bin/shellscripts/debugs/<script-id>/assets/*.jsonl` (Rotation deiner Debug-Policy folgend).

---

# Kleines Verhaltens-Schema (Priorität & Fehlerszenarien)

* **Priorität:** `SECTION-Assets` > `DEFAULT`.
* **Kein Default gesetzt:** Wenn `css_default`/`js_default` fehlt/leer → **kein** Fallback, nur Hinweis „kein Default konfiguriert“.
* **Default existiert nicht:** **Warnung** ausgeben, **nicht** verlinken, weiterlaufen (kein harter Abbruch).
* **HREF-Bezugspunkt:** Immer relativ zum finalen **HTML-Zielpfad** (Ordner der Ausgabedatei).

---

# Optional (für zentrale Optionen – nur Vorschlag, keine Umsetzung)

* `--with-assets` (verbose Echos aktivieren)
* `--link-mode=relative|absolute` (Standard: relative)
* `--unicode=yes|no` (Standard: yes)

> Aufnahme in `.script-options.conf.json` **nur** falls wir das *skriptübergreifend* vereinheitlichen wollen – ansonsten lokal lassen.

---

Wenn du „go“ gibst, baue ich dir als nächsten Schritt den **kompletten Einspieler** für `_audits-main` mit genau dieser Logik (Backup, Version-Bump, Symlink-Check, Dry-Run möglich).
