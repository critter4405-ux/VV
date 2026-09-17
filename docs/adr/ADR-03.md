# ADR-03 — Authentifizierung

> **Referenz-Layer.** Kanonische Fassung: Projektdokument **VV — ADR-Fundament v1.1** (Register K30/K33).
> Dieses Fragment ist die knappe Repo-Referenz; es dupliziert die Begründung nicht.

- **Status:** entschieden (10.09.2026)
- **Ebene:** Architektur (ADR) — `project.json` verweist hierauf, das Register führt die Strategie.

## Entscheidung (Kurz)

Dedizierter OIDC-Provider **Keycloak**; TOTP-2FA ab Start, MFA je Rolle erzwingbar; ID Austria später als Federation; technische Identitäten via Client-Credentials.

## Erzwungene Invariante (Stage 0)

App/Worker sind reine OIDC-Clients und sehen nie ein Passwort.

## Referenzen

- Register: K30 (10 ADRs), K33 (Echtbetrieb-Härtung), K28 (VEREVIA-Harvest).
- Validatoren: `validators/` (gate-blockierend, ADR-09).
