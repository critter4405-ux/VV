# Bau-Dossier — VV-BASIS-03 · Governance & Audit-Log

> **Skeleton (Stage 0).** 9-teilige Vorlage (K29). Die Bau-KI füllt die Abschnitte beim
> Modul-/Baustein-Bau aus; Prüf-KI + Validator erzwingen Vollständigkeit (Gate-Sperre).
> **Kein Bau-Inhalt bis zur Baustein-Freigabe.**

## 1. Kopf

- **Code:** VV-BASIS-03
- **Name:** Governance & Audit-Log
- **Version:** 0.1 (Skeleton)
- **Datum:** 16.09.2026
- **Verantwortlich:** Bau-KI (Claude Code + Opus 4.8) · Prüf-KI (Fremdmodell)
- **Status/Gate:** Skeleton · Gate 0

## 2. Was

*(zu füllen beim Bau)* Ziel dieses Bausteins: Ausnahmslose, unveränderbare Protokollierung + Freigabe-Register (Hash-Kette, Outbox).

## 3. Warum so

*(zu füllen beim Bau)* Hintergrund/Alternativen → ADR-Verweis: [ADR-05](../adr/ADR-05.md)

## 4. Wie umgesetzt

*(zu füllen beim Bau)* Architektur, Datenmodell, Schnittstellen, Grenzen. Referenz: [ADR-05](../adr/ADR-05.md)

## 5. Wie getestet

*(zu füllen beim Bau)* Testarten, Ergebnisse/Evidenz-Verweise, Akzeptanzkriterien.
Evidenz: [../../evidence/stage-0/gate0-checklist.md](../../evidence/stage-0/gate0-checklist.md)

## 6. Sicherheit & Datenschutz

*(zu füllen beim Bau)* Kontrollen, Datenklassen (Ö/S/Se/F-Buch/F-Bank/A9), Freigaben.

## 7. Visual (Pflicht)

```mermaid
flowchart LR
    P["Problem"] --> L["VV-BASIS-03<br/>Lösung"]
    L --> N["Nutzen"]
```

## 8. Nutzen in Klartext

Jede Aktion ist manipulationssicher belegt — Grundlage für Vertrauen und Prüfung.

## 9. Änderungshistorie

- 16.09.2026 — Skeleton angelegt (Stage 0 Startpaket-Harvest).
- 24.09.2026 — **Sicherheits-Retrofit im M05-Bau** (Register P52, Bezug P48/P49; durch die M05-Freigabe gedeckt), Migration [0011](../../db/migrations/0011_security_retrofit.sql): Audit nur noch über `vv_audit_log` (Actor aus Kontext, kein Direkt-DML für App/Worker, R1) · Freigabe verlangt Fremdmodell-Attestation bei KI-Vorschlägen (R3) und Freigeber-Recht × Scope je Effekt über `approval_effect_permission`, unbekannte Effekte deny (R4) · Executor nur mit fest registrierten Handlern (R2) · Outbox-Claim nur für konsumierte Topics (R5) mit Lease-Fencing-Token (R8). Gegenproben in [ci_db_asserts.sh](../../scripts/ci_db_asserts.sh). Details: [VV-M05 §6a](VV-M05.md).
- 25.09.2026 — **Review Runde 2 (P54):** Outbox-Claim nur noch für Topics aus dem DB-Consumer-Register `outbox_consumer` (H-2); Fremdmodell-Attestation nur für bekannte Modellfamilien (H-1); `approval` mit Schlüssel `(tenant_id, id)` für mandantendichte Referenzen (N-1). Details: [VV-M05 §6b](VV-M05.md).
