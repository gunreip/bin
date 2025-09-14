# PostgreSQL 17 - Connection

---

!!!question Frage: Ich arbeite mit wsl/ubuntu und VSC auf win11 und greife per remote auf wsl zu. Ich versuche eine Verbindung mit der VSC-Extension "Database Client" und kann keine Connection herstellen.
    ###
    ```bash
    gunreip@DESKTOP-I7C75P2:~$ psql --version
    psql (PostgreSQL) 17.6 (Ubuntu 17.6-1.pgdg24.04+1)
    gunreip@DESKTOP-I7C75P2:~$ sudo systemctl status postgresql.service
    [sudo] password for gunreip: 
    ● postgresql.service - PostgreSQL RDBMS
         Loaded: loaded (/usr/lib/systemd/system/postgresql.service; enabled; preset: enabled)
         Active: active (exited) since Sat 2025-09-06 19:03:15 CEST; 17min ago
        Process: 356 ExecStart=/bin/true (code=exited, status=0/SUCCESS)
       Main PID: 356 (code=exited, status=0/SUCCESS)
            CPU: 2ms

    Sep 06 19:03:15 DESKTOP-I7C75P2 systemd[1]: Starting postgresql.service - PostgreSQL RDBMS...
    Sep 06 19:03:15 DESKTOP-I7C75P2 systemd[1]: Finished postgresql.service - PostgreSQL RDBMS.
    ###
    ```

