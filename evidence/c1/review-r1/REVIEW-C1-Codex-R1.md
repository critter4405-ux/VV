# C-1 Review Runde 1 — Bericht Codex GPT-6 Sol (wörtlich, vom Betreiber übergeben am 25.09.2026)

> Prüfstand `5e139c3`. Einstufung: [EINSTUFUNG-Codex-R1.md](EINSTUFUNG-Codex-R1.md).


**Prüfstand:** Commit `5e139c3c820ddc770f6ec85244e3408cfbc36fbd` aus frischem Klon `~/VV-c1` im Linux-Dateisystem (WSL Ubuntu), PostgreSQL 16 im Docker-Container. **Datum:** 25.09.2026. Nur synthetische Daten. Keine Reparaturen, Commits oder Pushes.

## Gesamturteil: **nicht bestanden**

Die Kerntrennung gegen frei gesetzte GUCs, direkte Tabellenzugriffe und Worker-Imitation hat meine Gegenproben bestanden. Die **60-Sekunden-Grenze des geprüften Kontexts ist aber umgehbar**: Ein Angreifer mit `vv_app` und einem während einer echten Anfrage beobachteten Ticket kann in einem einzigen PostgreSQL-Protokollaufruf nach Ticketablauf weiter lesen und verbindliche Aktionen ausführen. Eine reguläre 60-s-Probe las nach 61 s noch 3.033 synthetische Personen. Zusätzlich fehlt bei einer fachlichen Vorschlagsentscheidung die Einmal-Prüfung. Der öffentliche `vv-ci`-Lauf dieses Commits ist außerdem fehlgeschlagen; die Ursache ist ohne zugängliche Job-Logs nicht bestimmbar.

## Befunde

### CRITICAL

Keine weiteren bestätigten Befunde dieser Stufe.

### HOCH — H-01: Ticketkontext bleibt innerhalb eines SQL-Protokollaufrufs nach Ablauf wirksam

- **Fundort:** `db/migrations/0013_kontext_signatur.sql:105`, `:114`, `:123`, `:262`. `vv_current_tenant()`, `vv_actor()`, `vv_ctx_kind()` und `vv_ticket_once()` vergleichen `exp_at` mit `statement_timestamp()`. Dieser Zeitwert bleibt für alle Befehle einer einzelnen PostgreSQL-Simple-Query-Nachricht konstant. `vv_set_context()` prüft an `:137`/`:191` beim Eintritt dagegen mit `clock_timestamp()`.
- **Reproduktion:** Im WSL-Klon ein Prüfticket erzeugen (nur der Prüfer verwendet den Wegwerf-Keyring):

  ```bash
  cd ~/VV-c1
  T=$(VV_TICKET_KEYRING=review-c1-out/ticket_keyring.json python3 scripts/vv_ticket.py mint --tenant 00000000-0000-0000-0000-0000000000aa --actor sub-schrift-aa --ttl 60)
  PGPASSWORD=change_me_dev_only psql -X -At -v ON_ERROR_STOP=1 -h 127.0.0.1 -p 55434 -U vv_app -d vv -c "BEGIN; SELECT vv_set_context('$T'); SELECT pg_sleep(61); SELECT count(*) FROM basis01_list_persons(); ROLLBACK"
  ```

  Dieselbe Technik mit `--ttl 2`, `pg_sleep(3)` und anschließend `m05_import_request('C1EXP…', repeat('a',64), 1)` führte eine verbindliche Aktion nach Ablauf aus und `COMMIT` gelang. Bei **getrennten** `psql -c`-Aufrufen in derselben Transaktion wurde `vv_current_tenant()` nach Ablauf korrekt `NULL`.
- **Erwartet:** Nach `exp` kein Mandanten-/Akteurskontext und keine Datenlesung oder Aktion mehr, unabhängig von Nachrichtengrenzen oder Transaktionsdauer.
- **Tatsächlich:** Die 60-s-Probe lieferte nach 61 s **3.033** Zeilen; die 2-s-Probe lieferte nach 3 s ebenfalls 3.033 Zeilen. Der Import-Antrag nach 3 s gab eine neue Approval-UUID zurück und wurde committet. Der Angreifer benötigt dafür den Ticket-Schlüssel **nicht**, nur ein innerhalb der Frist abgefangenes echtes Ticket und beliebiges SQL als `vv_app`.
- **Empfehlung:** Die Ablauffrist bei jeder Kontextnutzung und vor jeder verbindlichen Aktion gegen die reale Uhr prüfen; die Volatilität der Kontextfunktionen und die RLS-InitPlan-Strategie gemeinsam prüfen. Eine Gegenprobe muss mehrere SQL-Befehle in **einer** Protokollnachricht über die volle 60-s-Frist führen.

