# Bericht GPT-6 Sol — Kalibrierungs-Blindtest Stage 0 (Prüfstand bff8e58)

> Vom Betreiber am 24.09.2026 im Chat übergeben. Text unverändert übernommen; nur die Datei-Zitatmarker der Chat-Oberfläche (z. B. „03_PRUEFSTAND_TEIL_1_von_3.txt") entfernt und Tabellen als Markdown gesetzt. Auswertung: [auswertung.md](auswertung.md). Nur synthetische Beispiele.

## Vollständigkeit bestätigt

Die Prüfung wurde erst nach erfolgreicher Vollständigkeitskontrolle begonnen.

- Alle 3 Paket-Teile sind vorhanden.
- END-FILE-Marken: 27 + 39 + 29 = exakt 95.
- BEGIN-FILE-Indizes laufen lückenlos von [1/95] bis [95/95].
- Alle 95 im Manifest aufgeführten Dateien wurden bytegenau extrahiert; Dateigröße und vollständiger SHA-256 stimmen bei 95/95 mit 02_MANIFEST.txt überein. Das Manifest nennt ausdrücklich 95 Bundle-Dateien.
- Die leere validators/checks/__init__.py hat korrekt 0 Byte und den SHA-256 der leeren Datei; die Bundle-Trennzeile gehört nicht zum Dateiinhalt.
- Am Ende von Teil 3 steht eindeutig BUNDLE COMPLETE: 95 FILES, TEIL 3/3.

Damit war die im Paket selbst verlangte Vollständigkeitsbedingung erfüllt.

## Gesamturteil: NICHT BESTANDEN

Der Prüfauftrag verlangt ausdrücklich eine adversariale Prüfung darauf, ob die Invarianten wirklich erzwungen und nicht nur behauptet werden.

Es gibt mehrere reproduzierbare Fälle, bei denen eine fundamentale Invariante verletzt werden kann und der Stage-0-Validator trotzdem Exit 0 / GATE GRÜN meldet. Besonders kritisch sind Vier-Augen/Freigabe, zentraler Policy-Punkt, RLS-Policy-Semantik, Audit-Vollständigkeit und der Schutz vor echten personenbezogenen Daten.

## Befunde

**1. BLOCKIEREND — Vier-Augen-Freigabe ist nicht an eine reale Freigabe gebunden.**
Fundort: apps/worker/src/agents/vier_augen.ts:50–58, 73–105, apps/worker/src/agents/vier_augen.test.ts:36–42.
Beleg/Reproduktion: ExecRequest enthält actionClass, state, reviewerModelFamily, approvedBy und approvalToken als gewöhnliche Eingabefelder. Das angebliche Einmal-Token wird nur gegen ein lokales Set<string> geprüft; es gibt keine Ausstellung, Signatur oder DB-Verknüpfung mit einem approval-Datensatz. Der vorhandene Test demonstriert das selbst: der beliebige String "t3" wird beim ersten Aufruf akzeptiert. Nach Prozessneustart oder auf einer zweiten Worker-Instanz ist auch der Replay-Speicher leer. Zusätzlich wird assertTransition() von assertExecutable() überhaupt nicht verwendet.
Empfehlung: Ausführung nur über eine persistierte approval_id; Status, Antragsteller, tatsächlicher Freigeber, Aktion, Tenant und Verbrauchsstatus aus der DB laden. Atomarer Consume etwa über UPDATE ... WHERE status='approved' AND consumed_at IS NULL ... RETURNING. Keine vom Aufrufer gelieferten Zustände oder „Tokens" als Freigabenachweis akzeptieren. Auch die Action-Klassifikation muss aus der tatsächlich auszuführenden serverseitigen Operation entstehen.

**2. BLOCKIEREND — Der zentrale Policy-Prüfpunkt ist durch die Validator-Heuristik umgehbar.**
Fundort: validators/checks/adr04_policy.py:14–18, 31–57, 60–81.
Beleg/Reproduktion: Der Validator sucht SQL mit Regex und prüft nur, ob innerhalb von 160 Zeichen nach if (!decision.allowed) irgendwo return oder throw vorkommt. Gegenprobe: if (!decision.allowed) { if (false) return; } gefolgt von DELETE FROM person wurde als gültig akzeptiert. Ebenso blieb ein Schreibzugriff wie const op="DELETE"; pool.query(op+" FROM person") außerhalb einer Action unerkannt. Beide manipulierten Repos endeten mit Exit 0 / GATE GRÜN. Die Heuristik ist im Code klar erkennbar.
Empfehlung: Keine Regex als Sicherheitsgrenze. DB-Schreibzugriff strukturell nur über eine kontrollierte Mutation-/Repository-API ermöglichen, die Policy-Entscheidung und Mutation untrennbar koppelt. Ergänzend AST-/TypeScript-Compiler-Analyse bzw. ESLint-Regel mit Kontrollflussanalyse.

**3. BLOCKIEREND — ADR-01 prüft nur das Vorhandensein einer Policy, nicht deren Schutzwirkung.**
Fundort: validators/checks/adr01_rls.py:12–19, 32–58; validators/checks/db_live.py:43–60.
Beleg/Reproduktion: Eine Policy wird als ausreichend gezählt, sobald irgendein CREATE POLICY ... ON tabelle vorhanden ist. Auch der Live-Check zählt lediglich pg_policy-Einträge und relforcerowsecurity; der Policy-Ausdruck wird nicht ausgewertet. Ich habe bei approval die Policy auf USING (true) WITH CHECK (true) geändert. Ergebnis des statischen Gate-Laufs: ADR-01 PASS / Exit 0. Der Live-Validator würde dieselbe Policy ebenfalls als vorhanden zählen. Der zusätzliche CI-Gegencheck testet nur person, nicht alle tenant-scoped Tabellen.
Empfehlung: Effektive Policies aus pg_policy auslesen und ihre Semantik prüfen; zusätzlich für jede tenant-scoped Tabelle echte Zwei-Mandanten-Gegenproben für SELECT/INSERT/UPDATE/DELETE durchführen. Auch relrowsecurity selbst muss geprüft werden, nicht nur relforcerowsecurity.

**4. BLOCKIEREND — K31 verhindert keine realen personenbezogenen Daten im Repo/CI.**
Fundort: validators/checks/synthetic_guard.py:16–22, 29–36, 62–79.
Beleg/Reproduktion: Inhaltlich erkennt der Textscanner praktisch nur AT-IBAN und E-Mail-Adressen. PDF/JPG/PNG usw. werden ausdrücklich übersprungen. Gegenprobe mit einer roster.csv, die realistisch Namen, Wohnadresse, Geburtsdatum, Telefonnummer und eine SVNR-artige Nummer enthielt, jedoch keine E-Mail und keine IBAN: K31 PASS / gesamtes Gate GRÜN. Damit wird die harte Aussage „kein Personenbezug im Repo/CI" nicht erzwungen.
Empfehlung: Fail-closed statt Muster-Blacklist: nur explizit zugelassene synthetische Fixture-Verzeichnisse/Datenformate; zusätzliche Erkennung von Namen, Adressen, Geburtsdaten, Telefon, SVNR und IDs; PDF/Bild-/Binärdateien nicht pauschal überspringen. Nicht decodierbare Dateien dürfen nicht automatisch als unbedenklich gelten.

**5. BLOCKIEREND — „Lückenloses Audit" wird nicht als Invariante erzwungen.**
Fundort: apps/web/src/platform/audit.ts:1–17, Validator-Orchestrierung bzw. adr04_policy.py.
writeAudit() ist lediglich eine freiwillig aufzurufende Hilfsfunktion. Der Kommentar fordert zwar dieselbe Transaktion wie die Datenänderung, technisch gibt es aber keine Kopplung.
Beleg/Reproduktion: Ich habe eine regulär policy-gegatete UPDATE-Action angelegt, aber writeAudit() und Outbox bewusst weggelassen. Alle Stage-0-Validatoren meldeten PASS / GATE GRÜN.
Empfehlung: Mutation und Audit/Outbox müssen dieselbe technische Primitive verwenden. Entweder kontrollierte DB-Funktionen/Trigger oder eine einzige Mutation-API, die Fachänderung + Audit + Outbox atomar erzwingt. Eine Entwicklerkonvention genügt für die behauptete Invariante nicht.

**6. HOCH — Freigaben können von der allgemeinen App-Rolle direkt verändert oder gelöscht werden.**
Fundort: db/migrations/0004_freigabe.sql:5–18; db/migrations/0005_grants.sql:7–11.
Die DB prüft bei approval im Wesentlichen nur, dass approved_by <> requested_by und bei approved ein Freigeber sowie decided_at vorhanden sind. Gleichzeitig erhält vv_app ausdrücklich INSERT, UPDATE, DELETE auf approval.
Beleg: Ein App-Codepfad kann innerhalb seines Tenants beispielsweise einen Freigeber-String setzen, der nur vom Antragsteller verschieden ist. Die DB bindet approved_by nicht an den tatsächlich authentifizierten Benutzer oder eine freigabeberechtigte Rolle.
Empfehlung: Direktes UPDATE/DELETE auf approval für vv_app entziehen. Statusübergänge über eng definierte DB-Funktionen; tatsächliche Actor-ID serverseitig/DB-seitig binden; Entscheidung und Freigeber unveränderlich auditieren.

**7. HOCH — RLS schützt nur den vom App-Prozess gewählten Tenant; app.tenant_id ist keine vertrauenswürdige Identität.**
Fundort: db/migrations/0002_tenancy_rls.sql:14–17; apps/web/src/platform/tenant.ts:9–22.
vv_current_tenant() vertraut direkt auf current_setting('app.tenant_id'); withTenant() setzt diesen Wert aus einem übergebenen String. Besonders aufschlussreich ist der eigene RLS-Nachweis: dieselbe Rolle vv_app setzt einmal Tenant A und danach Tenant B und sieht jeweils dessen Daten. Die RLS erzwingt also Isolation gegenüber dem gewählten Kontext, bindet diesen Kontext aber nicht an die DB-Identität. Die JWT-Schicht liest zwar tenant_id aus einem verifizierten Token, aber Modulfunktionen nehmen weiterhin gewöhnliche ctx.tenantId-Strings entgegen.
Empfehlung: Actions nur mit einem serverseitig erzeugten, nicht frei konstruierbaren Principal/RequestContext aufrufen. Kein fachlicher API-Einstieg darf tenantId separat übernehmen. Für stärkere Isolation direkte Tabellenrechte weiter reduzieren bzw. Tenant/Actor-Zuordnung in kontrollierten DB-Funktionen erzwingen.

**8. HOCH — ADR-02 Cross-Modul-Gate hat reproduzierbare Lücken.**
Fundort: validators/checks/adr02_imports.py:37–59.
Es werden ausschließlich *.ts gescannt. Relative Cross-Modul-Erkennung versteht im Wesentlichen nur ../anderesModul/....
Gegenproben: Eine verbotene Cross-Modul-Abhängigkeit in cross.tsx → PASS. Eine .ts in person/sub/ mit ../../rbac/... → ebenfalls PASS. import type in der derzeit erkannten Form wird dagegen erfasst. Absolute .../modules/<name>/... werden teilweise erfasst, aber Resolver-/Barrel- und Template-Literal-Wege bleiben problematisch.
Empfehlung: TypeScript-Modulresolver verwenden und den aufgelösten realen Zielpfad prüfen – für .ts, .tsx, .mts, .cts, JS/JSX sowie tsconfig-Aliase und Re-Exports/Barrels.

**9. HOCH — Das Pseudonymisierungs-Gateway garantiert keinen PII-freien Modell-Request und ist nicht technisch vorgeschaltet.**
Fundort: apps/worker/src/agents/gateway.ts:13–49, apps/worker/src/index.ts.
Das Gateway erkennt nur E-Mail, AT-IBAN, Datum, 10-stellige Zahlenfolge und Telefon.
Beleg/Reproduktion: "Max Mustermann, Hauptstraße 12, 1010 Wien" passiert assertNoPii() unbeanstandet. Außerdem gibt es im restlichen Worker derzeit keinen Aufruf von pseudonymize() oder assertNoPii(); der Worker importiert das Gateway nicht. Der Outbox-Loop verarbeitet Topics unabhängig davon.
Empfehlung: Es darf nur einen technischen Modell-Client geben, und dieser muss das Gateway zwingend aufrufen. Direkter Provider-/HTTP-Zugriff außerhalb dieses Layers verbieten. Strukturierte Daten-Allowlist statt allein Regex-Pseudonymisierung; zusätzliche Erkennung insbesondere für Namen/Adressen/vereinsbezogene Identifikatoren.

**10. HOCH — Gate-Evidenz wird nur auf „Datei existiert" geprüft; die vorhandene Compose-Evidenz ist zudem veraltet.**
Fundort: validators/checks/evidence.py:6–20.
Der Validator macht tatsächlich nur (REPO / path).exists().
Gegenprobe: Eine Gate-Evidenz wurde durch .gitignore ersetzt. Ergebnis: ADR-09 PASS / gesamtes Gate GRÜN.
Zusätzlich widerspricht das mitgelieferte evidence/stage-0/compose-config.txt dem aktuellen Compose: aktuell verwendet der Worker WORKER_DATABASE_URL. Der gespeicherte Compose-Dump zeigt für den Worker dagegen noch DATABASE_URL mit vv_app.
Empfehlung: Evidenztyp, Pfad, Commit-ID, Erstellzeitpunkt und Hash erfassen. Nur Dateien unter einem definierten Evidence-Pfad zulassen; Inhalt pro Evidence-Typ validieren. CI soll Evidenz neu erzeugen und bei Abweichung vom geprüften Commit fehlschlagen.

**11. HOCH — Der CI-Gate beweist weder die Worker-Securitytests noch einen laufenden 5-Dienste-Stack.**
Fundort: .github/workflows/ci.yml:90–106; docs/bausteine/STAGE-0.md: „Wie getestet".
Beim Worker führt CI npm ci und npm run typecheck aus – nicht npm test. Unmittelbar danach wird lediglich docker compose config ausgeführt. Das Stage-0-Dossier nennt docker compose up hingegen als Akzeptanzbedingung, während die beschriebene Evidenz nur die normalisierte Compose-Konfiguration nennt.
Empfehlung: Worker-Tests gate-blockierend ausführen. Zusätzlich docker compose up --wait gegen frischen Zustand und echte Smoke-Tests: PostgreSQL/Migrationen, Keycloak-Realm + Tokenfluss, /api/me, MinIO-CRUD, Worker-Heartbeat und Outbox. Danach docker compose down -v.
Einschränkung dieses Prüflaufs: Docker/PostgreSQL stehen in meiner Ausführungsumgebung nicht zur Verfügung; ich konnte daher den mitgelieferten behaupteten Full-Stack-Lauf nicht unabhängig wiederholen. Der mitgelieferte Validator-Report behauptet einen Live-DB-Lauf, aber keinen aktuellen 5-Service-Runtime-Nachweis.

**12. HOCH — Outbox-Idempotenz schützt die Erzeugung eines Events, nicht zuverlässig dessen Verarbeitung.**
Fundort: db/migrations/0003_audit_outbox.sql:81–117.
(tenant_id, idempotency_key) ist zwar eindeutig, aber der Consumer erhält lediglich eine zeitbasierte Lease. vv_outbox_done(p_id) benötigt anschließend nur die UUID und prüft weder Lease-Generation noch Worker-/Claim-Token.
Beleg: Läuft Verarbeitung länger als eine Minute, kann Worker B denselben Eintrag neu claimen, während Worker A anschließend immer noch done(id) ausführen kann. Für zukünftige externe Side Effects ist damit keine robuste Delivery-Idempotenz/Fencing-Garantie vorhanden.
Empfehlung: Claim-ID/Lease-Generation zurückgeben und done(id, claim_token) nur für die aktuelle Lease erlauben; Lease heartbeat; externe Side Effects zwingend mit dem Outbox-Idempotency-Key idempotent machen.

**13. MITTEL — ADR-09 prüft die semantische Projektwahrheit nicht vollständig.**
Fundort: project/schema/project.schema.json bei tenant_scoped; validators/checks/project_recon.py:10–41.
Das Schema verlangt bei Tabellen lediglich einen Boolean tenant_scoped. Der Recon-Validator vergleicht anschließend nur Tabellennamen mit den Migrationen; er gleicht tenant_scoped nicht mit einer tatsächlichen tenant_id-Spalte ab. Zudem versteht sein SQL-Regex keine quoted identifiers.
Gegenproben: person im Fragment auf tenant_scoped:false gesetzt → alle ADR-09-Prüfungen PASS. Eine zusätzliche CREATE TABLE "evil_tenant" (... tenant_id ...) wurde von den statischen ADR-01/ADR-09-Regexen ebenfalls nicht erkannt.
Der Merge selbst prüft dagegen tatsächlich auf doppelte Tabelleneigentümer.
Empfehlung: Projektwahrheit gegen den effektiven DB-Katalog abgleichen: Tabellen, Spalten, Tenant-Scoped-Status und Eigentümer. SQL-Namen nicht per vereinfachtem Regex parsen.

**14. MITTEL — K29 prüft „Evidenz in Abschnitt 5" nicht tatsächlich.**
Fundort: validators/checks/k29_dossier.py:47–79, 82–100.
Es werden die neun ## n.-Überschriften gesucht. Danach genügt aber irgendein Markdown-Link irgendwo im Dokument, dessen URL "evidence/" enthält. Bei status=skeleton wird zudem bewusst kein echter Abschnittsinhalt verlangt.
Gegenproben: Evidenzlink aus Abschnitt 5 entfernt und in Abschnitt 1 verschoben → K29 PASS. Die konkret angefragte Teilüberschriften-Umgehung wurde dagegen korrekt erkannt: Änderung ## 4. → ### 4. führte zu K29 FAIL / Gate ROT.
Empfehlung: Dokument in echte Abschnittsbereiche parsen und Evidenzlink ausschließlich innerhalb von §5 akzeptieren; Abschnittstitel und semantische Mindestinhalte je Gate/Status prüfen.

**15. MITTEL — Supply-Chain-Härtung ist bewusst noch offen, obwohl CI ein Freigabe-Gate darstellt.**
Fundort: .github/workflows/ci.yml:1–2 sowie die uses:-Einträge.
Der Code enthält selbst das TODO, Actions auf Commit-SHA und Images auf Digest zu pinnen.
Beleg: Actions werden beispielsweise über actions/checkout@v4.2.2 und gitleaks/gitleaks-action@v2, Container über Tags referenziert. Ein veränderter Upstream-Tag verändert damit potentiell das Gate ohne Änderung des VV-Commits.
Empfehlung: Actions auf vollständige Commit-SHAs, Container auf Digests pinnen; automatisierten kontrollierten Update-Prozess etablieren.

## Gegenprobe gemäß Prüfpunkt 10

Die absichtlich eingebauten Verletzungen ergaben:

| Verletzte Invariante | Erwartung | Tatsächliches Ergebnis |
|---|---|---|
| approval-RLS auf USING(true) | ROT | GRÜN |
| verbotener Cross-Modul-Import in .tsx | ROT | GRÜN |
| Cross-Modul-Import über ../../rbac | ROT | GRÜN |
| wirkungsloser Policy-Guard | ROT | GRÜN |
| dynamisch zusammengesetztes DELETE außerhalb Action | ROT | GRÜN |
| personenbezogene CSV ohne Mail/IBAN | ROT | GRÜN |
| autorisierte Mutation ohne Audit | ROT | GRÜN |
| .gitignore als Gate-Evidenz | ROT | GRÜN |
| tenant_scoped:false trotz tenant_id | ROT | GRÜN |
| K29-Evidenzlink in falschem Abschnitt | ROT | GRÜN |
| K29 ## 4. zu ### 4. | ROT | ROT |

Damit ist der im Prüfauftrag geforderte Negativtest eindeutig nicht erfüllt: mehrere echte Invariantenverletzungen führen nicht zu Exit ≠ 0.

## Abdeckung der zehn vorgegebenen Prüfpunkte

| Prüfpunkt | Ergebnis |
|---|---|
| 1 ADR-01 RLS | nicht erfüllt – Befunde 3, 7, 13 |
| 2 ADR-02 Imports | nicht erfüllt – Befund 8 |
| 3 ADR-04 Policy | policy.ts selbst ist deny-by-default; Erzwingung nicht erfüllt – Befund 2 |
| 4 ADR-05 Audit/Outbox | Hash-Aufbau/Append-only ohne zusätzlichen konkreten Defekt; Audit-Vollständigkeit und Consumer-Idempotenz nicht erfüllt – 5, 12 |
| 5 ADR-06/07 Worker/Vier-Augen/Gateway | nicht erfüllt – 1, 6, 9 |
| 6 ADR-09 Projektwahrheit | Ein-Eigentümer-Merge vorhanden; Semantik/Evidenz nicht ausreichend – 10, 13 |
| 7 K29 Dossier | teilweise erfüllt, aber Abschnitt-5-Evidenz umgehbar – 14 |
| 8 K31/ADR-10 | nicht erfüllt – 4 |
| 9 Betrieb | nicht vollständig nachgewiesen – 10, 11, 15 |
| 10 Negativtest | nicht erfüllt – zahlreiche absichtliche Verletzungen bleiben grün |

Der Prüfauftrag verlangt bei sicherheitskritischen Befunden die Vorlage beim Betreiber statt einer automatischen Reparaturrunde. Mit den blockierenden Befunden oben ist daher keine Stage-0-Freigabe auf Basis dieses Prüfstands gerechtfertigt; das formale Urteil lautet nicht bestanden.