!!!quote ChatGPT: Alles klar—lass uns das sauber eingrenzen. In VS Code mit „Remote – WSL“ läuft die Extension **normalerweise im WSL**. Meist scheitert die Verbindung an (a) falschem Port/Cluster, (b) TCP-Listening aus, (c) `pg_hba.conf` (peer vs. Passwort) oder (d) die Extension läuft doch auf Windows und erreicht WSL nicht.

    Hier ist ein **kompakter Diagnose-&-Fix-Pfad**. Du kannst die Befehle 1:1 in deinem WSL-Terminal ausführen.

    !!!tip 1) Cluster/Port/Listening prüfen

        ```bash
        # Welche Cluster/Ports laufen?
        pg_lsclusters

        # Lauscht Postgres auf TCP? (zeigt Ports 5432/5433 etc.)
        ss -ltnp | grep -E '5432|5433' || true   # -l listen, -t TCP, -n numeric, -p process

        # Systemd-Unit des Clusters prüfen (17-main ist üblich)
        systemctl status postgresql@17-main --no-pager

        # Aus der Datenbank selbst prüfen, wohin verbunden ist
        sudo -u postgres psql -XAtqc "\conninfo; show port; show listen_addresses; show hba_file; show data_directory; show unix_socket_directories;"
        # -X keine psql-rc, -A unaligned, -t tuples only, -q quiet, -c command
        ```

        **Erwartung**: Port z. B. `5432`, `listen_addresses` mindestens `localhost`, Sockets unter `/var/run/postgresql`.

    !!!tip 2) Teste die **TCP-Verbindung** lokal

        So merkst du sofort, ob die VSC-Extension (die meist per TCP zugreift) eine Chance hat:

        ```bash
        # Test als postgres-User via TCP auf Port 5432 (ggf. anpassen)
        psql -h 127.0.0.1 -p 5432 -U postgres -d postgres -c 'select version();'
        # -h Host erzwingt TCP (nicht Unix-Socket)
        ```

        - Wenn das klappt → trage **Host=127.0.0.1**, **Port=(aus pg\_lsclusters)** in der Extension ein.
        - Wenn du „**Peer authentication failed**“ siehst → weiter mit Schritt 3.

    !!!tip 3) Passwort-Login aktivieren (falls Peer-Auth im Weg)

        Setze ein Passwort und stelle in `pg_hba.conf` auf Passwort-Methode um.

        ```bash
        # Passwort für postgres setzen (interaktiv)
        sudo -u postgres psql -c "\password postgres"

        # hba-Datei ermitteln
        sudo -u postgres psql -XAtqc "show hba_file;"

        # Beispiel: /etc/postgresql/17/main/pg_hba.conf
        # Prüfen:
        grep -n '^[^#].*local' /etc/postgresql/*/main/pg_hba.conf
        grep -n '^[^#].*host'  /etc/postgresql/*/main/pg_hba.conf

        # Für lokale TCP-Logins (127.0.0.1/::1) 'scram-sha-256' setzen:
        sudo sed -i \
          -e 's/^\s*host\s\+all\s\+all\s\+127\.0\.0\.1\/32\s\+\w\+/host    all             all             127.0.0.1\/32            scram-sha-256/' \
          -e 's/^\s*host\s\+all\s\+all\s\+::1\/128\s\+\w\+/host    all             all             ::1\/128                 scram-sha-256/' \
          /etc/postgresql/*/main/pg_hba.conf

        # Optional: lokale Unix-Socket-Logins (Zeilen mit "local") ebenfalls auf scram umstellen:
        # sudo sed -i 's/^\s*local\s\+all\s\+all\s\+\w\+/local   all             all                                     scram-sha-256/' /etc/postgresql/*/main/pg_hba.conf

        # Neu laden:
        sudo systemctl reload postgresql
        ```

        **Flags erklärt:**

        - `sed -i` (in-place), `reload` lädt Config ohne Stop.

        Nochmal testen:

        ```bash
        psql -h 127.0.0.1 -p 5432 -U postgres -d postgres -c 'select now();'
        ```

    !!!tip 4) `listen_addresses` sicher auf `localhost`

        Falls oben `listen_addresses = ''` oder nur Socket aktiv war:

        ```bash
        # Konfig-Datei finden
        sudo -u postgres psql -XAtqc "show config_file;"

        # In postgresql.conf setzen (Zeile aktivieren/ändern):
        # listen_addresses = 'localhost'
        sudo sed -i "s/^#\?\s*listen_addresses\s*=.*/listen_addresses = 'localhost'/" /etc/postgresql/*/main/postgresql.conf

        # Neustart zur Sicherheit
        sudo systemctl restart postgresql
        ```

    !!!tip 5) Nutzer für dich (optional, sauberer als postgres direkt)

        ```bash
        # Benutzer mit Passwort und DB anlegen (Name = dein Linux-User)
        sudo -u postgres createuser --createdb --login --pwprompt gunreip
        # --createdb darf DBs anlegen, --login loginfähig, --pwprompt fragt Passwort

        createdb -h 127.0.0.1 -U gunreip gunreip
        psql     -h 127.0.0.1 -U gunreip -d gunreip -c 'select current_user, current_database();'
        ```

    !!!tip 6) VS Code „Database Client“ konfigurieren
        - **Wenn du per „Remote – WSL“ drin bist**:
            - **Host**: `127.0.0.1`
            - **Port**: (aus `pg_lsclusters`, z. B. `5432`)
            - **User/Pass**: der oben gesetzte User (oder `postgres`)
            - **DB**: `postgres` oder deine DB
            - **SSL**: meist **off** (lokal)
        - **Falls die Extension doch **auf Windows** läuft** (ohne Remote-WSL):

        - Mit aktuellem WSL2 funktioniert **localhost-Forwarding** in der Regel automatisch. Oben gesetztes `listen_addresses='localhost'` reicht.
        - Falls nicht, setze testweise `listen_addresses='0.0.0.0'` **nur lokal** und belasse `pg_hba.conf` auf `127.0.0.1/32` – dann weiter über **Windows `127.0.0.1`** verbinden.

    !!!tip 7) Typische Stolpersteine schnell checken

        ```bash
        # Falscher Port?
        pg_lsclusters

        # Falsches Socket-Verzeichnis?
        sudo -u postgres psql -XAtqc "show unix_socket_directories;"

        # Fehler live sehen
        journalctl -u postgresql -n 100 --no-pager
        ```

    Wenn du mir die **Fehlermeldung** der VSC-Extension (genauer Text) plus das **Ergebnis** von `pg_lsclusters` und dem TCP-Test (`psql -h 127.0.0.1 ...`) schickst, passe ich dir die exakten sed-Zeilen und die Connection-Maske sofort an.

---

