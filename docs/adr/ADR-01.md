# ADR-01 — Mandantentrennung

> **Referenz-Layer.** Kanonische Fassung: Projektdokument **VV — ADR-Fundament v1.1** (Register K30/K33).
> Dieses Fragment ist die knappe Repo-Referenz; es dupliziert die Begründung nicht.

- **Status:** entschieden (10.09.2026)
- **Ebene:** Architektur (ADR) — `project.json` verweist hierauf, das Register führt die Strategie.

## Entscheidung (Kurz)

Shared Schema + `tenant_id` je mandantenbezogener Tabelle + **Postgres-RLS** (DB-Rolle ohne BYPASSRLS); DB-per-Verein als Option.

## Erzwungene Invariante (Stage 0)

Jede Tabelle mit `tenant_id` hat RLS aktiviert **und** mindestens eine Policy (Validator ADR-01).

## Referenzen

- Register: K30 (10 ADRs), K33 (Echtbetrieb-Härtung), K28 (VEREVIA-Harvest).
- Validatoren: `validators/` (gate-blockierend, ADR-09).
