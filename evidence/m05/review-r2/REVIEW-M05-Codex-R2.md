# Vier-Augen-Review M05, Runde 2 — Codex

**Prüfstand:** Commit `2ff76e11f70d61ea8ea938c823572ae74bd88c11`, separater sauberer Checkout. Nur synthetische Daten. Die vorhandenen Dateien unter `evidence/` wurden nicht als Nachweis übernommen.

**Gesamturteil: nicht bestanden.** Der direkte Datenbankzugang als `vv_app` kann den angeblich verifizierten Tenant- und Actor-Kontext selbst setzen. Damit sind Mandantentrennung und Vier-Augen-Prüfung bei dem ausdrücklich verlangten direkten SQL-Angriff umgehbar. Weitere statisch belegte Lücken betreffen die Modell-Attestation und den Outbox-Topic-Filter. Der unabhängige PostgreSQL-Live-Lauf konnte wegen der lokalen Docker-Umgebung nicht abgeschlossen werden; die nachstehenden SQL-Ergebnisse sind deshalb **Reproduktionserwartungen aus dem Code, keine behaupteten Live-Messungen**.

## Befunde

### CRITICAL C-1 — Tenant und Actor sind als `vv_app` frei wählbar

**Fundort:** `db/migrations/0002_tenancy_rls.sql:14–17`, `db/migrations/0006_rbac_core.sql:205–207`, `db/migrations/0011_security_retrofit.sql:27–45,123–165`; direkter Tabellenzugriff in `db/migrations/0005_grants.sql:8`.

**Reproduktion (frische DB mit synthetischem Seed, Verbindung als `vv_app`):**

```sql
BEGIN;
SELECT set_config('app.tenant_id', '00000000-0000-0000-0000-0000000000bb', true);
SELECT id, last_name FROM person WHERE id = 'b0000000-0000-0000-0000-000000000001';
COMMIT;

BEGIN;
SELECT set_config('app.tenant_id', '00000000-0000-0000-0000-0000000000aa', true);
SELECT set_config('app.actor', 'sub-schrift-aa', true);
SELECT m05_import_request('R2SYN', repeat('a', 64), 1);
SELECT set_config('app.actor', 'sub-vorstand-aa', true);
SELECT m05_import_decide('R2SYN', 'approved');
SELECT status, approved_by FROM approval WHERE subject_ref = 'R2SYN';
ROLLBACK;
```

**Erwartet:** Die DB bindet Tenant und Actor an eine überprüfte Identität; die Rolle `vv_app` allein kann weder Mandant B lesen noch in einer Sitzung Antragsteller und Freigeber spielen. **Tatsächlich laut Code:** `vv_current_tenant()` und `vv_actor()` lesen nur frei setzbare Custom-GUCs. Die erste Abfrage erhält dadurch Mandant-B-Kontext; die zweite nutzt nacheinander zwei synthetische Principals mit den passenden Rechten. `vv_decide_approval` vergleicht nur die beiden Strings. Auch R1s `vv_audit_log` übernimmt den frei gesetzten `app.actor`. Dies betrifft direkte SQL-Nutzung bzw. eine kompromittierte `vv_app`-Verbindung; für einen unveränderten HTTP-Pfad wird keine Token-Fälschung behauptet.

**Empfehlung:** Die DB-Vertrauensgrenze für `vv_app` ausdrücklich schließen: Tenant und Actor aus einer DB-seitig nicht vom Anwendungslogin frei setzbaren, überprüften Identität ableiten; direkte Tabellenrechte auf personenbezogene Daten auf die nötigen geprüften Funktionen reduzieren. Die Vier-Augen-Gegenprobe muss beide Aktionen über dieselbe `vv_app`-Verbindung mit wechselnden GUCs versuchen.

### HOCH H-1 — R3-Attestation ist eine frei behauptete Modellkennung

**Fundort:** `db/migrations/0011_security_retrofit.sql:50–74,155–163`; Modellfelder in `db/migrations/0004_freigabe.sql:18–20`.

