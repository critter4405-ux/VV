# ADR-07 — Agenten-Laufzeit

> **Referenz-Layer.** Kanonische Fassung: Projektdokument **VV — ADR-Fundament v1.1** (Register K30/K33).
> Dieses Fragment ist die knappe Repo-Referenz; es dupliziert die Begründung nicht.

- **Status:** entschieden (10.09.2026)
- **Ebene:** Architektur (ADR) — `project.json` verweist hierauf, das Register führt die Strategie.

## Entscheidung (Kurz)

Erzwungener **Vier-Augen-Zustandsautomat** (Bau-Agent → Prüf-Agent anderer Modellfamilie → Freigabe → Mensch → Ausführung → Audit) + **Pseudonymisierungs-Gateway**; KI via externe EU-API (World4You), AT-Inferenz = Exoscale-Upgrade.

## Erzwungene Invariante (Stage 0)

Kein Klartext-Personenbezug ans Modell; keine verbindliche Ausführung ohne gültiges Freigabe-Token.

## Referenzen

- Register: K30 (10 ADRs), K33 (Echtbetrieb-Härtung), K28 (VEREVIA-Harvest).
- Validatoren: `validators/` (gate-blockierend, ADR-09).
