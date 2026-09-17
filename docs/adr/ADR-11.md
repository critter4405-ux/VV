# ADR-11 — Betrieb & Ausfallsicherheit

> **Referenz-Layer.** Kanonische Fassung: Projektdokument **VV — ADR-Fundament v1.1** (Register K30/K33).
> Dieses Fragment ist die knappe Repo-Referenz; es dupliziert die Begründung nicht.

- **Status:** entschieden (10.09.2026)
- **Ebene:** Architektur (ADR) — `project.json` verweist hierauf, das Register führt die Strategie.

## Entscheidung (Kurz)

Backup/DR (PITR + Offsite-WORM + monatliche Restore-Drills, RPO≈Min/RTO≈Std), Monitoring/Alerting, **`sops`/`age`**-Secrets, Security-Baseline (OS-Härtung, least-priv DB, CI-Scan, IR + DSGVO-72h), Q07 = BSI/ISO-Baseline.

## Erzwungene Invariante (Stage 0)

Liefert die WORM-Senke für ADR-05-Kopf-Anchoring; kein Enterprise-HA (DR statt HA).

## Referenzen

- Register: K30 (10 ADRs), K33 (Echtbetrieb-Härtung), K28 (VEREVIA-Harvest).
- Validatoren: `validators/` (gate-blockierend, ADR-09).
