# M05 „Mitglieder" — Verifikation (Bau-KI, Phase B + Reparaturrunde 1)

> **Stand:** 24.09.2026 · **Bau-KI:** Claude Code + Opus 5.5 · **Umgebung:** echte PostgreSQL 16.13, frisch aufgesetzt (Migrationen 0001–0011 + synthetische Seeds), wie CI-Job `db-integration`.
> **Wichtig:** Das hier ist der Nachweis der **Bau-KI**. Das unabhängige Vier-Augen-Review (Codex + Gemini) wiederholt die Prüfung selbst und übernimmt diese Nachweise **nicht**.

## Ergebnis auf einen Blick

- **DB-Gegenproben:** M05/BASIS-02 **133/133** + Stage-0-Sicherheitsproben **33/33** (inkl. S0-1/S0-2 und Retrofit-Proben R1/R3/R4/R5/R8) — [db-asserts.txt](db-asserts.txt), maschinenlesbar [db-asserts.json](db-asserts.json).
- **Validatoren LIVE:** alle 10 Checks PASS (Tabellen-Abgleich 25/25 inkl. `approval_effect_permission`), `gate_passed=true` — [validator-report.json](validator-report.json).
- **Validator-Selbsttest:** 14/14 (inkl. R6: CI/CodeQL-Trigger auf realem Hauptbranch) — [tests.txt](tests.txt).
- **Tests:** Web 18/18 (inkl. API end-to-end gegen DB, Scope-Semantik R7), Worker 18/18 (inkl. R2/R3-Adversarial, G-1-Import-Andockung, R5-Topic-Filter, Outbox → Worker → Wirkung genau einmal); Typecheck web/worker rc=0; `npm audit` 0; `docker compose config` valide (5 Dienste).

## Akzeptanzkriterien (Steckbrief VV-M05)

| AK | Kriterium | Nachweis (Gegenprobe in `m05_db_asserts.py` bzw. Test) | Ergebnis |
|---|---|---|---|
| AK-01 | eigenes historisiertes Objekt; Wiedereintritt = neue Periode; max. 1 offene | „keine zweite offene Periode je Mitglied", Unique-Index `mp_one_open` | erfüllt |
| AK-02 | nur erlaubte Übergänge; Verlauf + Audit + Outbox in derselben Tx | „unerlaubter Übergang…", „DB-Automat…", „Statusverlauf automatisch", „Outbox-Events in derselben Transaktion" | erfüllt |
| AK-03 | Beendigung/Anonymisierung nur mit fremder, einmaliger, gültiger Freigabe | Selbst-Freigabe, Fälschung (S0-1), Spoofing (S0-2), ungebundene Freigabe, Parameter-Tausch, Replay, Rollenverlust, stale, expired, abgelehnt | erfüllt |
| AK-04 | Arten zweischichtig + versioniert, alte Versionen unveränderbar | „Regel-Versionen sind unveränderbar", „keine rückwirkende Regel-Version" | erfüllt |
| AK-05 | Kündigungsstichtag aus der Regel | „Kündigungsstichtag korrekt (6 Fälle)", „Stichtag aus Regel (Frist 1 M., Jahresende)" | erfüllt |
| AK-06 | Aging-up: genau ein Vorschlag, ohne Bestätigung kein Wechsel | „genau EIN Vorschlag…", „ohne Bestätigung ändert sich die Art NICHT", „Jugend ohne Geburtsdatum -> Hinweis-Event" | erfüllt |
| AK-07 | Feldsicht datenklassen-/scope-korrekt; Export nur berechtigt mit Zweck | Trainer nur eigenes Team, Se nur Vorstand/Obmann/Kinderschutz, Spieler: eigene S/Team Ö, Export ohne Zweck/Trainer ROT, Export nie Se | erfüllt |
| AK-08 | deny-by-default auch direkt an der DB | vv_app ohne Zugriff auf 8 Tabellen, ohne Actor/Tenant/Principal deny, keine Funktion für PUBLIC | erfüllt |
| AK-09 | SoD-Kern bei Zuweisung blockiert | „SoD-Kern… blockiert (Ergebnis statt Fehler)", „…auch direkten Eintrag", „versuchte SoD-Verletzung ist protokolliert" | erfüllt |
| AK-10 | keine Zugriffe über Mandantengrenzen | Mandant B sieht nichts, fremder Actor, fremde Periode, Cross-Tenant-FK, Worker im fremden Mandanten | erfüllt |
| AK-11 | Import idempotent, Konflikte gemeldet, nur mit Batch-Freigabe | ohne Freigabe/Selbstfreigabe ROT, Zeilen-Hash, Konflikte, gleicher Batch No-Op, neuer Batch idempotent | erfüllt |
| AK-12 | Aufbewahrung 7 J.; Anonymisierung entfernt Personenbezug, Kette intakt | Sperre/Frist-Jobs, Anonymisierungs-ANTRAG, Anonymisierung (Person/Nummer/Gründe entfernt, Daten auf Jahr), „Audit-Hash-Kette … verifiziert" | erfüllt |