!!!question Frage: Zu 1) bekomme ich diese Ergebnisse
    ```bash
    ###
    gunreip@DESKTOP-I7C75P2:~$ pg_lsclusters
    Ver Cluster Port Status Owner    Data directory              Log file
    17  main    5432 down   postgres /var/lib/postgresql/17/main /var/log/postgresql/postgresql-17-main.log
    gunreip@DESKTOP-I7C75P2:~$ ss -ltnp | grep -E '5432|5433' || true   # -l listen, -t TCP, -n numeric, -p process
    gunreip@DESKTOP-I7C75P2:~$ systemctl status postgresql@17-main --no-pager
    × postgresql@17-main.service - PostgreSQL Cluster 17-main
         Loaded: loaded (/usr/lib/systemd/system/postgresql@.service; enabled-runtime; preset: enabled)
         Active: failed (Result: protocol) since Sat 2025-09-06 19:03:15 CEST; 20min ago
        Process: 219 ExecStart=/usr/bin/pg_ctlcluster --skip-systemctl-redirect 17-main start (code=exited, status=1/FAILURE)
            CPU: 93ms

    Sep 06 19:03:15 DESKTOP-I7C75P2 postgresql@17-main[219]: 2025-09-06 19:03:15.701 CEST [318] LOG:  starting PostgreSQL 17.6 (Ubuntu 17.6-1.pgdg24.04+1) on x86_64-pc-linux-gnu, compiled by gcc (Ubuntu 13.3.0-6ubuntu2~24.04) 13.3.0, 64-bit
    Sep 06 19:03:15 DESKTOP-I7C75P2 postgresql@17-main[219]: 2025-09-06 19:03:15.702 CEST [318] LOG:  could not translate host name "'*'", service "5432" to address: Name or service not known
    Sep 06 19:03:15 DESKTOP-I7C75P2 postgresql@17-main[219]: 2025-09-06 19:03:15.702 CEST [318] WARNING:  could not create listen socket for "'*'"
    Sep 06 19:03:15 DESKTOP-I7C75P2 postgresql@17-main[219]: 2025-09-06 19:03:15.702 CEST [318] FATAL:  could not create any TCP/IP sockets
    Sep 06 19:03:15 DESKTOP-I7C75P2 postgresql@17-main[219]: 2025-09-06 19:03:15.703 CEST [318] LOG:  database system is shut down
    Sep 06 19:03:15 DESKTOP-I7C75P2 postgresql@17-main[219]: pg_ctl: could not start server
    Sep 06 19:03:15 DESKTOP-I7C75P2 postgresql@17-main[219]: Examine the log output.
    Sep 06 19:03:15 DESKTOP-I7C75P2 systemd[1]: postgresql@17-main.service: Can't open PID file /run/postgresql/17-main.pid (yet?) after start: No such file or directory
    Sep 06 19:03:15 DESKTOP-I7C75P2 systemd[1]: postgresql@17-main.service: Failed with result 'protocol'.
    Sep 06 19:03:15 DESKTOP-I7C75P2 systemd[1]: Failed to start postgresql@17-main.service - PostgreSQL Cluster 17-main.
    gunreip@DESKTOP-I7C75P2:~$ sudo -u postgres psql -XAtqc "\conninfo; show port; show listen_addresses; show hba_file; show data_directory; show unix_socket_directories;"
    psql: error: connection to server on socket "/var/run/postgresql/.s.PGSQL.5432" failed: No such file or directory
            Is the server running locally and accepting connections on that socket?
    ###
    ```

