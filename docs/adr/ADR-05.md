# ADR-05 — Audit & Events

> **Referenz-Layer.** Kanonische Fassung: Projektdokument **VV — ADR-Fundament v1.1** (Register K30/K33).
> Dieses Fragment ist die knappe Repo-Referenz; es dupliziert die Begründung nicht.

- **Status:** entschieden (10.09.2026)
- **Ebene:** Architektur (ADR) — `project.json` verweist hierauf, das Register führt die Strategie.

## Entscheidung (Kurz)

Append-only **Hash-Ketten-Audit** je Mandant + **Transactional-Outbox**; Kopf-Anchoring in Offsite-WORM (täglich/kritisch) + E-Mail-Zweitlinie.

## Erzwungene Invariante (Stage 0)

Audit ist append-only (kein UPDATE/DELETE); Event wird in derselben Transaktion wie die Datenänderung geschrieben.

## Referenzen

- Register: K30 (10 ADRs), K33 (Echtbetrieb-Härtung), K28 (VEREVIA-Harvest).
- Validatoren: `validators/` (gate-blockierend, ADR-09).
