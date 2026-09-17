# ADR-10 — Deployment / Betrieb

> **Referenz-Layer.** Kanonische Fassung: Projektdokument **VV — ADR-Fundament v1.1** (Register K30/K33).
> Dieses Fragment ist die knappe Repo-Referenz; es dupliziert die Begründung nicht.

- **Status:** entschieden (10.09.2026)
- **Ebene:** Architektur (ADR) — `project.json` verweist hierauf, das Register führt die Strategie.

## Entscheidung (Kurz)

**Docker Compose** auf World4You-vServer L+ (zustandslos), getrenntes Staging; **Prod mit echten Daten nur AT**; CI/CD auf GitHub nur mit **synthetischen** Daten.

## Erzwungene Invariante (Stage 0)

Kein Personenbezug im Repo/CI; Prod-Hosting ausschließlich AT.

## Referenzen

- Register: K30 (10 ADRs), K33 (Echtbetrieb-Härtung), K28 (VEREVIA-Harvest).
- Validatoren: `validators/` (gate-blockierend, ADR-09).
