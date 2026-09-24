# Review-Auftrag — Modul M05 „Mitglieder" (Vier-Augen, Fremdmodell)

> **Zweck:** Unabhängige Sicherheits- und Qualitätsprüfung von M05 Phase 1 (inkl. BASIS-02-Kern und zwei Stage-0-Nachhärtungen) durch **zwei Fremdmodelle**: GPT-5.x Codex (zuerst) und Gemini 3.x Pro, jeweils die neueste Version. Bau-KI (Claude Code + Opus 5.5) ≠ Prüf-KI.
> **Stand:** 24.09.2026 · Branch `feat/m05-mitglieder`, Commit siehe `git log -1` · **Intern — nur für den Betreiber.**
> **Rolle des Prüfers:** Du prüfst und meldest. Du reparierst nicht selbst und übernimmst die Nachweise der Bau-KI nicht, sondern wiederholst sie selbst.

## Prüfgegenstand

- **Migrationen:** `db/migrations/0006_rbac_core.sql` (BASIS-02-Kern), `0007_m05_schema.sql`, `0008_m05_functions.sql`, `0009_approval_insert_hardening.sql`; Seed `db/seed/0002_m05_synthetic.sql`.
- **App:** `apps/web/src/platform/policy.ts`, `apps/web/src/modules/mitglieder/*`, `apps/web/src/index.ts`.
- **Worker:** `apps/worker/src/jobs/m05.ts`, `apps/worker/src/index.ts`, `apps/worker/src/agents/effects.ts`.
- **Prüfwerkzeuge:** `validators/checks/adr01_rls.py`, `adr04_policy.py`, `validators/selftest.py`, `scripts/m05_db_asserts.py`, `scripts/ci_db_asserts.sh`, `.github/workflows/ci.yml`.
- **Doku/Evidenz:** `docs/bausteine/VV-M05.md`, `docs/bausteine/VV-BASIS-02.md`, `evidence/m05/*`, `project/fragments/VV-M05.project.json`, `project/mappings/vereinsplaner.v1.json`.
- **Spezifikation:** Baubuch v0.20 „VV-M05" (Steckbrief) · Register P50 (13 Entscheidungen) · Bau-Auftrag v1.1 · ADR-01…11.

## Reproduzierbarer Live-Lauf (Pflicht, unabhängig)

- **Codex (Docker, am besten in WSL):** aus dem Repo-Root `bash scripts/review_m05.sh`. Das Skript arbeitet read-only auf einer Temp-Kopie, startet eine frische PostgreSQL 16, spielt Migrationen + Seeds ein und führt Validatoren (LIVE), Selbsttest, DB-Gegenproben (Stage 0 + M05), Typechecks und Tests aus. Es liefert je Probe PASS/FAIL, das Urteil ziehst du.
- **Gemini (statisch):** Die Quelltexte liegen als nummerierte Bundle-Dateien bei (`VV_M05_Review_Teil1..3.md`). Bitte bestätige zuerst, dass jedes Bundle bis zur Endmarke `=== ENDE TEIL n ===` vollständig angekommen ist. Ohne vollständigen Upload ist kein Befund zu „fehlenden/abgeschnittenen" Dateien zulässig.

## Prüfpunkte (mindestens)