**Reproduktion (als `vv_app`, synthetischer Tenant A):**

```sql
SELECT vv_attestation_ok('', 'gpt-5') AS unbekannter_builder_wird_akzeptiert;
BEGIN;
SELECT set_config('app.tenant_id', '00000000-0000-0000-0000-0000000000aa', true);
SELECT set_config('app.actor', 'sub-schrift-aa', true);
INSERT INTO approval (tenant_id, kind, effect_id, subject_ref, requested_by, builder_model)
VALUES ('00000000-0000-0000-0000-0000000000aa', 'external_pii',
        'q05.import.commit', 'R2MODEL', 'sub-schrift-aa', 'claude-opus');
SELECT set_config('app.actor', 'sub-vorstand-aa', true);
SELECT vv_decide_approval((SELECT id FROM approval WHERE subject_ref = 'R2MODEL'),
                          'approved', 'gpt-5');
ROLLBACK;
```

**Erwartet:** Ein unbekanntes/leereres Builder-Modell wird abgewiesen; ein unabhängiges Review wird durch einen prüfbaren, fremden Modelllauf belegt. **Tatsächlich laut Code:** `vv_attestation_ok('', 'gpt-5')` ergibt wegen `IS DISTINCT FROM NULL` wahr. `reviewer_model` ist ein unbestätigter Freitextparameter des Entscheiders; ein Modelllauf oder dessen Herkunft wird weder gespeichert noch geprüft. Das `CHECK` und das Consume-Prädikat prüfen denselben Freitext. Die bestehenden Gegenproben testen fehlende und gleiche Kennungen, aber keine erfundene fremde Kennung und keinen leeren Builder.

**Empfehlung:** Leere/unbekannte Builder-Familie explizit ablehnen. Eine Fremdmodell-Attestation aus einem vertrauenswürdigen Review-Artefakt mit Herkunftsbindung beziehen und deren Referenz beim Entscheiden und Consume prüfen; den Freitextparameter nicht als Nachweis behandeln.

### HOCH H-2 — R5-Topic-Schutz ist über die Worker-SQL-Funktion umgehbar

**Fundort:** `db/migrations/0011_security_retrofit.sql:202–229,267–270`; Worker-Whitelist nur in `apps/worker/src/index.ts:18–21`.

**Reproduktion:** Als `vv_app` im synthetischen Tenant A eine normale Outbox-Zeile einfügen:

```sql
BEGIN;
SELECT set_config('app.tenant_id', '00000000-0000-0000-0000-0000000000aa', true);
INSERT INTO outbox (tenant_id, topic, payload, idempotency_key)
VALUES ('00000000-0000-0000-0000-0000000000aa', 'r2.ohne.consumer', '{}', 'r2-ohne-consumer');
COMMIT;
```

Dann als `vv_worker`:

```sql
SELECT id, lease_token FROM vv_outbox_claim(1, ARRAY['r2.ohne.consumer']);
-- Mit der zurückgegebenen ID und dem Token:
SELECT vv_outbox_done(:id, :lease_token);
```

**Erwartet:** Ein Topic ohne registrierten Consumer bleibt auch gegenüber direktem SQL als `vv_worker` geparkt. **Tatsächlich laut Code:** `p_topics` ist vollständig vom Aufrufer kontrolliert; `topic = ANY(p_topics)` ist die einzige Topic-Schranke. Der Worker kann das unbekannte Topic claimen und mit dem erhaltenen Token quittieren. Die Produktionsschleife übergibt zwar nur zwei registrierte Topics, die DB-Funktion erzwingt diese Liste nicht. Die CI-Gegenprobe prüft lediglich, dass die *korrekt übergebene* Liste andere Topics auslässt.

**Empfehlung:** Konsumierbare Topics DB-seitig festlegen oder eine eng berechtigte Consumer-Identität an eine unveränderliche Topic-Zuordnung binden; `vv_outbox_claim` darf keine beliebige Liste akzeptieren.

