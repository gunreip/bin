Nächste Git-Skripte (Vorschläge)

Kurz & pragmatisch, im selben Stil wie die bisherigen:

git-audit-read – JSONL-Audits filtern/anzeigen (Zeitraum, Aktion, Repo, User), optional --json.

git-state – kompakter Status (Branch, ahead/behind, untracked/changed), wahlweise --summary-only.

git-feature – Feature-Branch anlegen, von main abzweigen, Convention-Name, optional Ticket-ID, --push.

git-release – Release-Tagging (semver bump, CHANGELOG aus Commits, Tag + Push).

git-clear – Working-Tree aufräumen (untracked/temp), Sicherheitsabfragen, --aggressive-Stufe.

git-publish – Erstveröffentlichung: origin setzen, initial commit, push, .gitignore-Template.

git-clone-bootstrap – Klonen + Standard-Setup (Hooks, user.name/email, LFS optional, submodules).

git-protect – lokale Schutzliste pflegen (branches, die delete/force verbieten), --add/--list/--rm.

Wenn du magst, starten wir als Nächstes mit git-audit-read (macht deine neuen Audits sofort „brauchbar“), oder lieber mit git-feature.
