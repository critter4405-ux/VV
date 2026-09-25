# Evidenz — Gate M05 (Modul Mitglieder, Phase 1) — DoD-Checkliste (Bau-Auftrag v1.1 §4)

> **Stand:** 24.09.2026 · Bau-KI Claude Code + Opus 5.5 · **Gate gesperrt** bis Vier-Augen-Review (Codex + Gemini) und **Betreiber-Freigabe**. Die Bau-KI öffnet kein Gate.

| # | DoD-Punkt | Status | Nachweis |
|---|---|---|---|
| 1 | `project.json`-Fragment M05 schema-valide, konsistent mit Migrationen | erfüllt | [validator-report.json](validator-report.json) (Schema 14/14, Abgleich 26/26) · [VV-M05.project.json](../../project/fragments/VV-M05.project.json) |
| 2 | Migrationen idempotent, laufen gegen echte PostgreSQL 16 | erfüllt | [db-asserts.txt](db-asserts.txt) („Migrationen 0006–0011 idempotent") |
| 3 | RLS-Gegenprobe: ohne Kontext 0 Zeilen, A ≠ B | erfüllt | [db-asserts.txt](db-asserts.txt) (RLS, Mandantentrennung, Cross-Tenant-FK, fremder Worker) |
| 4 | Audit-Ketten-Eintrag je Zustandsänderung; append-only/TRUNCATE gesperrt | erfüllt | [db-asserts.txt](db-asserts.txt) (Kette verifiziert, Verlauf append-only) |
| 5 | Vier-Augen an Austritt/Löschung erzwungen + adversarial (spoof/forge/replay ROT) | erfüllt | [db-asserts.txt](db-asserts.txt) (Selbst-Freigabe, Fälschung, Parameter-Tausch, Replay, Rollenverlust, stale, expired) |
| 6 | Neue automatische Sicherheitstests in `ci_db_asserts.sh` / `selftest.py`, CI | erfüllt (lokal); CI-Lauf auf GitHub nach Push | [ci_db_asserts.sh](../../scripts/ci_db_asserts.sh) → [m05_db_asserts.py](../../scripts/m05_db_asserts.py) · Selbsttest 14/14 in [tests.txt](tests.txt) |
| 7 | Typecheck web/worker rc=0; Modul-Tests grün; `docker compose config` valide | erfüllt | [tests.txt](tests.txt) (Web 18/18, Worker 18/18); compose config valide (5 Dienste, unverändert) |
| 8 | Bau-Dossier 9-teilig, HTML, in Wissensbibliothek verlinkt | erfüllt | [VV-M05.md](../../docs/bausteine/VV-M05.md) · [VV-M05.html](../../docs/bausteine/VV-M05.html) · [Wissensbibliothek](../../docs/WISSENSBIBLIOTHEK.md) |
| 9 | Evidenz unter `vv/evidence/…` | erfüllt | dieser Ordner |
| 10 | Nur synthetische Daten (K31-Guard grün) | erfüllt | [validator-report.json](validator-report.json) (K31) · Seeds `db/seed/*` |
| 11 | Reparaturrunde 1 (R1–R8, G-1–G-3): je Fix gate-blockierende Gegenprobe, echte PG16 | erfüllt | [verification.md](verification.md) §Reparaturrunde 1 · M05 133/133, Stage-0 33/33 (Stand Runde 1) |
| 12 | Review Runde 2 (Codex GPT-6 Sol + Gemini): Befunde eingestuft, echte behoben, je Fix Gegenprobe (grün neu / rot alt) | erfüllt | [review-r2/einstufung.md](review-r2/einstufung.md) · M05 137/137, Stage-0 37/37 in [db-asserts.txt](db-asserts.txt) |

**Offen (nicht Bau-KI):** Bestätigungs-Review über den Stand nach Reparaturrunde 2 (Codex GPT-6 Sol, Live-Lauf) · Betreiber-Freigabe M05-Gate (Phase D). GitHub-Ruleset (R6) bei Remote-Anlage.