!!!quote ChatGPT:
    Danke, das Log sagt genau, was kaputt ist:

    - `could not translate host name "'*'": Name or service not known`
    - In deiner `postgresql.conf` steht sehr wahrscheinlich
    - `listen_addresses = "'*'"` (also **mit** eingebetteten Hochkommas).
    - Richtig wäre `listen_addresses = '*'` **oder** `'localhost'`.

    Lass uns das geradebiegen:

    !!!tip Fix: `listen_addresses` korrigieren und Cluster starten

        ```bash
        # 1) Datei finden und sichern
        cfg="/etc/postgresql/17/main/postgresql.conf"
        sudo test -f "$cfg" || { echo "Config nicht gefunden: $cfg"; exit 1; }
        sudo cp -a "$cfg" "${cfg}.bak-$(date +%F_%H%M%S)"
        # cp -a: bewahrt Rechte/Zeitstempel; Backup mit Zeitstempel

        # 2) Falsches "'*'" auf korrektes 'localhost' setzen (oder auf '*' wenn du willst)
        sudo sed -i -E "s/^\s*#?\s*listen_addresses\s*=.*/listen_addresses = 'localhost'/" "$cfg"
        # sed -i: in-place; -E: erweiterte Regex; wir überschreiben die Zeile robust

        # (Optional) Port sicher auf 5432 halten
        sudo sed -i -E "s/^\s*#?\s*port\s*=.*/port = 5432/" "$cfg"

        # 3) Cluster neu starten und Status prüfen
        sudo systemctl restart postgresql@17-main
        systemctl status postgresql@17-main --no-pager

        # 4) Lauscht Postgres jetzt?
        ss -ltnp | grep -E '5432|5433' || true
        # -l listen, -t TCP, -n numerisch, -p Prozess

        # 5) TCP-Test (erzwingt TCP via -h)
        psql -h 127.0.0.1 -p 5432 -U postgres -d postgres -c 'select version();'
        ```

        **Erwartung:**

        - `systemctl status` → **active (running)**
        - `ss …` zeigt `127.0.0.1:5432` (oder `::1:5432`)
        - `psql … select version()` liefert die Version.

    !!!tip Falls der TCP-Test an der Auth scheitert (peer/MD5/SCRAM)

        Dann einmal Passwort-Login aktivieren:

        ```bash
        # Passwort für postgres setzen (interaktiv)
        sudo -u postgres psql -c "\password postgres"

        # hba-Datei finden
        hba=$(sudo -u postgres psql -XAtqc "show hba_file;")
        echo "$hba"

        # 127.0.0.1/::1 auf scram-sha-256 stellen
        sudo sed -i \
          -e "s/^\s*host\s\+all\s\+all\s\+127\.0\.0\.1\/32\s\+\w\+/host    all     all     127.0.0.1\/32    scram-sha-256/" \
          -e "s/^\s*host\s\+all\s\+all\s\+::1\/128\s\+\w\+/host    all     all     ::1\/128           scram-sha-256/" \
          "$hba"

        # Config neu laden
        sudo systemctl reload postgresql

        # Erneut testen
        psql -h 127.0.0.1 -p 5432 -U postgres -d postgres -c 'select now();'
        ```

        **Flag-Kurzinfos:**

        - `sed -i` = direkt in Datei schreiben, `-e` = mehrere Ersetzungen
        - `systemctl reload` = Config neu laden ohne Neustart

    Wenn der Restart erneut fehlschlägt, poste bitte direkt die **letzten Zeilen** aus:

    ```bash
    journalctl -u postgresql@17-main -n 50 --no-pager
    ```

    und einmal die **aktuellen** Werte:

    ```bash
    grep -nE '^\s*#?\s*(listen_addresses|port)\s*=' /etc/postgresql/17/main/postgresql.conf
    ```

        Sobald der TCP-Test läuft, können wir die VS-Code-Connection exakt durchkonfigurieren (Host `127.0.0.1`, Port `5432`, User/Pass, DB).

---

!!!question Frage: Danke, jetzt klappt es.

!!!quote ChatGPT : Sehr gut 👍!
    Dann hast du jetzt wieder ein **laufendes Cluster auf 5432** und kannst dich auch mit der VSC-Extension verbinden.

    Kleiner Tipp für später:

    - Wenn du mal wieder ein Cluster nicht starten kannst, **immer zuerst ins Log** schauen (`journalctl -u postgresql@17-main -n 50`), dort steht fast immer die Ursache.
    - Beim Editieren der `postgresql.conf` → keine doppelten Hochkommas, besser gleich mit `sed` oder `nano` arbeiten.
    - Nach Änderungen: `systemctl reload postgresql` reicht für Config-Reload, nur bei Port/Listen-Änderungen braucht’s `restart`.

    👉 Willst du, dass ich dir eine kleine **Checkliste** (5–6 Zeilen) zusammenstelle, wie du künftig in 2 Minuten so eine „kein Start / keine Connection“-Situation systematisch prüfst?

---

!!!question Frage: Ja bitte.