### MITTEL — M-01: Aging-up-Entscheidungen verbrauchen kein Einmal-Ticket

- **Fundort:** `db/migrations/0008_m05_functions.sql:595-616` (`m05_decide_proposal` entscheidet und ändert bei Bestätigung die Mitgliedsart), `db/migrations/0013_kontext_signatur.sql:502-586` (acht Einmal-Wrapper, aber keiner für `m05_decide_proposal`), `:669` (EXECUTE für `vv_app`).
- **Reproduktion:** Zwei synthetische offene `membership_proposal`-Zeilen für Mandant A/aktive Perioden anlegen. Als `vv_app` mit **einem** Ticket für `sub-admin-aa` in einer Transaktion ausführen:

  ```sql
  BEGIN;
  SELECT vv_set_context('<ein Ticket für Mandant A / sub-admin-aa>');
  SELECT m05_decide_proposal('<Vorschlag 1>', 'abgelehnt');
  SELECT m05_decide_proposal('<Vorschlag 2>', 'abgelehnt');
  ROLLBACK;
  ```

  Beide Aufrufe lieferten live `{"ok": true}`. Die Probe wurde zurückgerollt; die beiden Testvorschläge wurden entfernt.
- **Erwartet:** Wenn die fachlich endgültige Bestätigung/Ablehnung eines Aging-up-Vorschlags unter „verbindliche Aktionen“ des Bau-Auftrags fällt, muss der zweite Aufruf mit derselben `jti` verweigert werden. Die Liste des Auftrags nennt Freigabe/Ablehnung und fordert die Prüfung auf fehlende verbindliche Wege.
- **Tatsächlich:** `m05_decide_proposal` ruft `vv_ticket_once` nicht auf und ist als `vv_app` direkt ausführbar. Ein Ticket kann beliebig viele Vorschläge entscheiden, solange der Kontext gilt.
- **Empfehlung:** Fachlich festlegen, ob Aging-up-Entscheidungen der Einmal-Regel unterliegen. Falls ja, wie die übrigen verbindlichen Funktionen vor den Kern einen Einmal-Wrapper setzen und eine Live-Gegenprobe ergänzen. Falls nein, die Ausnahme im Bau-Auftrag/Dossier ausdrücklich begründen.

### NIEDRIG — N-01: Doppelte JSON-Schlüssel in signierten Tickets werden akzeptiert

- **Fundort:** `db/migrations/0013_kontext_signatur.sql:167-180`. Die Umwandlung nach `jsonb` entfernt doppelte Schlüssel, bevor `jsonb_object_keys` die „exakte“ Schlüsselmenge prüft.
- **Reproduktion:** Mit dem **Prüfer-Keyring** eine Nutzlast mit `"t":"…bb","t":"…aa"` und den sonst regulären Feldern `s,iat,exp,jti` signieren; `vv_app` ruft `vv_set_context(<Ticket>)` auf. Die Live-Probe wurde mit Mandant A angenommen.
- **Erwartet:** Eine nicht eindeutige Nutzlast als Formatfehler verweigern, wenn „genau diese Schlüssel“ auch eindeutiges Vorkommen meint.
- **Tatsächlich:** Der letzte `t`-Wert gewinnt. **Kein nachgewiesener Angriff im vorgegebenen Modell:** Der Ticket-Dienst erzeugt keine solchen Nutzlasten und `vv_app` kann sie ohne Schlüssel nicht signieren.
- **Empfehlung:** Doppelte Schlüssel vor der `jsonb`-Normalisierung abweisen oder das akzeptierte JSON-Format ausdrücklich als Last-wins definieren. Positiv-/Negativtest ergänzen.

### NIEDRIG — N-02: Die S0-2-Regressionsprobe erreicht den Actor-Guard nicht mehr

