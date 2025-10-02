<!-- code/bin/docs/CHECKLISTE-skript-erstellung.md -->

Top, danke für die Aktualisierungen. Ich habe beide Dateien geprüft—**Syntax ist valide**, Struktur konsistent, und die neuen Default-Variablen sind sauber gesetzt:

* **`.css.conf.json`**: `vars.css_default` zeigt auf `${css_root_bootstrap}/bootstrap.min.css`. 
* **`.js.conf.json`**: `vars.js_default` zeigt auf `${js_root_bootstrap}/bootstrap.min.js`. 

Hinweis: Du hattest „default-css“ erwähnt; in den Dateien heißt es **`css_default`** bzw. **`js_default`** (mit Unterstrich). Das passt zu deiner Namenskonvention für interne Variablen, also 👍—nur in den Skripten bitte genau diese Keys erwarten. Für die Pfad-Auflösung gilt weiter das Schema **envsubst → abspath → relative HREF** (Bezug: Ziel-HTML), wie in deiner Trouble-Doku festgelegt.

---

# Checkliste: zentrale Script-Optionen (wenn in `.script-options.conf.json`?)

**Grundsatz:** Nur zentrale Verwaltung, wenn mehrere Skripte dieselbe Option **konsistent** brauchen oder wenn die Option **globale Pfade/Rotation/Output-Modi** steuert. Triviales (`--help`, `--version`) bleibt lokal.

* **Laufzeit/Debug & Nachvollziehbarkeit**

  * `--debug` (Werte: `all|trace|syntax|OFF`) – einheitliche Debug-Stufen.
  * `--echo-*` (z. B. `--echo-clear`) – Echo-/JSONL-Logverhalten. 
* **Link-/Render-Modus (nur falls mehrere Skripte das nutzen)**

  * `--with-assets` (Terminal-Echo der Assets), `--link-mode=relative|absolute`. 
* **Rotation/Backups (global konsistent)**

  * `--rotation-max-age`, `--rotation-max-count`, evtl. `--rotation-min-keep` → spiegelt deine Policy (max ~2h **oder** max=10, min=2; Trash-Verschiebung).
* **Internationalisierung/Encoding**

  * `--unicode=yes|no` (Standard: Unicode, Fallback ASCII).
* **Pfade/Assets (falls nötig)**

  * Schalter, um alternative **Configpfade** (`CFG_CSS`, `CFG_JS`) zu setzen, wenn Skripte das erlauben sollen.
* **Sicherheitsnetze**

  * `--yes/--no-prompt` nur zentral, wenn „destruktive“ Pfade (Löschen/Prune) skriptübergreifend identisch abgesichert werden sollen.

**Nicht zentral** (Default: lokal bleiben): `--help`, `--version`, rein skript-lokale Schalter ohne Cross-Script-Bezug.

---

# Checkliste: Default-CSS/JS im Skript verlinken (ohne Code, nur Logik)

* **Konfiguration**

  * Lies `vars.css_default` / `vars.js_default`. Falls leer/nicht gesetzt → **kein** Default-Link.
* **Auflösung & Prüfung**

  * Für jedes Asset: `envsubst(raw)` → `abspath()` → `href_for(abs)` (relativ zur Ziel-HTML).
    Wenn **keine** paarspezifischen Einträge für `<script-id>` vorhanden sind, prüfe `css_default`/`js_default` und ob die Zieldatei existiert.
* **Priorität**

  * Reihenfolge: **Sektionsspezifische Einträge > Defaults**. Defaults greifen nur, wenn die Sektion 0 Assets liefert.
* **Terminal-Echos (Vorschlag)**

  * Bei Default-Treffer:

    * `CSS:        DEFAULT verlinkt!  <href>  (ABS=<abs>, Exists=[OK|ERR])`
    * `JS:         DEFAULT verlinkt!  <href>  (ABS=<abs>, Exists=[OK|ERR])`
  * Zählt weiter sauber in `CSS-RAW/CSS-Assets` bzw. `JS-RAW/JS-Assets` mit. 
* **Logging**

  * Echo-JSONL pro Asset: `label=DEFAULT|<key>`, `raw`, `abs`, `href`, `exists=true|false`. Python-Logger statt `jq`. 
* **HREF-Bezugspunkt**

  * **Immer** relativ zum Ordner der Ziel-HTML (z. B. `…/shellscripts/audits/audits-main.html`). 

---

# Mini-Syntax-Review deiner Dateien

* **Struktur**

  * Beide Dateien haben `version`, `vars`, `audits` – sauber. `css_root_*` / `js_root_*` zeigen in `templates/…`, `css_default`/`js_default` referenzieren `bootstrap.min.css/.js`.
* **Keys & Benennung**

  * Unterstriche statt Bindestriche → gut für ENV-Exports.
  * `audits`-Sektionen sind konsistent benannt (`"_audits-main"`, `_lx-env*`, `shellscripts`) – passt.
* **Kompatibilität zur Pipeline**

  * Passt zur festgelegten Reihenfolge `envsubst → abspath → rel_to_main()`; keine Widersprüche.

Wenn du möchtest, entwerfe ich dir als Nächstes eine **ultraknappe Implementierungs-Notiz** (3–4 Schritte) für `_audits-main`, wie die Default-Verknüpfung ins bestehende Echo-/HREF-Handling integriert wird—rein beschreibend, ohne Code.
