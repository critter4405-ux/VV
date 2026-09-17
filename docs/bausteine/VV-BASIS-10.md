# Bau-Dossier — VV-BASIS-10 · Identität & Authentifizierung

> **Skeleton (Stage 0).** 9-teilige Vorlage (K29). Die Bau-KI füllt die Abschnitte beim
> Modul-/Baustein-Bau aus; Prüf-KI + Validator erzwingen Vollständigkeit (Gate-Sperre).
> **Kein Bau-Inhalt bis zur Baustein-Freigabe.**

## 1. Kopf

- **Code:** VV-BASIS-10
- **Name:** Identität & Authentifizierung
- **Version:** 0.1 (Skeleton)
- **Datum:** 16.09.2026
- **Verantwortlich:** Bau-KI (Claude Code + Opus 4.8) · Prüf-KI (Fremdmodell)
- **Status/Gate:** Skeleton · Gate 0

## 2. Was

*(zu füllen beim Bau)* Ziel dieses Bausteins: Sichere Anmeldung: Keycloak-OIDC, TOTP/Passkeys, risikobasierte MFA-Pflicht, Intern-SSO.

## 3. Warum so

*(zu füllen beim Bau)* Hintergrund/Alternativen → ADR-Verweis: [ADR-03](../adr/ADR-03.md)

## 4. Wie umgesetzt

*(zu füllen beim Bau)* Architektur, Datenmodell, Schnittstellen, Grenzen. Referenz: [ADR-03](../adr/ADR-03.md)

## 5. Wie getestet

*(zu füllen beim Bau)* Testarten, Ergebnisse/Evidenz-Verweise, Akzeptanzkriterien.
Evidenz: [../../evidence/stage-0/gate0-checklist.md](../../evidence/stage-0/gate0-checklist.md)

## 6. Sicherheit & Datenschutz

*(zu füllen beim Bau)* Kontrollen, Datenklassen (Ö/S/Se/F-Buch/F-Bank/A9), Freigaben.

## 7. Visual (Pflicht)

```mermaid
flowchart LR
    P["Problem"] --> L["VV-BASIS-10<br/>Lösung"]
    L --> N["Nutzen"]
```

## 8. Nutzen in Klartext

Ein sicherer Login für alle Module — MFA dort, wo es das Risiko verlangt.

## 9. Änderungshistorie

- 16.09.2026 — Skeleton angelegt (Stage 0 Startpaket-Harvest).
