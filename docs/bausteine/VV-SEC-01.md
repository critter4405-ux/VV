# Bau-Dossier — VV-SEC-01 · Kontext-Signatur (Ticket-Dienst, C-1)

> **Bau-Dossier (K29).** Sicherheits-Architekturschritt C-1, gebaut nach Bau-Auftrag v1.0 (freigegeben 25.09.2026, Grill **P58**).
> **Status: FREIGEGEBEN (Betreiber, 26.09.2026)** — Review konvergiert (Runde 1 GPT-6 Sol + Gemini 3.1 Pro repariert, Runde 2 Gemini „bestanden“; Codex-Live-Runde 2 entfallen, Betreiber-Entscheidung P60); Merge Pull Request #21 → `master` (`73455a3`) nach 27/27 grünen Checks. Die Bau-KI öffnet kein Gate.

## 1. Kopf

- **Code:** VV-SEC-01 (neuer Code-Bereich `VV-SEC-##` für bausteinübergreifende Sicherheitsschritte)
- **Name:** Kontext-Signatur (Ticket-Dienst) — schließt Codex-Befund **C-1** (P54)
- **Version:** 1.2 (freigegeben)
- **Datum:** 25.09.2026
- **Verantwortlich:** Bau-KI Claude Code + Opus 5.5 (hoch) · Prüf-KI GPT-6 Sol (Codex, Live-Lauf R1) + Gemini 3.1 Pro (R1 + R2) · Freigabe Betreiber
- **Status/Gate:** **freigegeben** · Gate 1 durch Betreiber-Entscheidung geöffnet (26.09.2026, PR #21 → `master` `73455a3`)
- **Grundlage:** Bau-Auftrag `VV_C1_Bau-Auftrag_Kontext-Signatur.md` v1.0 · Register P54, P57, P58 · [project.json-Fragment](../../project/fragments/VV-SEC-01.project.json)

## 2. Was

Die Datenbank nimmt Mandant und Nutzer **nur noch mit einem Nachweis** an, den die Web-App nicht selbst herstellen kann (**Schutzziel B**): Auch eine vollständig übernommene App handelt nur im Namen von Nutzern, deren echte Anfrage gerade läuft.

- **Ticket-Dienst** (eigener Container `ticket`): prüft das Keycloak-Access-Token (RS256 via JWKS, Issuer, Audience, nur `typ=Bearer`, Token-Alter ≤ 300 s) und stellt ein **60-s-Ticket** aus: `v1.<kid>.<payload>.<hmac>` mit Mandant, Nutzer (`sub`), `iat`, `exp`, `jti`. HMAC-SHA256 mit einem Schlüssel, den **nur Dienst und DB** kennen.
- **DB-Prüfung** `vv_set_context(ticket)`: Signatur (pgcrypto, zeitkonstanter Vergleich), Schlüssel-Kennung, Ablauf, Gültigkeitsfenster ≤ 60 s, exakte Nutzlast (keine doppelten Schlüssel), bekannter Mandant, kein Systemakteur, nicht verbrauchte Kennung, **ein Kontext je Transaktion**.
- **Geprüfter Kontext statt GUC:** `vv_current_tenant()` / `vv_actor()` lesen nur noch die Kontextzeile (Backend + Transaktion) und prüfen den Ablauf **bei jeder Auswertung gegen die reale Uhr**. Auch in einer einzigen Protokollnachricht oder einem `DO`-Block endet der Kontext mit `exp`. `set_config('app.…')` wirkt nicht mehr.
- **Einmal-Tickets** für die 9 verbindlichen Befehle: Freigabe/Ablehnung (`m05_decide`, `m05_import_decide`), Bestätigung/Ablehnung eines Aging-up-Vorschlags (`m05_decide_proposal`, Review R1), Beendigungsantrag, Import-Antrag, Export, Lesen gesperrter Daten (Art. 18), Rollenvergabe/-entzug. Lesen und normale Erfassung bleiben innerhalb von 60 s mehrfach möglich. Das gilt auch für die direkten Status-Befehle (`m05_apply/admit/reject/suspend/resume/change_type/withdraw_notice`): Sie sind einzelne Erfassungsschritte ohne Vier-Augen-Grenze, sind jederzeit rückgängig zu machen oder zu korrigieren und werden im Verlauf protokolliert (P58-4).
- **Keine Direktrechte mehr für `vv_app`:** alle Tabellen-/Spalten-/Sequenzrechte entzogen; auch die Stage-0-Demo-Lesepfade laufen über `basis01_list_persons()` / `basis02_list_role_assignments()`. `vv_decide_approval` nur noch intern.
- **Worker ohne Tickets:** feste Positivliste (11 Systemfunktionen), fester Akteur `system:worker` über `vv_worker_context()`; keine Nutzer-Funktion aufrufbar.
- **Schlüsselwechsel** per [scripts/rotate_ticket_key.sh](../../scripts/rotate_ticket_key.sh) (`init` · `rotate` · `retire` · `emergency` · `status`), zwei Schlüssel in der Übergangszeit, jeder Schritt im Audit.
- **Fail-closed:** Ticket-Dienst weg → Web-App **503 „vorübergehend nicht verfügbar“**, kein Rückfall, kein Datenzugriff; Worker läuft unabhängig weiter.

## 3. Warum so

- **Warum überhaupt:** Die DB schützte gegen Programmfehler, nicht gegen eine übernommene App. Mit den App-Zugangsdaten ließen sich `app.tenant_id`/`app.actor` frei setzen — Mandant B lesen, Antragsteller + Freigeber in einer Verbindung ([Negativnachweis am alten Stand](../../evidence/c1/negativnachweis-master.txt)). Frist: **vor dem ersten echten Datenimport (S1)**, weil der Pilot laut K34 echte Daten inkl. Minderjähriger verarbeitet.
- **Eigener Ticket-Dienst statt Keycloak-Umbau** (Grill P58, Punkt 3): HS256-Realm-Schlüssel hätte einen Generalschlüssel verteilt und den OIDC-Standard gebrochen; Public-Key-Prüfung in der DB bräuchte eine abgekündigte Fremd-Erweiterung. HMAC mit pgcrypto ist Kern-Postgres ([ADR-03](../adr/ADR-03.md), [ADR-11](../adr/ADR-11.md)).
- **Kontext in einer Tabelle statt in einer GUC:** Custom-GUCs sind für jede Rolle frei beschreibbar. Die Kontextzeile ist nur für die Prüfrolle `vv_ticketcheck` schreibbar. `vv_current_tenant()`/`vv_actor()` sind `SECURITY DEFINER` mit festem `search_path = pg_catalog, pg_temp` und voll qualifizierter Tabelle, also ohne Schatten über `search_path`. Seit Review R1 sind sie `plpgsql` statt `BEGIN ATOMIC`: Der Plan wird je Sitzung zwischengespeichert, statt in jeder verschachtelten Abfrage neu geplant zu werden (siehe Leistung). `TEMP` ist für alle entzogen, `CREATE` hat `vv_app` nirgends ([ADR-01](../adr/ADR-01.md)).
- **Einmal-Ticket nur für Verbindliches** (Grill P58, Punkt 4): Lesen darf die Anfrage mehrfach, Bindendes genau einmal — Verbrauch atomar über den Primärschlüssel, nur erfolgreiche Aktionen verbrauchen (Rollback gibt frei).
- **Reale Uhr statt Anweisungszeit** (Review R1, Codex H-01): `statement_timestamp()` bleibt innerhalb einer Protokollnachricht und eines `DO`-Blocks stehen. Ein abgegriffenes Ticket wäre damit beliebig lange nutzbar gewesen. `clock_timestamp()` bei jeder Auswertung schließt das. Listen mit zeilenweiser Berechtigung (`m05_list_members`, `m05_export_members`, `m05_pending_approvals`) prüfen den Kontext am Ende erneut: Läuft er mitten in der Abfrage ab, gibt es einen Fehler statt einer still gekürzten Liste.
- **Keine Toleranz auf `exp`** (Review R1, Gemini G3, Betreiber-Entscheidung): Geht die DB-Uhr vor, verkürzt ein Versatz das Fenster nur. Geht sie nach, greift die 5-s-Toleranz auf `iat`. Eine Toleranz auf `exp` würde nur abgegriffene Tickets verlängern.
- **Worker ohne Tickets** (Punkt 5): Hintergrundjobs haben keine Nutzeranfrage; sie dürfen nie als Mensch auftreten — deshalb fester Systemakteur und getrennte Positivlisten ([ADR-06](../adr/ADR-06.md)).
- **Fail-closed** (Punkt 7): jeder Rückfall auf den alten Weg wäre eine Hintertür; deckt sich mit B09-1 und K36 (Degradation statt Umgehung).
- **Nicht umgesetzt (Nicht-Ziele):** nutzersignierte Freigaben (Option C, Passkey) — der Dienst bleibt dafür erweiterbar; keine Änderung an Keycloak; keine M05-Fachlogik-Änderung außer der Kontext-Übergabe.

## 4. Wie umgesetzt

- **Migration** [0013_kontext_signatur.sql](../../db/migrations/0013_kontext_signatur.sql) (idempotent, atomar):
  - Rolle `vv_ticketcheck` (NOLOGIN, NOBYPASSRLS) besitzt die Prüf-/Kontextfunktionen.
  - Tabellen `ticket_key` (nur `vv_ticketcheck` lesbar; deaktiviert = Geheimnis gelöscht), `ticket_used` (verbrauchte Kennungen), `vv_ctx` (UNLOGGED, Kontext je Backend + Transaktion, CHECK: Systemkontext nie menschlich).
  - Funktionen `vv_set_context`, `vv_worker_context`, `vv_worker_tenants`, `vv_bootstrap_context` (nur Superuser: Seeds/Onboarding/Tests), `vv_ticket_once`, `vv_ticket_housekeeping`, Schlüsselverwaltung `vv_ticket_key_add/expire/disable/event`.
  - Umgestellt: `vv_current_tenant`, `vv_actor`, `vv_decide_approval`, `vv_approval_insert_guard`, `rbac_onboard_root`, `rbac_link_principal`; SoD-Trigger jetzt **fail-closed ohne passenden Kontext**.
  - Verbindliche Befehle: Kern umbenannt in `…__kern` (nur Definer), neuer gleichnamiger Einstieg ruft zuerst `vv_ticket_once`. Listen (`m05_list_members`/`export_members`/`pending_approvals`) enden mit `vv_ctx_require_valid()`.
  - RLS-Policies werten den Kontext als **InitPlan** aus (einmal je Abfrage).
  - Rechte als **Positivlisten** (`vv_app`: 32 Funktionen, `vv_worker`: 11), PUBLIC-EXECUTE auf allen eigenen Funktionen entzogen, `TEMP` entzogen.
- **Ticket-Dienst** [apps/ticket](../../apps/ticket/src/): [ticket.ts](../../apps/ticket/src/ticket.ts) (Format/HMAC), [verify.ts](../../apps/ticket/src/verify.ts) (RS256-JWKS, Issuer, Audience, `typ`, Token-Alter), [keyring.ts](../../apps/ticket/src/keyring.ts) (Docker-Secret, Neuladen bei Änderung/SIGHUP), [server.ts](../../apps/ticket/src/server.ts) (ein Endpunkt, Rate-Limit je Quelle und Nutzer, Logs ohne Tokens), Health `/health`.
- **Web-App:** [platform/ticket.ts](../../apps/web/src/platform/ticket.ts) (Ticket holen, 2 s Timeout, fail-closed) · [platform/tenant.ts](../../apps/web/src/platform/tenant.ts) (`withTenant(client, ticket)` → `vv_set_context`) · [server.ts](../../apps/web/src/server.ts) (401/503-Logik) · Aktionen reichen nur das Ticket weiter.
- **Worker:** [jobs/m05.ts](../../apps/worker/src/jobs/m05.ts) und [approval_store.ts](../../apps/worker/src/agents/approval_store.ts) → `vv_worker_context`; Tagesjob räumt `ticket_used` auf.
- **Compose:** Dienst `ticket` mit Secret `ticket_keyring`, `restart: always`, Healthcheck, `read_only`, `cap_drop: ALL`, nur internes Netz `ticketnet` (kein Port nach außen); Web erhält nur `TICKET_URL` ([docker-compose.yml](../../docker-compose.yml)).
- **Betrieb:** Schlüsselwechsel planmäßig **alle 90 Tage** (`status` warnt), sofort bei Verdacht (`emergency`), nach Restore aus altem Backup (ADR-11). Keyring-Datei 0600, Eigentümer = Container-Nutzer (`KEYRING_UID=1000`), verschlüsselte Kopie per `sops`/`age` (`SOPS_AGE_RECIPIENTS`).
- **Grenzen:** Ausfall-Alarm wird angebunden, sobald das ADR-11-Monitoring steht (bis dahin Healthcheck + Log); Image-Digests folgen P47.

## 5. Wie getestet

- **C-1-Gegenproben DoD 1–7 + Review R1 gegen echte PostgreSQL 16:** [scripts/c1_db_asserts.py](../../scripts/c1_db_asserts.py) — **83/83** ([Ausgabe](../../evidence/c1/c1-asserts.txt)): P54-Reproduktion schlägt fehl, keine Direkt-Grants (alle Schemata), exakte Funktions-Positivlisten, 14 Fälschungs-/Ablaufvarianten + doppelte Schlüssel, Mandantentrennung, Einmal-Tickets (seriell, gleiche Transaktion, parallel, Aging-up), Worker-Trennung, echter Schlüsselwechsel mit dem Betreiber-Skript, InitPlan. Aus Review R1 dazu: Ablauf in **einer Protokollnachricht** und im **`DO`-Block** (Lesen und verbindliche Aktion), Liste nach Ablauf gibt Fehler statt Kürzung, Uhrversatz `iat` +4/+6 s, Antragsteller-Bindung auf dem echten Pfad App → Definer-Funktion. Die neuen Proben sind am alten Stand rot ([Negativnachweis R1](../../evidence/c1/review-r1/negativnachweis-r1-alter-stand.txt)).
- **Regression auf dem Ticket-Weg (ohne Abschwächung):** Stage-0-Proben **38/38** + M05 **140/140** ([db-asserts.txt](../../evidence/c1/db-asserts.txt)); wo `vv_app` früher auf eine Normalisierung stieß, gilt jetzt der stärkere Nachweis „kein Recht“, die Normalisierung selbst wird über die Definer-Rolle weiter geprüft.
- **Ende-zu-Ende** [scripts/c1_e2e.sh](../../scripts/c1_e2e.sh) — echte Kette Token → Ticket-Dienst → Web → DB, inkl. **503 bei Dienstausfall ohne Datenzugriff** und Wiederanlauf ([c1-e2e.txt](../../evidence/c1/c1-e2e.txt)).
- **Tests:** Web 23/23, Worker 18/18, Ticket-Dienst 21/21 (u. a. alg-Tausch, ID-/Refresh-Token, fremder Aussteller, Rate-Limit, keine Tokens im Log); Typecheck rc=0; `npm audit` 0 (3 Apps); Worker-Start-Probe grün; `docker compose config` valide; Migrationen 0006–0013 idempotent.
- **Validatoren:** LIVE grün inkl. neuem Check **C-1** (keine `app.*`-GUC in App-Code, im produktiven Code überhaupt kein `set_config`/`current_setting`, kein Schlüsselmaterial in der Web-App, keine Direkt-Grants, Kontext-Ablauf gegen die reale Uhr, M05-Schreibfunktionen setzen immer den internen Fachkontext), Selbsttest **25/25** ([validator-report.json](../../evidence/c1/validator-report.json)). Der statische Teil ist eine **Heuristik** (Frühwarnung). Maßgeblich sind die DB-Invarianten: Eine frei gesetzte GUC wirkt in der DB nicht.
- **Leistung:** [perf.md](../../evidence/c1/perf.md) — `vv_set_context` ≈ 0,5 ms je Anfrage; RLS mit InitPlan ≈ 3× schneller als Auswertung je Zeile. M05-Mitgliederliste (3 008 Mitglieder, zeilenweise Berechtigung): ohne C-1 4,4 s, C-1 v1.0 8,7 s, **nach R1 5,3 s** (Kontextfunktionen `plpgsql`). Die Grundlaufzeit liegt im M05-Bestand und ist als eigener Register-Punkt vorgeschlagen.
- **Gesamtnachweis:** [evidence/c1/verification.md](../../evidence/c1/verification.md) · DoD-Checkliste [gate-c1-checklist.md](../../evidence/c1/gate-c1-checklist.md) · Review-Harness [scripts/review_c1.sh](../../scripts/review_c1.sh).

## 6. Sicherheit & Datenschutz

- **Schlüssel:** HMAC-Schlüssel (32 Byte) nur im Ticket-Dienst (Docker-Secret) und in `ticket_key` (nur Prüfrolle); nie in Web-App, Repo, CI-Variablen oder Logs (CI: Wegwerf-Schlüssel je Lauf). Validator erzwingt: kein Schlüsselmaterial im Web-Code.
- **Datenklassen:** Ticket enthält nur Referenzen (Mandanten-UUID, OIDC-`sub`), keinen Klartext-Personenbezug. Audit der Schlüsselereignisse nur mit Kennung.
- **Restrisiken (dokumentiert, Schutzziel B bewusst):**
  - Eine übernommene App kann für **laufende** Anfragen innerhalb von 60 s im Namen dieses Nutzers handeln und ein abgefangenes Access-Token bis zu 300 s zum Ticket-Holen nutzen (Token-Alter-Grenze). Freigaben „nur durch den Nutzer selbst“ = Option C (Passkey), später.
  - **Abgegriffenes Ticket** (Log, Proxy, Innentäter; Review R1, Gemini G2): Bis `exp` (höchstens 60 s, gegen die reale DB-Uhr) ist es für **Lesen und normale Erfassung** mehrfach nutzbar, für eine **verbindliche Aktion genau einmal**. Das ist die bewusste Abwägung aus P58-4. Gegenmittel: keine Tickets/Tokens in Logs (Ticket-Dienst getestet), Ticket nur im Speicher der laufenden Anfrage.
  - **Uhrzeit** (Review R1, Gemini G3): DB und Ticket-Dienst müssen zeitsynchron laufen (NTP/chrony, **Betriebsauflage ADR-11**). Geht die DB bis 5 s nach, wird das Ticket angenommen (`iat`-Toleranz). Geht sie mehr als 5 s nach, werden alle Tickets verweigert (fail-closed). Geht sie vor, verkürzt sich das Fenster um den Versatz. Das Monitoring soll gehäufte „Ticket verweigert: Gültigkeitsfenster/abgelaufen“ melden.
  - Hält die Web-App künftig **Refresh-Tokens** (serverseitiger Login-Flow), könnte sie Tickets ohne laufende Anfrage erzeugen → Auflage für den Frontend-/Login-Bau: Refresh-Tokens nicht im Web-Server, oder Option C.
  - Superuser/Betreiber-Zugang bleibt allmächtig (Bootstrap-Kontext nur für Superuser); Schutz über ADR-11 (Zugang, Audit-Anchoring).
- **Freigaben:** keine bindende Wirkung ohne Betreiber-Freigabe; Merge nach `master` ist Betreiber-Entscheidung.

## 7. Visual

```mermaid
sequenceDiagram
    participant B as Browser (Nutzer)
    participant W as Web-App (vv_app)
    participant T as Ticket-Dienst
    participant K as Keycloak (JWKS)
    participant D as PostgreSQL
    B->>W: Anfrage + Access-Token
    W->>T: POST /v1/ticket (Bearer)
    T->>K: JWKS (RS256, gecacht)
    T-->>W: Ticket v1.kid.payload.hmac (60 s)
    W->>D: BEGIN · vv_set_context(ticket)
    D->>D: HMAC + Ablauf + Kennung prüfen, Kontext setzen
    W->>D: Fachfunktion (RLS mit geprüftem Kontext)
    D->>D: verbindlich? Ticket-Kennung einmalig verbrauchen
    D-->>W: Ergebnis · COMMIT
    Note over W,D: Gefälschte GUC app.* wirkt nicht mehr · ohne Ticket kein Zugriff
    W-->>B: 200 (Ticket-Dienst weg: 503, kein Rückfall)
```

## 8. Nutzen in Klartext

Selbst wenn ein Angreifer die Web-Anwendung übernimmt, kann er in der Datenbank keine Vereine oder Personen erfinden und nicht nachts im Namen des Kassiers oder Obmanns handeln — die Datenbank verlangt für jede Anfrage einen kurzlebigen, fälschungssicheren Nachweis des angemeldeten Nutzers. Verbindliches wie Freigaben oder Exporte geht pro Nachweis genau einmal. So bleiben Mitgliederdaten, auch von Kindern und Jugendlichen, auch im schlimmsten Fall getrennt und nachvollziehbar.

## 9. Änderungshistorie

- **1.0 (25.09.2026):** Bau C-1 nach Bau-Auftrag v1.0 (P58) — Migration 0013, Ticket-Dienst, Web/Worker-Umstellung, Betreiber-Skript Schlüsselwechsel, Gegenproben/e2e/Validator, Evidenz `evidence/c1/`.
- **1.1 (25.09.2026):** Reparatur Review R1 (Codex GPT-6 Sol + Gemini 3.1 Pro, [Einstufungen](../../evidence/c1/review-r1/)): H-01 Ablauf gegen reale Uhr + End-Prüfung Listen; M-01 `m05_decide_proposal` einmalig; N-01 doppelte Schlüssel; N-02 Probe App→Definer; N-03 Validator verschärft + Live-Invariante; E-1 Kontextfunktionen `plpgsql` (Leistung); CI-Probe mit frischen Tickets; G2/G3 Restrisiken + Zeitsync-Auflage.
- **1.1a (26.09.2026):** Runde 2 — Gemini „bestanden“, keine neuen Befunde; Codex-Live-Runde entfallen (Werkzeug gesperrt), Abweichung als Betreiber-Entscheidung dokumentiert ([Abschluss R2](../../evidence/c1/review-r2/ABSCHLUSS-R2.md), Register P60). CI auf `8d6d16e` grün. Review konvergiert.
- **1.2 (26.09.2026): FREIGABE (Betreiber)** — Merge Pull Request #21 `feat/c1-kontext-signatur` → `master` (`73455a3`) nach 27/27 grünen Checks. Vor dem Merge CodeQL-Befunde #30/#31 behoben, #32 als Fehlalarm geschlossen ([Einstufung](../../evidence/c1/codeql-pr21.md)). Ruleset `master-schutz` um die Pflicht-Checks des Ticket-Dienstes ergänzt. Die Bau-KI hat das Gate nicht geöffnet.
