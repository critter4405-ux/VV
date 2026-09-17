# Evidenz — Gate 0 (Stage 0 Startpaket-Harvest)

Statische Evidenz-Verankerung für die Fundament-Bausteine. Der maschinelle Nachweis
(Validator-Report, Compose-Config-Dump) liegt zusätzlich in diesem Ordner und wird
bei jedem Lauf neu erzeugt.

- [x] Repo-Skeleton (Monorepo, ein Migrations-Set) vorhanden — `docker-compose.yml`, `apps/`, `db/`.
- [x] `project.json`-Fragmente + JSON-Schema vorhanden — `project/`.
- [x] Python-Validatoren gate-blockierend — `validators/`.
- [x] ADR-Fragmente im Repo (Referenz-Layer) — `docs/adr/`.
- [x] Bau-Dossier-Skeleton (9 Abschnitte) je Baustein — `docs/bausteine/`.
- [x] CI nur mit synthetischen Daten — `.github/workflows/ci.yml`, `db/seed/`.

Maschinelle Nachweise (bei Lauf erzeugt):

- `evidence/stage-0/validator-report.json` — Ergebnis aller Validatoren.
- `evidence/stage-0/compose-config.txt` — normalisierte Compose-Konfiguration (5 Dienste).
- `evidence/stage-0/db-rls-proof.txt` — realer PostgreSQL-16-Lauf: Migrationen + RLS-Isolationstest (AK-08).
