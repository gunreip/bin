# CHANGELOG bin_audit

_Erstellt: 2025-09-14 11:02 CEST_

## History

- **v0.9.33** *(2025-09-12)* — ✅
  - Changelog-Persist fix (alte Versionseinträge bleiben vollständig erhalten).
  - „Folders total“ bereits in den Metriken.

- **v0.9.32** *(2025-09-12)* — ✅
  - FIX: Vollständiger, nicht komprimierter Changelog wiederhergestellt.
  - NEU: „Folders total“ (Gesamtzahl Ordner) in Metriken (mit Excludes).

- **v0.9.31** *(2025-09-12)* — ❓
  - Vereinfachung auf Kern-Optionen; Zählungen via `Python`/`os.walk`.
  - `latest.*` aus `/tmp`, Backups mit Timestamp, Rotation=5.

- **v0.9.30** *(2025-09-12)* — ❓
  - (Zwischenschritt) Export-/Print-Utility; später wieder entfernt.

- **v0.9.29** *(2025-09-12)* — ❓
  - Komplett ohne `find`: Counts via `Python`/`os.walk`; Top-Level-Ordner (Summary).

- **v0.9.28** *(2025-09-12)* — ❓
  - Dynamische find-Optionen; Hänger-Fix in `\[1/4]`.

- **v0.9.27** *(2025-09-12)* — ❓
  - Timeouts; Renderer über `tree -J` + `Python`; Icon hinter Name; rekursive Counts.

- **v0.9.26** *(2025-09-12)* — ❓
  - MD-Rendering komplett auf `tree -J` + `Python` umgestellt; korrekte Counts.

- **v0.9.25** *(2025-09-12)* — ❓
  - Entfernt: `tree -A` (`ANSI`); Parser auf `ASCII`→`Unicode`; Icon-Position gefixt.

- **v0.9.24** *(2025-09-12)* — ❓
  - Parser stabilisiert; keine leeren `<tt></tt>`; Counts repariert.

- **v0.9.23** *(2025-09-11)* — ❓
  - `UTF-8`-Handling (`C.UTF-8`), `--dir-icon`, rekursive Counts Default.

- **v0.9.22** *(2025-09-11)* — ❓
  - `--files-scope=[direct|recursive]`; Linien im `<tt>`.

- **v0.9.21** *(2025-09-11)* — ❓
  - `latest.*` immer aus frischen Buffern (keine Abweichungen).

- **v0.9.20** *(2025-09-11)* — ❓
  - `CRLF`/Indent-Filter; Inline-Code + *(files: N)*.

- **v0.9.19** *(2025-09-11)* — ❓
  - Kein globaler ```-Block; Inline-Code + Kursiv-Zähler.

- **v0.9.18** *(2025-09-11)* — ❓
  - `JSON` via `tree -J --noreport` (Fallback: `tree_lines`).

- **v0.9.17** *(2025-09-11)* — ❓
  - MD: Basenames, Ordner-Icon, *(files: N)*; `JSON`-Baum.

- **v0.9.16** *(2025-09-11)* — ❓
  - Icons nur bei Verzeichnissen; (files: N) je Ordner (direkt).

- **v0.9.15** *(2025-09-11)* — ❓
  - Icon-Stabilität; `JSON`-Dirs-Top; `ASCII`-Backticks.

- **v0.9.14** *(2025-09-11)* — ❓
  - Ordner-Icon integriert.

- **v0.9.13** *(2025-09-11)* — ❓
  - Unicode-Baumlinien per Postprocessing.

- **v0.9.12** *(2025-09-11)* — ❓
  - Steps-Logger; Changelog mit Datum.

- **v0.9.11** *(2025-09-11)* — ❓
  - Tree-only Rendering; Trace-Rotation; `latest.*` als Dateien.

- **v0.9.10** *(2025-09-11)* — ❓
  - safe Counts; Fix `unbound var`; weitere Rotation.

- **v0.9.09** *(2025-09-11)* — ❓
  - Array-Längen-Fix; Header ergänzt.

- **v0.9.08** *(2025-09-11)* — ❓
  - `safe_count()`; `pipefail`-sicher.

- **v0.9.07** *(2025-09-11)* — ❓
  - `--steps=0|1|2`; Core-Fallback; Installer/Backup.
