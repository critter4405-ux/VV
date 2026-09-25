# Bestätigungs-Review M05, Runde 3 — Codex

**Prüfstand:** frischer LF-Klon unter /home/ws126/VV (WSL Ubuntu), Commit d3f30279c9526e70a28bdfeb02330c8bb93fb704, PostgreSQL 16.15 in Docker. Ausschließlich synthetische Seed- und Prüfdaten. Keine Reparatur, kein Commit, kein Push.

**Gesamturteil: bestanden.** Die fünf in Runde 2 zur Reparatur angenommenen Befunde halten den gezielten Live-Gegenproben stand. Es wurde kein neuer M05-Befund nachgewiesen. Die M05-Freigabe bleibt eine Betreiber-Entscheidung.

## Neue Befunde

| Schwere | Ergebnis |
|---|---|
| CRITICAL | Keine |
| HOCH | Keine |
| MITTEL | Keine |
| NIEDRIG | Keine |

Die frei eingegebenen Modellkennungen werden erst in Stage 1 durch ein Prüfartefakt mit Herkunftsbindung ersetzt (P54/BASIS-09). Das ist eine dokumentierte Design-Grenze und kein neuer R3-Befund.

## Status der R2-Reparaturen und eigene Live-Reproduktion

Alle Abfragen liefen auf der nach dem Pflicht-Harness stehen gebliebenen, frisch migrierten Prüf-DB. Wo nötig wurde der Kontext in einer Transaktion mit set_config('app.tenant_id', Tenant A, true) und set_config('app.actor', synthetischer Principal, true) gesetzt. Jeder angegebene Personen-/Antragsfall stammt aus db/seed/0002_m05_synthetic.sql oder wurde daraus über M05-Funktionen synthetisch erzeugt.

| R2-Befund | Status | Erwartet und tatsächlich |
|---|---|---|
| H-1, db/migrations/0011_security_retrofit.sql:50–77, 156–160 | **behoben** | SELECT vv_attestation_ok('', 'gpt-5'), vv_attestation_ok('unknown-builder', 'gpt-5'), vv_attestation_ok('claude-opus', 'gpt-5'), vv_attestation_ok('claude-opus', 'claude-sonnet') ergab **false/false/true/false**. Je ein als vv_app gestellter Q05-Antrag mit leerem bzw. xyz-bot-Builder blieb trotz Entscheidung durch sub-vorstand-aa mit Reviewer gpt-5 auf pending; vv_decide_approval meldete „Fremdmodell-Attestation fehlt/ungültig“. Auch CHECK und Consume wurden in den SQL-Gegenproben geprüft. |
| H-2, db/migrations/0011_security_retrofit.sql:207–245 | **behoben** | Ein als vv_app erzeugtes Ereignis r3.ohne.consumer ergab als vv_worker bei SELECT id FROM vv_outbox_claim(10, ARRAY['r3.ohne.consumer']) **0 Zeilen**. Danach attempts=0 und processed_at NULL. INSERT INTO outbox_consumer als vv_worker scheiterte mit permission denied; has_table_privilege für INSERT/UPDATE/DELETE war false. |
| M-1, db/migrations/0008_m05_functions.sql:448–468 | **behoben** | Ein fälliger gesperrter synthetischer Fall wurde per m05_decide(approval_id,'rejected') abgelehnt. Danach: verlängerte retention_until, genau **1** Audit-Eintrag und **1** Ereignis m05.retention.hold, auch nach erneutem Tagesjob nur **1** Antrag. Der Umweg per vv_decide_approval(approval_id,'rejected') und nachfolgendem m05_job_daily() ergab ebenfalls genau **1** Audit- und **1** Outbox-Ereignis; ein weiterer Job verdoppelte nichts. |
| M-2, db/migrations/0008_m05_functions.sql:690–706 | **behoben** | Zwei überlappende vv_worker-Transaktionen führten SELECT m05_job_daily() aus. Lauf A hielt nach dem Job die Transaktion per pg_sleep(6) offen; Lauf B startete währenddessen. **Beide COMMIT ohne Fehler**, A meldete anonymize_requested=1, B =0; für die fällige Periode existierte danach genau **1** Anonymisierungsantrag. Auch die eigene Python-Gegenprobe mit zwei Verbindungen war grün. |
| N-1, db/migrations/0007_m05_schema.sql:265–315 | **behoben** | Als vv_bootstrap wurde in einer zurückgerollten Transaktion eine Freigabe für Mandant B erzeugt und mit tenant_id von A in m05_import_batch bzw. m05_approval_request referenziert. Beide INSERTs scheiterten erwartungsgemäß mit **mib_approval_fk** bzw. **mar_approval_fk**; ein gültiger Periodenbezug für A war vorhanden. |

Zusätzliche Umgehungsversuche: vv_app konnte den Freigabestatus nicht direkt setzen und reservierte M05-Outbox-Topics nicht selbst einfügen; ein unbekanntes Outbox-Topic blieb auch nach explizitem Worker-Claim geparkt; direkte Ablehnung außerhalb von m05_decide löste den Hold über den Tagesjob genau einmal aus. Die regulären HTTP-Routen verwenden Tenant und Actor aus verifyBearer() und withTenant() (apps/web/src/platform/auth.ts:19–36, tenant.ts:13–37, modules/mitglieder/mitglieder.routes.ts:3–5); ein Angriff über ein verifiziertes OIDC-Token wurde nicht nachgewiesen. Dies ist eine statische Pfadprüfung, kein Live-HTTP-Test mit einem OIDC-Issuer.

