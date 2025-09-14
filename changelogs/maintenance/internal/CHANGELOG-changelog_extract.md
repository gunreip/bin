# CHANGELOG changelog_extract

_Erstellt: 2025-09-14 08:11 CEST_

## History

- **v0.2.17** *(2025-09-14)* — ✅
  - Hilfe stark erweitert: Beschreibung, Optionen, Beispiele, Exit-Codes, Pfade/Hinweise.
  - CHANGELOG-Abschnitt im Tool selbst konkretisiert.
  - Fehlercodes für Extract/Render differenziert (71/72) und Propagation bis exit.
  - Kleinere Robustheitsverbesserungen (CRLF-Säuberung bleibt erhalten).

- **v0.2.16** *(2025-09-13)* — ✅
  - FIX: Render-Hänger beseitigt (Renderer liest aus Datei; kein STDIN-Feeding).
  - Vereinfachter Renderer: keine Sortierung; Icons & Tail 1:1 aus dem Skriptkopf.

- **v0.2.15** *(2025-09-13)* — ✅
  - Datei-basiertes Rendering eingeführt; stabilere Step-Logs.

- **v0.2.14** *(2025-09-13)* — ✅
  - CLI bereinigt: --mark=…, --mark-version=…, --mark-auto-from-exit=…, --internal-postmark deprecatet (werden ignoriert).
  - Renderer: Status/Icons ausschließlich aus Skriptkopf (❌/✅/⚠️/❓). Usage aktualisiert; Auto-Postmark entfernt.
