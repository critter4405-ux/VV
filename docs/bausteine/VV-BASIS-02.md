# Bau-Dossier — VV-BASIS-02 · Rollen & Rechte

> **Skeleton (Stage 0).** 9-teilige Vorlage (K29). Die Bau-KI füllt die Abschnitte beim
> Modul-/Baustein-Bau aus; Prüf-KI + Validator erzwingen Vollständigkeit (Gate-Sperre).
> **Kein Bau-Inhalt bis zur Baustein-Freigabe.**

## 1. Kopf

- **Code:** VV-BASIS-02
- **Name:** Rollen & Rechte
- **Version:** 0.1 (Skeleton)
- **Datum:** 16.09.2026
- **Verantwortlich:** Bau-KI (Claude Code + Opus 4.8) · Prüf-KI (Fremdmodell)
- **Status/Gate:** Skeleton · Gate 0

## 2. Was

*(zu füllen beim Bau)* Ziel dieses Bausteins: Steuern, wer was sehen und tun darf — least privilege, deny-by-default.

## 3. Warum so

*(zu füllen beim Bau)* Hintergrund/Alternativen → ADR-Verweis: [ADR-04](../adr/ADR-04.md), [ADR-01](../adr/ADR-01.md)

## 4. Wie umgesetzt

*(zu füllen beim Bau)* Architektur, Datenmodell, Schnittstellen, Grenzen. Referenz: [ADR-04](../adr/ADR-04.md), [ADR-01](../adr/ADR-01.md)

## 5. Wie getestet

*(zu füllen beim Bau)* Testarten, Ergebnisse/Evidenz-Verweise, Akzeptanzkriterien.
Evidenz: [../../evidence/stage-0/gate0-checklist.md](../../evidence/stage-0/gate0-checklist.md)

## 6. Sicherheit & Datenschutz

*(zu füllen beim Bau)* Kontrollen, Datenklassen (Ö/S/Se/F-Buch/F-Bank/A9), Freigaben.

## 7. Visual (Pflicht)

```mermaid
flowchart LR
    P["Problem"] --> L["VV-BASIS-02<br/>Lösung"]
    L --> N["Nutzen"]
```

## 8. Nutzen in Klartext

Sichere, nachvollziehbare Zugriffe inkl. Funktionstrennung (Kassier ≠ Kassaprüfer).

## 9. Änderungshistorie

- 16.09.2026 — Skeleton angelegt (Stage 0 Startpaket-Harvest).
