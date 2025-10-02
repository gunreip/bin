# Dokumentation – `_bin-no-comment-txt.md` (v0.4.0)

## `_bin-no-comment-txt` — Kommentarplatzhalter in Ordnern anlegen (v0.4.0)

**Kurzbeschreibung:**
Legt in allen Verzeichnissen unter einem Root (Default: `~/code/bin`) eine `comment-bin-tree.txt` an, falls dort noch **keine** existiert.
Neue Dateien enthalten den HTML-Platzhalter `<span class="no-comment">Noch kein Kommentar!</span>`.
Bestehende `comment-bin-tree.txt` mit EXAKT `Noch kein Kommentar!` werden auf den HTML-Platzhalter **migriert**.

!!!info Hinweis: Dieses Skript schreibt **kein Audit**.

## Verwendung
```bash
_bin-no-comment-txt                     # Standard-Root = ~/code/bin
_bin-no-comment-txt --report-only       # Nur Bericht (keine Änderungen)
_bin-no-comment-txt --root=/abs/pfad    # Muss innerhalb von ~/code/bin liegen
_bin-no-comment-txt --exclude='*/.git/*' --exclude='*/node_modules/*'
```

## Verhalten

* **Nicht zerstörerisch:** vorhandene `comment-bin-tree.txt` und etwaige `comment-bin.tree.txt` (Legacy) werden **nicht überschrieben**.
* **Migration:** Nur Dateien mit **exaktem** Inhalt `Noch kein Kommentar!` werden geändert.
* **Rechte:** Fehlt Schreibrecht, wird sauber **geskippt** (keine Abbrüche).
* **Report:** `--report-only` listet, was **würde** passieren (inkl. Meta: Owner, Modus, ACL, immutable).

## Exit-Codes

* `0` Erfolg (inkl. report-only)
* `3` Root außerhalb `~/code/bin`
* `>0` andere Fehler (z. B. Tools fehlen)

## Beispiele

```bash
# Nur anzeigen, was unter ~/code/bin passieren würde
_bin-no-comment-txt --report-only

# Nur unter audits arbeiten:
_bin-no-comment-txt --root="$HOME/code/bin/shellscripts/audits"

# Komplettlauf, aber Repos-Metaverzeichnisse auslassen
_bin-no-comment-txt --exclude='*/.git/*' --exclude='*/.cache/*' --exclude='*/node_modules/*'
```

## Flowchart

```mermaid
%% Knoten (neue @-Notation)
flowchart TD
  start@{shape: circle, label: "Start:\nSkriptaufruf"}
  parseArgs@{shape: rect, label: "Args parsen\n<tt>--root</tt>,\n<tt>--report-only</tt>,\n<tt>--exclude</tt>"}
  rootCheck@{shape: diam, label: "Root innerhalb\n<tt>~/code/bin?</tt>"}

  enumerateDirs@{shape: rect, label: "Alle Verzeichnisse\nunter &lt;ROOT&gt; finden"}
  forEachDir@{shape: diam, label: "Verzeichnis\n<tt>excluded</tt>?"}
  hasFile@{shape: diam, label: "<tt>comment-bin-tree.txt</tt>\noder Legacy vorhanden?"}
  checkWritable@{shape: diam, label: "Verzeichnis\nschreibbar?"}
  createFile@{shape: rect, label: "Datei anlegen\n(<tt><span class='no-comment'>…</span></tt>)"}
  reportCreate@{shape: text, label: "Report: <tt>would_create</tt>"}
  skipNoWrite@{shape: rect, label: "<tt>Skip: no write perms (dir)</tt>"}

  scanFiles@{shape: rect, label: "Alle <tt>comment-bin-tree.txt</tt>\nfinden"}
  isExact@{shape: diam, label: "Inhalt exakt:\n'Noch kein Kommentar!'"}
  fileWritable@{shape: diam, label: "Datei schreibbar?"}
  upgradeFile@{shape: rect, label: "Upgrade → HTML-Span"}
  reportUpgrade@{shape: text, label: "<tt>Report: would_upgrade</tt>"}
  skipNoWriteFile@{shape: rect, label: "<tt>Skip: no write perms (file)</tt>"}

  endAbort@{shape: stadium, label: "Ende\n(<tt>Hinweis: schreibt kein Audit</tt>)"}
  endNode@{shape: stadium, label: "Summary + Hinweis:\n<tt>Dieses Skript schreibt kein Audit!</tt>"}

  %% Fluss
  start --> parseArgs --> rootCheck
  rootCheck -- nein --> endAbort
  rootCheck -- ja --> enumerateDirs
  enumerateDirs --> forEachDir
  forEachDir -- ja --> enumerateDirs
  forEachDir -- nein --> hasFile

  hasFile -- ja --> scanFiles
  hasFile -- nein --> checkWritable
  checkWritable -- nein --> skipNoWrite --> enumerateDirs
  checkWritable -- ja --> createFile --> enumerateDirs
  hasFile -. report-only .-> reportCreate -.-> enumerateDirs

  scanFiles --> isExact
  isExact -- nein --> enumerateDirs
  isExact -- ja --> fileWritable
  fileWritable -- nein --> skipNoWriteFile --> enumerateDirs
  fileWritable -- ja --> upgradeFile --> enumerateDirs
  isExact -. report-only .-> reportUpgrade -.-> enumerateDirs

  enumerateDirs --> endNode
```

---
