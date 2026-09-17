# ADR-04 — Autorisierung / Policies

> **Referenz-Layer.** Kanonische Fassung: Projektdokument **VV — ADR-Fundament v1.1** (Register K30/K33).
> Dieses Fragment ist die knappe Repo-Referenz; es dupliziert die Begründung nicht.

- **Status:** entschieden (10.09.2026)
- **Ebene:** Architektur (ADR) — `project.json` verweist hierauf, das Register führt die Strategie.

## Entscheidung (Kurz)

Kontextbezogenes **RBAC** im App-Layer, deny-by-default, **ein zentraler Prüfpunkt**, SoD bei der Zuweisung; RLS bleibt der Mandanten-Boden.

## Erzwungene Invariante (Stage 0)

Keine Aktion umgeht den zentralen Policy-Prüfpunkt (Validator ADR-04).

## Referenzen

- Register: K30 (10 ADRs), K33 (Echtbetrieb-Härtung), K28 (VEREVIA-Harvest).
- Validatoren: `validators/` (gate-blockierend, ADR-09).
