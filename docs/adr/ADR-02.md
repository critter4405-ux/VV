# ADR-02 — Architekturform — modularer Monolith

> **Referenz-Layer.** Kanonische Fassung: Projektdokument **VV — ADR-Fundament v1.1** (Register K30/K33).
> Dieses Fragment ist die knappe Repo-Referenz; es dupliziert die Begründung nicht.

- **Status:** entschieden (10.09.2026)
- **Ebene:** Architektur (ADR) — `project.json` verweist hierauf, das Register führt die Strategie.

## Entscheidung (Kurz)

Ein Repo, eine DB, **ein Migrations-Set**, Web/API-Prozess + separater Agenten/Job-Worker; zustandslos.

## Erzwungene Invariante (Stage 0)

Keine verbotenen Cross-Modul-Imports; Modulzugriff nur über öffentliche Schnittstelle/Events (Validator ADR-02).

## Referenzen

- Register: K30 (10 ADRs), K33 (Echtbetrieb-Härtung), K28 (VEREVIA-Harvest).
- Validatoren: `validators/` (gate-blockierend, ADR-09).