### MITTEL M-1 — Legal Hold ändert den Zustand ohne Outbox-Ereignis

**Fundort:** `db/migrations/0008_m05_functions.sql:448–461`.

**Reproduktion:** Einen fälligen, gesperrten synthetischen Zeitraum samt offenem Anonymisierungsantrag erzeugen. Als berechtigter fremder Freigeber im Tenant A ausführen (psql-Variablen `:approval_id`/`:period_id` aus dem synthetischen Testsetup):

```sql
BEGIN;
SELECT set_config('app.tenant_id', '00000000-0000-0000-0000-0000000000aa', true);
SELECT set_config('app.actor', 'sub-vorstand-aa', true);
SELECT m05_decide(:approval_id, 'rejected');
COMMIT;
-- Folgende Inspektion als vv_bootstrap im synthetischen Testsystem:
SELECT retention_until FROM membership_period WHERE id = :period_id;
SELECT count(*) FROM audit_log WHERE action = 'm05.retention.hold'
  AND subject_ref = :period_id::text;
SELECT count(*) FROM outbox WHERE topic = 'm05.retention.hold'
  AND payload->>'period_id' = :period_id::text;
```

Der direkte Reject über `vv_decide_approval` wird durch `m05_job_daily()` nachgeholt und führt zum selben fehlenden Outbox-Ereignis.

**Erwartet:** Die Verlängerung der Aufbewahrung erzeugt Audit **und** Outbox atomar, wie für Zustandsänderungen in ADR-05 und im Kopf von `0008_m05_functions.sql` zugesagt. **Tatsächlich laut Code:** `m05_apply_hold` aktualisiert `retention_until` und schreibt Audit, ruft aber weder `m05_emit` noch `vv_outbox_emit` auf. Nachgelagerte Verbraucher erhalten die Änderung nicht. Die G-3-Gegenprobe prüft nur den Audit-Eintrag.

**Empfehlung:** Für den Legal Hold ein minimales, personenbezugsfreies Outbox-Ereignis in derselben Transaktion emittieren und dessen einmalige Zustellung prüfen.

### MITTEL M-2 — Fällige Anonymisierungsanträge sind nicht nebenläufigkeitsfest angelegt

**Fundort:** `db/migrations/0008_m05_functions.sql:683–691`; Eindeutigkeitsindex in `db/migrations/0007_m05_schema.sql:283–286`.

**Reproduktion:** Bei einer synthetischen Periode mit `status='gesperrt'`, abgelaufener `retention_until` und ohne offenen Anonymisierungsantrag in zwei Sitzungen gleichzeitig `SELECT m05_job_daily()` für denselben Tenant ausführen. Die Fälligkeitsschleife enthält kein `FOR UPDATE SKIP LOCKED`; beide Sitzungen können die Periode auswählen. Eine Sitzung legt den Antrag an, die andere endet mit „bereits ein Antrag offen“ oder einem Unique-Konflikt. Ihr gesamter Tagesjob wird zurückgerollt.

**Erwartet:** Beide Jobläufe schließen idempotent ab; nur einer erzeugt den Antrag. **Tatsächlich laut Kontrollfluss:** Der Index verhindert zwar Dubletten, macht den zweiten Aufruf aber zum Fehler. Die vorhandene Tagesjob-Gegenprobe läuft seriell und deckt diese Race nicht ab.

**Empfehlung:** Fällige Perioden beim Auswählen mit `FOR UPDATE SKIP LOCKED` reservieren und den Konfliktpfad idempotent behandeln; parallele DB-Gegenprobe ergänzen.

### NIEDRIG N-1 — Zwei M05-Fremdschlüssel sind nicht mandantendicht

**Fundort:** `db/migrations/0007_m05_schema.sql:268–270,295–299`.

**Reproduktion (nur Bootstrap-Testrolle, frische synthetische DB):**