1. **Mandantentrennung (ADR-01):** Hat jede neue Tabelle mit `tenant_id` ENABLE + FORCE RLS + Policy? Kann eine `SECURITY DEFINER`-Funktion (Eigentümer `vv_definer`, NOBYPASSRLS) Daten eines anderen Mandanten lesen oder schreiben? Sind alle FKs mandantendicht (zusammengesetzt)?
2. **Rechteprüfung (ADR-04, BASIS-02):** Gibt es einen Weg, eine M05-Wirkung ohne passende Rolle × Scope × Datenklasse zu erzielen: über die App, über direkte SQL als `vv_app`/`vv_worker` oder über eine Funktion ohne Prüfung? Ist deny-by-default überall gegeben (fehlender Actor/Tenant/Principal, Systemakteur, unbekannte Ressource, DB-Fehler)? Stimmt die Feldsicht (Ö/S/Se) mit dem Steckbrief überein (Trainer nur eigenes Team; Se nur Vorstand/Obmann/Kinderschutz; Export nie Se)?
3. **Rechte-Eskalation:** Kann jemand sich selbst oder anderen unzulässige Rollen verschaffen (`role_assignment`, `principal_link`, Selbst-Zuweisung, SoD-Kern, Umdeutung bestehender Zuweisungen, Nebenläufigkeit)?
4. **Vier-Augen (ADR-07):** Lässt sich eine Beendigung oder Anonymisierung ausführen ohne fremde, berechtigte, gültige, einmalige Freigabe? Prüfe gezielt: direkt eingefügte oder umgeschriebene `approval`-Zeilen, Antragsteller-Spoofing, Selbst-Freigabe, Parameter-Tausch nach der Freigabe, Replay, abgelaufene Freigabe, Freigeber ohne Recht, veralteter Antrag, konkurrierende Anträge, Auslösen von `m05.execute` über eine selbst eingefügte Outbox-Zeile.
5. **Zustandsautomat:** Sind nur die erlaubten Übergänge möglich, auch für Tabelleneigentümer und Definer-Funktionen? Kann `m05.ctx` missbraucht werden?
6. **Audit/Outbox (ADR-05/06):** Schreibt jede Zustandsänderung Audit + Outbox in derselben Transaktion? Enthalten Audit- oder Outbox-Payloads Klartext-Personenbezug? Ist der Tagesjob idempotent und nebenläufigkeitsfest (`FOR UPDATE SKIP LOCKED`)?
7. **Datenschutz (K31, Q01):** Stimmen Aufbewahrung (mind. 7 J.), Sperre (Art. 18) und Anonymisierung? Bleibt die Hash-Kette intakt? Kommen echte Daten ins Repo? Enthält das Vereinsplaner-Mapping nur Spaltennamen?
8. **Import (Q05-Schnittstelle):** Ist der Import an die freigegebenen Zeilen gebunden (Hash, Anzahl)? Ist er idempotent und überschreibt nie? Gibt es Konflikt-Reports ohne Klartext?
9. **Validatoren/Tests:** Sind die Validator-Änderungen (ADR-01 Reihenfolge, ADR-04 je Aktion und Fachbefehle) korrekt oder umgehbar? Prüfen die Gegenproben das Behauptete wirklich (keine geschönten Nachweise)? Bleiben die Stage-0-Invarianten und -Gegenproben grün?
10. **Stage-0-Nachhärtung (Migration 0009, S0-1/S0-2):** Ist der Befund korrekt beschrieben und der Fix vollständig? Bricht er einen Stage-0-Pfad?
11. **Bau-Dossier (K29):** Sind die 9 Abschnitte vollständig, das Diagramm valide und die Evidenz-Links real?

## Rückgabe (Format)

- **Gesamturteil:** „bestanden" / „bestanden mit Auflagen" / „nicht bestanden".
- **Befundliste** nach Schweregrad **CRITICAL / HOCH / MITTEL / NIEDRIG**, je Befund: Fundort (Datei:Zeile), konkreter Reproduktionsweg (SQL/Request), erwartetes vs. tatsächliches Verhalten, Empfehlung.
- **Bestätigungen:** Welche Prüfpunkte hast du selbst live bzw. statisch nachvollzogen?
- Ausdrücklich **keine** Befunde aus unvollständigem Upload oder aus Pfad-/Umgebungsartefakten des Harness (diese getrennt als „Umgebung" melden).

## Weiteres Vorgehen

Die Befunde beider Prüfer werden in **einer** konsolidierten Reparaturrunde behoben (Bau-KI), gegen echte PostgreSQL 16 nachgewiesen und erneut geprüft, bis zur Konvergenz. Danach Vorlage beim Betreiber. **Die M05-Freigabe ist ausschließlich eine Betreiber-Entscheidung.**
