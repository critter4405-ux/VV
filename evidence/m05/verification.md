# M05 „Mitglieder" — Verifikation (Bau-KI, Phase B)

> **Stand:** 24.09.2026 · **Bau-KI:** Claude Code + Opus 5.5 · **Umgebung:** echte PostgreSQL 16.13, frisch aufgesetzt (Migrationen 0001–0009 + synthetische Seeds), wie CI-Job `db-integration`.
> **Wichtig:** Das hier ist der Nachweis der **Bau-KI**. Das unabhängige Vier-Augen-Review (Codex + Gemini) wiederholt die Prüfung selbst und übernimmt diese Nachweise **nicht**.

## Ergebnis auf einen Blick

- **DB-Gegenproben:** M05/BASIS-02 **115/115** + Stage-0-Sicherheitsproben **17/17** (inkl. neuer S0-1/S0-2) — [db-asserts.txt](db-asserts.txt), maschinenlesbar [db-asserts.json](db-asserts.json).
- **Validatoren LIVE:** alle 10 Checks PASS, `gate_passed=true` — [validator-report.json](validator-report.json).
- **Validator-Selbsttest:** 12/12 (5 neue Umgehungsproben) — [tests.txt](tests.txt).
- **Tests:** Web 17/17 (inkl. API end-to-end gegen DB), Worker 12/12 (inkl. Outbox → Worker → Wirkung genau einmal); Typecheck web/worker rc=0; `npm audit` 0; `docker compose config` valide (5 Dienste).

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
- **V-1 (mittel, Validator ADR-01):** Statement-Reihenfolge je Datei ignoriert → idempotentes `DROP POLICY IF EXISTS; CREATE POLICY` galt als fehlend. Fix: textuelle Reihenfolge; Selbsttest für beide Richtungen.
- **V-2 (mittel, Validator ADR-04):** nur der erste Guard je Datei geprüft; DB-Fachbefehle (`SELECT m05_…()`) nicht als Schreibzugriff erkannt. Fix: Prüfung je exportierter Aktion inkl. lokaler Helfer; Fachbefehle nur in `*.action.ts`. Selbsttest für 3 Umgehungen.

## Bewusst offen (dokumentiert, nicht Teil von M05 Phase 1)

- **Erziehungsberechtigten-Sicht:** braucht die BASIS-01-Beziehung → bis dahin deny-by-default.
- **Vereinsrollen (tenant-lokal), Delegation (B02-2), Super-Admin-Lesesicht (K10):** BASIS-02-Rest; bis dahin deny.
- **MFA-Pflicht je Rolle (B10-2):** `role_type.mfa_required` ist gesetzt; die Durchsetzung erfolgt in Keycloak/BASIS-10 (nicht Teil von M05).
- **Principal-Onboarding:** nur Betreiber-Pfad (Bootstrap-Funktion); Einladungsfluss mit BASIS-10.
- **BASIS-07-Konsument** der M05-Events und Finanzbezug der Frist (bis dahin konservativ 7 J.).
- **Import-Engine** (Staging/Dry-Run/Rollback, Werte-Mapping) = Sync/Q05; M05 liefert Schnittstelle + [Mapping v1](../../project/mappings/vereinsplaner.v1.json).
- **Stage-0-Executor** `executeBindingEffect` löst generische Freigaben weiterhin getrennt von der Wirkung ein (Stage 0 unverändert); M05 nutzt den atomaren DB-Pfad.
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