```sql
BEGIN;
WITH a AS (
  INSERT INTO approval (tenant_id, kind, effect_id, subject_ref, requested_by, builder_model)
  VALUES ('00000000-0000-0000-0000-0000000000bb', 'external_pii',
          'q05.import.commit', 'R2FK', 'synthetic', 'human:synthetic')
  RETURNING id
)
INSERT INTO m05_import_batch
  (tenant_id, batch_ref, approval_id, requested_by, rows_sha256, row_count)
SELECT '00000000-0000-0000-0000-0000000000aa', 'R2FK', id,
       'synthetic', repeat('a', 64), 1 FROM a;
ROLLBACK;
```

Der einfache FK `REFERENCES approval(id)` akzeptiert diese mandantenfremde Beziehung. Dasselbe Schema gilt für `m05_approval_request.approval_id`.

**Erwartet:** Jeder Tenant-FK referenziert `(tenant_id,id)` und weist diese Zeile bereits als Schema-Invariante zurück. **Tatsächlich laut DDL:** Nur die global eindeutige Approval-ID wird geprüft. Die aktuellen Fachfunktionen haben zusätzliche Tenant-Prädikate; ein unmittelbarer unprivilegierter Cross-Tenant-Schreibpfad wurde nicht nachgewiesen.

**Empfehlung:** `approval` um `UNIQUE (tenant_id,id)` ergänzen und beide Referenzen zu zusammengesetzten FKs machen.

## Bestätigungen und Grenzen nach Prüfpunkt

| Punkt | Selbst geprüft | Ergebnis / Grenze |
|---|---|---|
| 1 Mandantentrennung | DDL, RLS-Validator (19/19), FK-Inspektion, direkte-SQL-Reproduktion entworfen | RLS/Force statisch vorhanden; C-1 und N-1. Keine Live-DB-Bestätigung. |
| 2 Rechte und Feldsicht | Rollenmatrix, `vv_authorize_subject`, Web-Policy, M05-Lese-/Exportfunktionen, Unit-Tests | Deny-Pfade und Se-Ausblendung statisch nachvollzogen; C-1 bricht die Provenienz des Actors. |
| 3 Rechte-Eskalation | Grants, `principal_link`, `rbac_assign_role`, SoD-Trigger und Advisory-Lock | Selbstzuweisung/Umdeutung im vorgesehenen Pfad statisch gesperrt; C-1 ermöglicht Principal-Impersonation per direktem SQL. |
| 4 Vier-Augen | Approval-Insert-Guard, SoD, Effekt-Zuordnung, Antragshash, Consume, Replay und Outbox-Auslösung | R4, Bindung und Replay statisch nachvollzogen; C-1 und H-1 verhindern ein positives Gesamturteil. |
| 5 Zustandsautomat | `m05_period_guard`, `m05.ctx`, DML-Grants, Übergangsmatrix | Direkte M05-Tabellen-DML für `vv_app`/`vv_worker` statisch gesperrt; Trigger schützt normale Eigentümer-DML, sofern Trigger nicht deaktiviert werden. |
| 6 Audit/Outbox | Audit-Kette, R1, R5, R8, M05-Emits, Tagesjob | H-2, M-1, M-2. Lease-Token-Fencing statisch und durch Unit-Tests, nicht gegen PostgreSQL bestätigt. |
| 7 Datenschutz | 7-Jahre-Constraint, Sperr-/Anonymisierungspfad, synthetischer Seed, Repo-Validator | Mindestfrist und Ausblendung statisch; Mapping enthält nur Spaltennamen. Hash-Kette nicht live nachgerechnet. |
| 8 Import | Batch-Hash/Anzahl, Worker-Anbindung, fehlende Q05-Quelle, G-2-Schleife | G-1 fällt bei fehlender Quelle kontrolliert in Retry/DLQ; G-2 ohne Zeilen-Savepoints. DB-Wirkung nicht live bestätigt. |
| 9 Validatoren/Tests | Eigener Validator-Lauf, Selbsttest, beide Typechecks und Unit-Tests | Statische Checks grün; DB-Gegenproben und API/Worker-Integration mangels Docker nicht ausgeführt. |
| 10 Stage-0 0009/0010 | Trigger, Grants und Aufrufpfade statisch | Insert-Normalisierung und reservierte Topics statisch vorhanden; direkter `vv_app`-Insert in reservierte Topics gesperrt. Stage-0-Live-Gegenproben offen. |
| 11 Bau-Dossier | Neun Abschnitte, Mermaid-Block, Link-Ziele und Mapping; K29-Validator | Struktur/Links bestätigt; Rendering mit externem Mermaid-Parser nicht ausgeführt. |
| 12 R1–R8, G-1–G-3 | Migration 0011, Web/Worker, CI, Gegenproben gelesen; eigene Unit-/Validatorläufe | R1 **unvollständig** (C-1), R2 statisch bestätigt, R3 **unvollständig** (H-1), R4 statisch bestätigt, R5 **umgehbar** (H-2), R6 `master`/`main` statisch bestätigt, R7 Unit-Test bestätigt, R8 statisch/Unit-Test bestätigt; G-1/G-2 statisch bestätigt, G-3 **unvollständig** (M-1/M-2). Live-Aussagen offen. |