- **Fundort:** `scripts/ci_db_asserts.sh:111-121`, `scripts/m05_db_asserts.py:315-327`, Guard in `db/migrations/0013_kontext_signatur.sql:362-367`.
- **Reproduktion:** Die neue S0-2-Probe sendet `INSERT approval` direkt als `vv_app` und bekommt vor Ausführung des Triggers `permission denied`; die ergänzende Normalisierungsprobe läuft als `vv_bootstrap` mit `SET ROLE vv_definer`. Der Guard prüft `requested_by = vv_actor()` aber nur bei `session_user = 'vv_app'` oder `current_user = 'vv_app'`. In beiden neuen Proben wird diese Bedingung im Trigger nicht als `vv_app` durchlaufen.
- **Erwartet:** Die umgestellte Gegenprobe weist auch die Bindung von `requested_by` an den geprüften Actor auf dem echten App→Definer-Pfad nach.
- **Tatsächlich:** Das Wegfallen des direkten INSERT-Rechts wird korrekt geprüft und ist stärker gegen den direkten Angriff. Die spezielle Trigger-Behauptung „Antragsteller-Spoofing im Definer-Pfad verweigert“ ist damit nicht mehr separat belegt. Der aktuelle Guard enthält die Abweisung; dies ist eine **Testabdeckungslücke**, kein live ausnutzbarer Spoofing-Befund.
- **Empfehlung:** Einen Test über eine als `vv_app` gestartete Definer-Funktion ergänzen, der absichtlich einen vom Ticket-Akteur abweichenden `requested_by` versucht.

### NIEDRIG — N-03: Der C-1-Validator erkennt dynamische Kontext-GUCs nicht

- **Fundort:** `validators/checks/c1_context.py:20-22`, `:60-68`. Die Erkennung verlangt ein Literal `'app.` unmittelbar nach `set_config(` oder `current_setting(`.
- **Reproduktion (statisch, keine Codeänderung am Prüfstand):** `const name = 'app.' + 'tenant_id'; client.query('SELECT set_config($1,$2,true)', [name, tenant]);` trifft weder `GUC` noch `GUC_SET`. Analog ist Schlüsselmaterial unter anderem Variablennamen/anderer Crypto-API nicht durch `KEYMAT` abgedeckt.
- **Erwartet:** Ein Sicherheits-Validator sollte diese gleichwertige Rückkehr zu frei setzbarem Kontext als Regression erkennen oder seine Reichweite begrenzen.
- **Tatsächlich:** Der aktuelle App-Code nutzt den geprüften Ticketweg; die Lücke betrifft die künftige Warnfunktion des statischen Checks. Die live geprüfte DB liest derzeit keine `app.*`-GUC.
- **Empfehlung:** Den Validator als heuristisch dokumentieren und die DB-seitigen Live-Invarianten sowie gezielte mutierte Selbsttests als maßgebliches Gate beibehalten/erweitern.

## Pflicht-Harness

`VV_KEEP_DB=1 bash scripts/review_c1.sh` im frischen WSL-Klon: **PASS=30, FAIL=0**.

| Schritt | Eigenes Laufergebnis |
|---|---|
| 0 Stand | PASS: sauberer Prüfstand `5e139c3` |
| 1 PostgreSQL 16, Migrationen 0001–0013, Seeds | PASS |
| 2 Schlüssel, LIVE-Validatoren, Selbsttest, Stage-0-/M05-/C-1-Gegenproben | PASS |
| 3 Typechecks, Tests und npm audit (Web/Worker/Ticket), Token→Ticket→Web→DB und Fail-closed | PASS |
| 4 Idempotenz 0006–0013, direkte `vv_app`-Rechte, P54-Repro | PASS |

Die zusätzlichen eigenen Proben zeigten: gefälschte `app.*`-GUCs wirkungslos; direkter Tabellenzugriff, `SET ROLE vv_worker`, TEMP-Schattenobjekt, Funktion ohne Ticket, zweites Ticket in derselben Transaktion, App-Aufruf eines `__kern` und `vv_decide_approval` verweigert. `search_path=pg_temp,public` änderte den Ticketkontext nicht. Falsche Signatur, unbekannte `kid`, Base64-Padding, `iat` als String, Systemakteur und unbekannter Mandant wurden verweigert. Einmal-Antrag konnte nach Commit mit derselben `jti` nicht erneut gesetzt werden. Worker erhielt keine Nutzerfunktion und kein Nutzer-Ticket. Die eigenen Ausnahmefälle sind H-01, M-01 und N-01.

## Prüfpunkte 1–12