!!!quote ChatGPT: Perfekt 👍 – hier eine **schnelle Checkliste für PostgreSQL-Start/Connection-Probleme** unter WSL/Ubuntu.

    **PostgreSQL Quick-Check (WSL)**
    
    !!!tip 1. **Clusterstatus prüfen**
        ```bash
        pg_lsclusters
        systemctl status postgresql@17-main --no-pager
        ```

    **→ Läuft er? Auf welchem Port?**

    !!!tip 2. **Log ansehen**

        ```bash
        journalctl -u postgresql@17-main -n 50 --no-pager
        ```

    **→ Meist steht hier der konkrete Fehler (Config, Port, Rechte).**

    !!!tip 3. **Konfiguration checken**

        ```bash
        grep -E 'listen_addresses|port' /etc/postgresql/17/main/postgresql.conf
        ```

    → `listen_addresses = 'localhost'` oder `'*'` (aber ohne doppelte Quotes), `port = 5432`.

    !!!tip 4. **Lauscht der Server wirklich?**

        ```bash
        ss -ltnp | grep 5432
        ```

        → Erwartet: `127.0.0.1:5432` oder `::1:5432`.

    !!!tip 5. **Verbindung lokal testen (TCP)**
        ```bash
        psql -h 127.0.0.1 -p 5432 -U postgres -d postgres -c 'select now();'
        ```

        → Wenn Auth-Fehler → Passwort setzen & `pg_hba.conf` auf `scram-sha-256`.

    !!!tip 6. **VS Code Extension konfigurieren**

        * Host: `127.0.0.1`
        * Port: `5432`
        * User/Pass: dein DB-User
        * DB: `postgres` oder eigene

    Damit kannst du in 2–3 Minuten jedes Mal systematisch durchgehen.

    👉 Soll ich dir diese Checkliste noch als **Shell-Skript (`pg_quickcheck.sh`)** aufbereiten, das die Punkte automatisch abprüft und die wichtigsten Ergebnisse direkt anzeigt?

!!!question Ja bitte

