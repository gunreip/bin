# CHANGELOG git_sync_bin

_Erstellt: 2025-09-15 03:56 CEST_

## History

- **v0.1.4** *(2025-09-15)* — ✅
  - Preflight: 'git ls-remote' mit Timeout → frühe Netz/Auth-Diagnose
  - No-Prompt: GIT_TERMINAL_PROMPT=0, SSH BatchMode=yes (+ConnectTimeout)
  - Timeout für alle Git-Calls (default 8s), --timeout=N
  - Klare Fehlerausgaben (inkl. Timeout=124), Git-Kommandos bei --steps>=2

- **v0.1.3** *(2025-09-15)* — ✅
  - Robust: ahead/behind parsing, verlässlicher stash-pop

- **v0.1.2** *(2025-09-14)* — ✅
  - [[ .. ]], Quoting, gepufferte Reads

- **v0.1.1** *(2025-09-14)* — ✅
  - Icons/if-else, SC2155 entflechtet

- **v0.1.0** *(2025-09-14)* — ✅
  - Erstversion
