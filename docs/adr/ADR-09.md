# ADR-09 — Projektwahrheit

> **Referenz-Layer.** Kanonische Fassung: Projektdokument **VV — ADR-Fundament v1.1** (Register K30/K33).
> Dieses Fragment ist die knappe Repo-Referenz; es dupliziert die Begründung nicht.

- **Status:** entschieden (10.09.2026)
- **Ebene:** Architektur (ADR) — `project.json` verweist hierauf, das Register führt die Strategie.

## Entscheidung (Kurz)

**`project.json` in Fragmenten** je Baustein + JSON-Schema + **Python-Validatoren**, die ADR-01…08 + K29 + Evidenz gate-blockierend erzwingen (lokal + CI).

## Erzwungene Invariante (Stage 0)

Register referenziert, ADR referenziert — keine Doppelung; Merge-Schritt vor Validierung.

## Referenzen

- Register: K30 (10 ADRs), K33 (Echtbetrieb-Härtung), K28 (VEREVIA-Harvest).
- Validatoren: `validators/` (gate-blockierend, ADR-09).
