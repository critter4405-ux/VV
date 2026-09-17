# ADR-06 — Jobs / Hintergrundverarbeitung

> **Referenz-Layer.** Kanonische Fassung: Projektdokument **VV — ADR-Fundament v1.1** (Register K30/K33).
> Dieses Fragment ist die knappe Repo-Referenz; es dupliziert die Begründung nicht.

- **Status:** entschieden (10.09.2026)
- **Ebene:** Architektur (ADR) — `project.json` verweist hierauf, das Register führt die Strategie.

## Entscheidung (Kurz)

**Postgres-Job-Queue (pg-boss)**: Retries/Backoff, Dead-Letter, Cron; **idempotent**; kein Redis/Broker.

## Erzwungene Invariante (Stage 0)

Kein Job überschreitet autonom eine harte Grenze — er bereitet vor und legt ein Freigabe-Objekt an.

## Referenzen

- Register: K30 (10 ADRs), K33 (Echtbetrieb-Härtung), K28 (VEREVIA-Harvest).
- Validatoren: `validators/` (gate-blockierend, ADR-09).