## Im Bau entdeckte und geschlossene Befunde (für das Review ausdrücklich markiert)

- **S0-1 (hoch, Stage 0):** `vv_app` konnte eine Freigabe mit `status='approved'`, beliebigem `approved_by`, `decided_at` direkt **einfügen** (H1 hatte nur UPDATE gesperrt). Fix: Migration 0009, BEFORE-INSERT-Trigger normalisiert auf `pending`. Gegenprobe in `ci_db_asserts.sh` + `m05_db_asserts.py`.
- **S0-2 (mittel, Stage 0):** `requested_by` frei setzbar → Antragsteller-Spoofing umging die SoD. Fix: für die Web-Rolle `requested_by = app.actor` (Trigger). Gegenprobe wie oben.
- **S0-3 (mittel, Stage 0 × M05):** `vv_app` durfte beliebige Events in die Outbox schreiben → M05-/BASIS-02-Events (`m05.execute`, `m05.membership.ended`, …) fälschbar. Fix: Migration 0010, reservierte Topic-Präfixe nur aus den Fachfunktionen. Gegenprobe (3 Topics).
- **M-1 (hoch, eigener Bau, vor dem Review gefunden):** Das für `vv_app` lesbare Freigabe-Objekt (`approval.context`) enthielt die Antragsparameter im Klartext, darunter bei Ausschluss den Se-Grund. Fix: dort nur noch der Parameter-Hash; Parameter liegen im geschützten Antrag, Sicht nur feldgefiltert. Gegenproben: Kontext enthält nur Hash; Manipulation von Antrag **oder** Hash wird erkannt.
- **M-2 (mittel, eigener Bau):** Detailansicht zeigte gesperrte Perioden ohne Zweckangabe. Fix: gesperrt nur über Liste/Export mit Zweck. Gegenproben.
- **V-1 (mittel, Validator ADR-01):** Statement-Reihenfolge je Datei ignoriert → idempotentes `DROP POLICY IF EXISTS; CREATE POLICY` galt als fehlend. Fix: textuelle Reihenfolge; Selbsttest für beide Richtungen.
- **V-2 (mittel, Validator ADR-04):** nur der erste Guard je Datei geprüft; DB-Fachbefehle (`SELECT m05_…()`) nicht als Schreibzugriff erkannt. Fix: Prüfung je exportierter Aktion inkl. lokaler Helfer; Fachbefehle nur in `*.action.ts`. Selbsttest für 3 Umgehungen.

## Reparaturrunde 1 — Sicherheits-Retrofit (Register P52)

Verifiziert und eingestuft vor dem Fix (Betreiber bestätigt): R1–R6 echt · R7 teilweise echt (M05-Reads korrekt, Stage-0-Demo-Reads zu breit) · R8 echt, latent (bindende Wirkung durch Einmal-Consume geschützt) · G-1/G-2/G-3 echt · keine Dubletten zwischen Gemini und R1–R8 (G-1 nutzt den R5-Mechanismus). Je Fix eine gate-blockierende Gegenprobe:

| Befund | Gegenprobe (Datei) | Ergebnis |
|---|---|---|
| R1 Audit-Spoofing | 6 Proben in `ci_db_asserts.sh` (INSERT/OVERRIDING/Anchor/`vv_audit_write` verweigert, reservierte Aktion abgewiesen, Actor aus Kontext) · `policy.test.ts` | grün |
| R2 Executor mit Aufrufer-Handler | 4 adversariale Tests in `vier_augen.test.ts` | grün |
| R3 Attestation optional | 3 Proben in `ci_db_asserts.sh` (NULL-Reviewer, gleiche Familie, CHECK als Eigentümer) · `vier_augen.test.ts` | grün |
| R4 Freigabe ohne Rolle × Scope | 3 Proben `ci_db_asserts.sh` (Trainer, unbekannter Actor, Effekt ohne Zuordnung) + 2 in `m05_db_asserts.py` (Kassier freigeben/ablehnen direkt) | grün |
| R5 Quittung ohne Consumer | 2 Proben `ci_db_asserts.sh` (geparkt, NULL-Topics) · Worker-Integrationstest (`m05.membership.ended` bleibt geparkt) | grün |
| R6 CI-Trigger | 2 Proben `validators/selftest.py` (rot bei Entfernen von `master` nachgewiesen) | grün |
| R7 Policy-Scope | `policy.test.ts` R7 · 2 Proben `m05_db_asserts.py` (Trainer irgendwo ja / Wurzel nein; Obmann Wurzel ja) | grün |
| R8 Lease-Fencing | 1 Probe `ci_db_asserts.sh` (alter Token f/f/f, neuer t) | grün |
| G-1 Import nie ausgeführt | `m05_db_asserts.py` (Event bei Freigabe) · `m05.test.ts` (Handler, ohne Quelle Retry/DLQ) | grün |
| G-2 Savepoint je Zeile | `m05_db_asserts.py` (kein `EXCEPTION WHEN`; 3.005 Zeilen in 1 Tx, ungültige als Konflikt, 2,4 s) | grün |
| G-3 Re-Request-Loop | `m05_db_asserts.py` (Hold +12 M. via `m05_decide` und direkt; Audit `m05.retention.hold`; kein Folgeantrag) | grün |

## Bewusst offen (dokumentiert, nicht Teil von M05 Phase 1)

- **Erziehungsberechtigten-Sicht:** braucht die BASIS-01-Beziehung → bis dahin deny-by-default.
- **Vereinsrollen (tenant-lokal), Delegation (B02-2), Super-Admin-Lesesicht (K10):** BASIS-02-Rest; bis dahin deny.
- **MFA-Pflicht je Rolle (B10-2):** `role_type.mfa_required` ist gesetzt; die Durchsetzung erfolgt in Keycloak/BASIS-10 (nicht Teil von M05).
- **Principal-Onboarding:** nur Betreiber-Pfad (Bootstrap-Funktion); Einladungsfluss mit BASIS-10.
- **BASIS-07-Konsument** der M05-Events und Finanzbezug der Frist (bis dahin konservativ 7 J.).
- **Import-Engine** (Staging/Dry-Run/Rollback, Werte-Mapping) = Sync/Q05; M05 liefert Schnittstelle + [Mapping v1](../../project/mappings/vereinsplaner.v1.json).
- **Stage-0-Executor** (R2 behoben): nur fest registrierte Handler, Produktions-Registry leer; M05/Q05 ausschließlich über den atomaren DB-Pfad.
- **Q05-Zeilenquelle** für den angedockten Import (G-1): bis zum Q05-Bau endet ein freigegebener Import kontrolliert in Retry → DLQ (Technik-Eskalation), nie still quittiert.
- **GitHub-Ruleset/Required Checks** (R6): kein Remote gesetzt → TODO bei Remote-Anlage; Trigger-Abdeckung per Selbsttest erzwungen.
- **Supply-Chain:** Image-Digests weiterhin via `scripts/pin-images.sh` (Registry-Egress gesperrt, Stage-0-Residuum).

## Reproduzieren

```
# frische PostgreSQL 16, Migrationen + Seeds (siehe CI-Job db-integration), dann:
VV_PGHOST=localhost PW=change_me_dev_only bash scripts/ci_db_asserts.sh
VV_REPORT_DIR=evidence/m05 VV_VALIDATE_DSN="host=localhost dbname=vv user=vv_app password=…" VV_REQUIRE_LIVE=1 python3 -m validators.validate
python3 -m validators.selftest
(cd apps/web && DATABASE_URL=postgres://vv_app:…@localhost:5432/vv VV_REQUIRE_DB=1 npm test)
(cd apps/worker && DATABASE_URL=… WORKER_DATABASE_URL=postgres://vv_worker:…@localhost:5432/vv VV_REQUIRE_DB=1 npm test)
```