## Unabhängige Läufe und Harness-Zusammenfassung

| Schritt | Status | Beobachtung |
|---|---|---|
| `bash scripts/review_m05.sh`, Schritt 0 | **PASS** | LF-Checkout unter WSL, `HEAD=2ff76e1`, Arbeitsbaum sauber. |
| Schritt 1: PostgreSQL 16, Migrationen, Seeds | **FAIL (Umgebung)** | `postgres:16 nicht startbar`: Docker Desktop hatte keinen Engine-Socket; WSL-Docker-Integration meldete keinen verfügbaren Docker-Befehl. Kein Migrationsfehler nachgewiesen. |
| Schritt 2: LIVE-Validatoren, Selbsttest, DB-Gegenproben | **NICHT ERREICHT** | Abbruch in Schritt 1. |
| Schritt 3: Container-Typechecks und DB-Tests | **NICHT ERREICHT** | Abbruch in Schritt 1. |
| Schritt 4: Idempotenz und RLS ohne Kontext | **NICHT ERREICHT** | Abbruch in Schritt 1. |
| Statische Validatoren, separat | **PASS** | ADR-01 19/19; weitere statische Gates grün. LIVE-RLS wurde vom Validator ausdrücklich übersprungen. |
| Validator-Selbsttest, separat | **PASS** | 14/14 nach Setzen von `origin/HEAD` des *lokalen Prüfklons* auf `master`; vorher 12/14 wegen des beim lokalen Klonen geerbten `origin/HEAD=feat/m05-mitglieder`. |
| Typecheck Web / Worker, separat | **PASS / PASS** | `npm run typecheck` in beiden Anwendungen. |
| Unit-Tests Web / Worker, separat | **PASS / PASS** | Je 17 bestanden, 0 fehlgeschlagen, je 1 DB-Integrationstest wegen fehlender DB übersprungen. |

**Umgebung:** Ein erster Start über Windows-Git-Bash scheiterte zusätzlich an fehlenden Unix-Standardprogrammen/Pfadumsetzung. Der erste WSL-Aufruf auf dem Windows-Checkout scheiterte an CRLF. Ein unveränderter LF-Checkout unter WSL beseitigte beides und erreichte den Docker-Start; dessen Scheitern ist kein Produktbefund. Der lokale Prüfklon erbte außerdem einen falschen Remote-HEAD-Verweis vom Quellcheckout; das erklärt allein die zwei anfänglichen R6-Selbsttestabweichungen. Weder Quellcode noch Migrationen wurden repariert, committet oder gepusht.