| # | Bestätigung | Ergebnis |
|---|---|---|
| 1 Kontext nicht fälschbar | **live + statisch**: GUC, Rolle, TEMP, Suchpfad, zwei Tickets, Ticket-Replay; PID/XID-Bindung statisch. | Identitäts-/Mandantenwechsel verweigert; **Ablauf in einem Protokollaufruf offen (H-01)**. Savepoint- und Pool-Fälle zusätzlich im Harness, nicht als eigener Pool-Stresstest. |
| 2 Ticket-Prüfung | **live + statisch**: Signatur, `kid`, Format, Padding, Typen, Systemakteur, unbekannter Mandant; Quellcode zu HMAC/Vergleich. | Grundschutz wirksam; doppelte JSON-Schlüssel akzeptiert (N-01). Zeitseitenkanal nicht experimentell vermessen; Double-HMAC statisch nachvollzogen. |
| 3 Einmal-Tickets | **live + statisch**: Replay, `__kern`/`vv_decide_approval` direkt, zwei Vorschläge; Harness prüft Parallelität/Rollback. | Acht Wrapper und `jti`-Sperre wirksam; Aging-up-Entscheidung ohne Einmal-Prüfung (M-01). |
| 4 Direktrechte/Worker | **live + statisch**: Tabellen, TEMP, Rollenwechsel, Funktions-Positivlisten, Worker-Proben. | Keine direkten Fachrechte für `vv_app`; 32 eigene App-Funktionen und 11 Worker-Funktionen laut Migration/Harness. Öffentlich ausführbare `pgcrypto`-Erweiterungsfunktionen sind keine Fachfunktionen. |
| 5 Ticket-Dienst | **statisch + Harness-live**: `verify.ts`, `server.ts`, `keyring.ts`, Rate-Limit, Dockerfile/Compose; E2E/Unit-Tests. | RS256/Issuer/Audience/`typ`/Alter, TTL-Obergrenze, interne Netzbindung und Secret-Mount vorhanden. Keine eigene externe Keycloak-Fälschungsprobe; Harness und Tests grün. |
| 6 Fail-closed | **statisch + Harness-live**: `platform/ticket.ts`, `tenant.ts`, `server.ts`, E2E bei Dienstausfall. | 503 ohne Rückfall; DB-Zugriff ohne Ticket verweigert. |
| 7 Schlüsselwechsel | **Harness-live + statisch**: echte Rotation, Übergang, Deaktivierung, Audit und Geheimnislöschung; Skript/Dateirechte gelesen. | Bestanden im lokalen Lauf; Keyring `0600`, UID 1000. |
| 8 Regression | **statisch gegen `origin/master` + Harness-live**: Stage 0/M05 und R1–R8/G-1–G-3 grün. | Fachproben überwiegend gleichwertig/stärker; S0-2-Triggerpfad nicht mehr direkt belegt (N-02). |
| 9 Validator/Selbsttest | **Harness-live + statisch**: Validatoren und 22/22 Selbsttests, Quelltext gelesen. | Bestehende Checks grün; dynamische GUC-Formen entgehen dem Regex (N-03). |
| 10 Leistung/Betrieb | **live + statisch**: 19/19 Public-Policies mit `SELECT`-InitPlan, Housekeeping und Idempotenz im Harness. | InitPlan und Aufräumen abgelaufener `jti` bestätigt; Zeitprüfung selbst fehlerhaft (H-01). |
| 11 Restrisiken | **statisch**: Dossier Abschnitt 6. | 60-s-Abfangen, 300-s-Token-Alter, künftige Refresh-Tokens und Superuser benannt; H-01 fehlt als reales längeres Nutzungsfenster. |
| 12 Bau-Dossier/Gates | **statisch + live/Remote-Status**: neun Abschnitte, Mermaid-Parser-CI grün, lokale Evidenzlinks vorhanden; lokaler Typecheck/Tests/Audit/Compose grün. | **Remote-`vv-ci` fehlgeschlagen**; DoD 12 nicht erfüllt. |

## Remote-CI und Umgebung, getrennt von Sicherheitsbefunden

- Öffentliche GitHub-Actions-API für genau `5e139c3` (Abfrage 25.09.2026): [CodeQL erfolgreich](https://github.com/critter4405-ux/VV/actions/runs/36125589511), [`vv-ci` fehlgeschlagen](https://github.com/critter4405-ux/VV/actions/runs/36125589509). Nur der Job „Live-DB: Migrationen + RLS“ war rot; darin der Schritt „C-1 Kontext-Signatur: DB-Gegenproben DoD 1–7“. Die öffentliche API liefert keine Fehlerursache, Job-Logs antworteten ohne Anmeldung mit HTTP 403. **Kein Urteil über die Ursache**; der lokale Pflicht-Harness war vollständig grün.
- WSL war im anfänglichen Sandbox-Aufruf gesperrt; nach erteilter Ausführungsfreigabe funktionierten WSL und Docker. Kein verbleibendes lokales Umgebungsproblem.
- Alle eigenen Datenbankproben nutzten ausschließlich synthetische Mandanten, Principals und Testdaten. Der temporäre Probe-Code wurde nicht in den Prüfklon übernommen.