!!!quote Alles klar — hier ist ein **einmal einfügen & fertig** Skript. Es prüft Status, Logs, Konfiguration, Listening-Port und macht einen TCP-Test. Du kannst User/DB/Port optional über Flags setzen.

    !!!note Kopiere den Block 1:1 ins Terminal:
        ```bash
        # Datei erzeugen und ausführbar machen
        tee ~/bin/pg_quickcheck.sh >/dev/null <<'BASH'
        #!/usr/bin/env bash
        # pg_quickcheck.sh — PostgreSQL Quick-Diagnose für WSL/Ubuntu
        # Ziel: In <2 Min. Cluster/Port/Auth/Logs prüfen und klare Hinweise ausgeben.
        # Aufrufbeispiele:
        #   pg_quickcheck.sh
        #   pg_quickcheck.sh --user postgres --db postgres --port 5432
        #   pg_quickcheck.sh --unit postgresql@17-main
        set -u  # undefined vars als Fehler behandeln (robuster)

        VERSION="0.1.0"

        # --------- Defaults ----------
        USER_NAME="${USER:-postgres}"
        DB_NAME="${USER_NAME}"
        PORT_DEFAULT=""
        UNIT_DEFAULT=""
        CLUSTER_VER=""
        CLUSTER_NAME=""

        # ---------- Args -------------
        show_help() {
          cat <<EOF
        pg_quickcheck.sh v${VERSION}
        Prüft Clusterstatus, Logs, Konfig (listen_addresses/port), Listening-Sockets und TCP-Login.

        Usage:
          pg_quickcheck.sh [--user NAME] [--db NAME] [--port N] [--unit UNIT] [--verbose] [--help]

        Options:
          --user NAME     DB-User für TCP-Test (Default: \$USER oder 'postgres')
          --db NAME       DB-Name für TCP-Test (Default: wie --user)
          --port N        Port überschreiben (Default: aus pg_lsclusters)
          --unit UNIT     systemd-Unit, z. B. postgresql@17-main (Default: aus pg_lsclusters)
          --verbose       Mehr Details/Logs
          --help          Diese Hilfe
        EOF
        }

        VERBOSE=0
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --user) USER_NAME="${2:-$USER_NAME}"; shift 2;;
            --db) DB_NAME="${2:-$DB_NAME}"; shift 2;;
            --port) PORT_DEFAULT="${2:-}"; shift 2;;
            --unit) UNIT_DEFAULT="${2:-}"; shift 2;;
            --verbose) VERBOSE=1; shift;;
            --help|-h) show_help; exit 0;;
            *) echo "Unbekanntes Argument: $1"; show_help; exit 2;;
          esac
        done

        # ---------- Helpers ----------
        c_ok()    { printf "\033[1;32m%s\033[0m\n" "$*"; }
        c_warn()  { printf "\033[1;33m%s\033[0m\n" "$*"; }
        c_err()   { printf "\033[1;31m%s\033[0m\n" "$*"; }
        c_info()  { printf "\033[1;34m%s\033[0m\n" "$*"; }

        run() { # Befehl anzeigen & ausführen; bei VERBOSE immer, sonst nur Fehler
          local cmd="$*"
          if [[ $VERBOSE -eq 1 ]]; then c_info "\$ $cmd"; fi
          bash -c "$cmd"
        }

        line() { printf "%s\n" "----------------------------------------"; }

        # ---------- 1) Cluster/Port ermitteln ----------
        line
        echo "1) Cluster & Port ermitteln"
        if ! command -v pg_lsclusters >/dev/null 2>&1; then
          c_err "pg_lsclusters nicht gefunden. Ist das Paket 'postgresql-common' installiert?"
          exit 3
        fi

        # Header überspringen, erste Datenzeile nehmen
        cluster_line="$(pg_lsclusters 2>/dev/null | awk 'NR==2{print $0}')"
        if [[ -n "$cluster_line" ]]; then
          # Format: Ver Cluster Port Status Owner DataDir Logfile
          read -r CLUSTER_VER CLUSTER_NAME CLUSTER_PORT CL_STATUS _ <<<"$cluster_line"
          [[ -n "$PORT_DEFAULT" ]] && CLUSTER_PORT="$PORT_DEFAULT"
          c_ok "Gefunden: ${CLUSTER_VER}-${CLUSTER_NAME} (Port ${CLUSTER_PORT}, Status ${CL_STATUS})"
        else
          c_warn "Keine Cluster gefunden (pg_lsclusters leer)."
          [[ -z "$PORT_DEFAULT" ]] && PORT_DEFAULT="5432"
          CLUSTER_PORT="$PORT_DEFAULT"
        fi

        UNIT_NAME="$UNIT_DEFAULT"
        if [[ -z "$UNIT_NAME" ]] && [[ -n "$CLUSTER_VER" ]] && [[ -n "$CLUSTER_NAME" ]]; then
          UNIT_NAME="postgresql@${CLUSTER_VER}-${CLUSTER_NAME}"
        fi
        [[ -z "$UNIT_NAME" ]] && UNIT_NAME="postgresql"

        # ---------- 2) Unit-Status ----------
        line
        echo "2) systemd-Status (${UNIT_NAME})"
        if systemctl status "$UNIT_NAME" --no-pager >/dev/null 2>&1; then
          systemctl status "$UNIT_NAME" --no-pager | sed -n '1,12p'
        else
          c_warn "Unit ${UNIT_NAME} nicht verfügbar (WSL ohne systemd? oder anderer Unit-Name)."
        fi

        # ---------- 3) Logs zeigen (tail) ----------
        line
        echo "3) Letzte Logs"
        if command -v journalctl >/dev/null 2>&1; then
          if ! journalctl -u "$UNIT_NAME" -n 25 --no-pager 2>/dev/null | sed 's/^/  /'; then
            c_warn "journalctl liefert keine Einträge (evtl. kein systemd-Log oder anderer Unit-Name)."
          fi
        else
          c_warn "journalctl nicht verfügbar."
        fi

        # ---------- 4) Konfiguration prüfen ----------
        line
        echo "4) Konfiguration (listen_addresses / port)"
        CONFIG_PATH=""
        if [[ -n "$CLUSTER_VER" ]]; then
          # Übliche Debian/Ubuntu-Struktur:
          CONFIG_PATH="/etc/postgresql/${CLUSTER_VER}/${CLUSTER_NAME}/postgresql.conf"
          if [[ ! -f "$CONFIG_PATH" ]]; then CONFIG_PATH=""; fi
        fi
        if [[ -z "$CONFIG_PATH" ]]; then
          # Fallback: erste passende Datei
          CONFIG_PATH="$(ls /etc/postgresql/*/main/postgresql.conf 2>/dev/null | head -n1 || true)"
        fi

        if [[ -n "$CONFIG_PATH" ]]; then
          echo "Config: $CONFIG_PATH"
          grep -nE '^\s*#?\s*(listen_addresses|port)\s*=' "$CONFIG_PATH" || true
        else
          c_warn "postgresql.conf nicht gefunden."
        fi

        # ---------- 5) Listening-Sockets ----------
        line
        echo "5) Lauscht der Server auf TCP?"
        LISTEN_OUT="$(ss -ltnp 2>/dev/null | grep -E '127\.0\.0\.1:|:5432|:5433' || true)"
        if [[ -n "$LISTEN_OUT" ]]; then
          echo "$LISTEN_OUT"
          c_ok "TCP-Listener gefunden."
        else
          c_warn "Kein TCP-Listener sichtbar. Server läuft evtl. nicht oder listen_addresses/port sind falsch."
        fi

        # ---------- 6) TCP-Login testen ----------
        line
        echo "6) TCP-Login-Test"
        PORT="${CLUSTER_PORT:-5432}"
        HOST="127.0.0.1"
        PSQL_CMD=(psql -h "$HOST" -p "$PORT" -U "$USER_NAME" -d "$DB_NAME" -c "select current_user, current_database(), inet_server_addr(), inet_server_port(), now();")
        # Flags:
        # -h HOST  -> erzwingt TCP statt Unix-Socket
        # -p PORT  -> Zielport
        # -U USER  -> DB-User
        # -d DB    -> Datenbank
        # -c SQL   -> führt SQL aus und beendet sich

        if command -v psql >/dev/null 2>&1; then
          if [[ $VERBOSE -eq 1 ]]; then c_info "\$ ${PSQL_CMD[*]}"; fi
          if "${PSQL_CMD[@]}"; then
            c_ok "TCP-Verbindung erfolgreich."
            EXIT_CODE=0
          else
            c_warn "TCP-Verbindung fehlgeschlagen. Häufige Ursachen:"
            echo "  - Cluster down → 'sudo systemctl restart ${UNIT_NAME}'"
            echo "  - listen_addresses falsch → in postgresql.conf z. B. 'localhost' setzen"
            echo "  - Auth in pg_hba.conf → 127.0.0.1/32 auf 'scram-sha-256' und Passwort für User setzen"
            echo "  - Falscher Port in Extension → Verwende ${PORT}"
            EXIT_CODE=10
          fi
        else
          c_err "psql nicht gefunden."
          EXIT_CODE=4
        fi

        line
        echo "Fertig. Host=${HOST} Port=${PORT} User=${USER_NAME} DB=${DB_NAME}"
        exit "${EXIT_CODE:-0}"
        BASH

        chmod +x ~/bin/pg_quickcheck.sh
        echo "✅ ~/bin/pg_quickcheck.sh wurde erstellt und ist ausführbar."
        ```

    !!!tip So nutzt du’s schnell:

        ```bash
        pg_quickcheck.sh --verbose
        # oder spezifisch:
        pg_quickcheck.sh --user postgres --db postgres --port 5432 --verbose
        ```

        Kurz zu den wichtigsten **Flags** (wie gewünscht, mini-Erklärungen):

        - `systemctl status --no-pager` → zeigt Unit-Status ohne Paging.
        - `journalctl -u UNIT -n 25 --no-pager` → letzte 25 Logzeilen der Unit.
        - `ss -ltnp` → listet TCP-Listener (`-l` listen, `-t` TCP, `-n` numerisch, `-p` Prozess).
        - `psql -h 127.0.0.1 -p 5432 -U USER -d DB -c SQL` → erzwingt TCP und führt einen Schnell-Query aus.

    Wenn du willst, erweitere ich dir das Skript noch um:

    - automatische Korrektur von `listen_addresses`/`port` (inkl. Backup),
    - Check/Anpassung von `pg_hba.conf` auf `scram-sha-256`,
    - kompakte Markdown-Ausgabe für deine Doppel-Logging-Pipelines.

