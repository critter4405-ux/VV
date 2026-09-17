# ADR-08 — Dateien / Storage

> **Referenz-Layer.** Kanonische Fassung: Projektdokument **VV — ADR-Fundament v1.1** (Register K30/K33).
> Dieses Fragment ist die knappe Repo-Referenz; es dupliziert die Begründung nicht.

- **Status:** entschieden (10.09.2026)
- **Ebene:** Architektur (ADR) — `project.json` verweist hierauf, das Register führt die Strategie.

## Entscheidung (Kurz)

**S3-kompatibel** (MinIO / Exoscale-SOS), Metadaten in Postgres, kurzlebige signierte URLs, at-rest-Verschlüsselung, **ClamAV-Upload-Scan**.

## Erzwungene Invariante (Stage 0)

Bytes im Objektspeicher, DB bleibt schlank; host-agnostisch ohne Codeänderung.

## Referenzen

- Register: K30 (10 ADRs), K33 (Echtbetrieb-Härtung), K28 (VEREVIA-Harvest).
- Validatoren: `validators/` (gate-blockierend, ADR-09).