## Pflicht-Harness und unabhängige Nachläufe

Pflichtaufruf zuerst: VV_KEEP_DB=1 bash scripts/review_m05.sh aus dem Repo-Root. Der rohe Harness meldete **PASS=13, FAIL=3**. Die drei roten Schritte waren Folge des Python-Setups: deb.debian.org/debian-security lieferte für trixie-security/Packages HTTP 404; deshalb fehlten psql, psycopg und jsonschema im Python-Container. Docker und PostgreSQL starteten regulär. Diese drei FAILs sind **Umgebung**, keine DB- oder Produktfehler.

| Harness-Schritt | Rohstatus | Beobachtung / unabhängiger Nachlauf |
|---|---|---|
| 0 Stand | **PASS** | HEAD d3f3027, Arbeitsbaum vor dem Lauf sauber. |
| 1 PostgreSQL 16, Migrationen, Seeds | **PASS** | Frische Prüf-DB, alle Migrationen 0001–0011 und Seeds fehlerfrei. |
| 2 Python-Setup | **FAIL (Umgebung)** | Debian-Security-Paketindex 404. |
| 2 Validatoren LIVE | **FAIL (Folge Umgebung)** | Im Pflichtlauf fehlten jsonschema und psycopg. Separater Lauf im temporären Python-Container: **PASS**, Gate 0→1 grün, LIVE-RLS/Rollen 20/20. |
| 2 Validator-Selbsttest | **PASS** | Schon im Pflichtlauf grün. |
| 2 DB-Gegenproben | **FAIL (Folge Umgebung)** | Im Pflichtlauf fehlten psql/psycopg. Nachlauf: alle Shell-SQL-Proben vor dem Python-Teil **OK**; vollständiger M05/BASIS-02-Python-Lauf **137/137 PASS** gegen dieselbe DB. Für dessen reinen Migrationsreplay wurde in der temporären Python-Umgebung ein psql-Aufruf über psycopg ausgeführt; echtes psql bestätigte die Idempotenz zusätzlich in Schritt 4. |
| 3 Node Web/Worker | **PASS** | Typecheck Web/Worker; Tests Web **18/18**, Worker **18/18**, einschließlich DB-Integration. |
| 4 Idempotenz/RLS ohne Kontext | **PASS** | Migrationen 0006–0011 erneut fehlerfrei; alle fünf Tabellen ohne Kontext leer bzw. permission denied. |

Die SQL-Nachläufe bestätigten unter anderem SoD, Freigeber-Recht, Modellfamilien, Consume/Replayschutz, Audit- und Outbox-Rechte, Reaper, Lease-Fencing, Topic-Register sowie Stage-0-Härtungen. Der Python-Lauf bestätigte die M05-Fach- und Datenschutzpfade, den 3.005-Zeilen-Import, Legal Hold, Parallelität, FKs und eine intakte Audit-Hash-Kette.

## Prüfpunkte 1–13 aus docs/REVIEW-Auftrag-M05.md

| Punkt | Eigene Bestätigung |
|---|---|
| 1 Mandantentrennung | Live-RLS/Rollen 20/20; Tenant-A/B-Gegenproben und zusammengesetzte FKs live. |
| 2 Rechte/Feldsicht | Live-Deny-Pfade, Trainer nur eigenes Team, Se nur berechtigte Rollen, Export ohne Se (137er-Lauf); HTTP-Principal-Pfad statisch. |
| 3 Rechte-Eskalation | Selbstzuweisung, SoD und Umdeutung bestehender Zuweisungen live abgewiesen. |
| 4 Vier-Augen | Selbstfreigabe, fremdes Recht, Parameter-/Hash-Tausch, Replay, Ablauf, veralteter Antrag, Outbox-Spoofing live geprüft. |
| 5 Zustandsautomat | Verbotener Übergang, Eigentümer-DML, Löschung, Append-only und Freigabe-Kontext live geprüft. |
| 6 Audit/Outbox | Atomare Emission, Legal Hold, Job-Parallelität, Fencing und Audit-Hash-Kette live geprüft. |
| 7 Datenschutz | 7-Jahres-Grenze, Sperre, Anonymisierung, Payload ohne Klartext und Mapping nur mit Spaltennamen live/statisch geprüft. |
| 8 Import | Hash-/Anzahl-Bindung, Idempotenz, Konfliktbericht, kein Überschreiben und 3.005-Zeilen-Lauf live. |
| 9 Validatoren/Tests | Live-Validator grün, Selbsttest grün, Web/Worker je 18/18, M05-DB 137/137. |
| 10 Stage 0 S0-1–S0-3 | Freigabe-Insert-/Antragsteller-Guard und reservierte Outbox-Topics live abgewiesen; vorhandener Pfad weiterhin grün. |
| 11 Bau-Dossier | Neun Abschnitte/Mermaid-Block 15/15 und Evidenz-Links 35/35 im Validator; kein externer Mermaid-Renderlauf. |
| 12 R1–R8, G-1–G-3 | R1/R3/R4/R5/R7/R8 sowie G-1–G-3 live/Tests grün; R2 feste Executor-Registry und R6 master/main in CI/CodeQL statisch plus Node-Tests bestätigt. |
| 13 R2-Fixes | H-1, H-2, M-1, M-2, N-1 wie oben einzeln live reproduziert und **behoben**. |

Die Prüfung verwendete ausschließlich synthetische Daten. Nach Abschluss wurden vv_m05_pg und vv_m05_net entfernt.
