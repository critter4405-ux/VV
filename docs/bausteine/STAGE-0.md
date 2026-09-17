# Bau-Dossier — VV-STAGE-0 · Startpaket-Harvest (Fundament-Gerüst)

> **Kurz-Bau-Dossier Stage 0.** 9-teilige Vorlage (K29). Dokumentiert das geprüfte
> Bau-Gerüst, gegen das danach jedes Modul gebaut wird. **Kein Modul-Bau, keine echten Daten.**

## 1. Kopf

- **Code:** VV-STAGE-0
- **Name:** Startpaket-Harvest — Fundament-Infrastruktur
- **Version:** 1.0
- **Datum:** 16.09.2026
- **Verantwortlich:** Bau-KI (Claude Code + Opus 4.8, Aufwand hoch) · Review = Fremdmodell (Aufwand hoch)
- **Status/Gate:** gebaut · **Gate 0 → 1** (Validatoren grün)

## 2. Was

Erzeugt wurde das **Bau-Gerüst** nach Profil „Standard". **Hinweis:** Das VEREVIA-Startpaket
**existiert noch nicht** (16.09.2026) — das Gerüst wurde daher **direkt zur entschiedenen Spec**
(ADR-01…11, ADR-09, K29) gebaut; das Ergebnis entspricht dem, was ein Harvest nach dem Strippen
ergäbe. Umgestellt auf **VV/AT/Linux/Python**:

- **Monorepo** mit einem Migrations-Set: `apps/web` (modularer Monolith), `apps/worker`
  (Agenten-/Job-Worker), `db/migrations`, `db/seed` (nur synthetisch).
- **`docker compose`-Stack:** Web/API + Worker + Postgres + Keycloak + MinIO.
- **`project.json` in Fragmenten** je Baustein (13 Fragmente) + **JSON-Schema** + Merge-Schritt.
- **Python-Validatoren**, die die ADR-Invarianten **gate-blockierend** erzwingen.
- **ADR-01…11 als Referenz-Fragmente** (`docs/adr`) + **Bau-Dossier-Skeletons** (9 Abschnitte) je Baustein.
- **CI (GitHub)**: Build + Validatoren, **nur synthetische Daten**.
- **Doku-Pipeline** (`scripts/build_html.py`, `fix_lists.py`, `mermaid.min.js`).

**Nicht** gebaut (Nicht-Ziele): Fachmodule (M##), Agenten-Fachlogik, Live-Bank/SEPA, Prod-Deploys, echte Daten.

## 3. Warum so

Grundgerüst-Profil „Standard" (K17/K28). Das VEREVIA-Startpaket („Erstversuch, IP = Betreiber")
war als Harvest-Quelle vorgesehen, **existiert aber noch nicht** — daher zur entschiedenen Spec
gebaut statt geerntet (Inhalte wären ohnehin gestrippt worden). Die 10 VEREVIA-Architekturpunkte
sind über ADR-01…11 bereits **neu entschieden** → [ADR-01…11](../adr/ADR-01.md) (K30/K33); die
VEREVIA-Formulierung in K17/K28 ist als offene Frage vermerkt (Register). Ebenentrennung:
Register = Mensch · `project.json` = Maschine · ADR = Architektur.

## 4. Wie umgesetzt

- **Mandantentrennung (ADR-01):** `tenant_id` + Postgres-RLS + Policy je Tabelle; App-Rolle ohne BYPASSRLS.
- **Modularer Monolith (ADR-02):** Modulgrenzen, kein Cross-Modul-Import; Worker getrennt.
- **Policy-Prüfpunkt (ADR-04):** `apps/web/src/platform/policy.ts`, deny-by-default; jede `*.action.ts` geht hindurch.
- **Audit/Events (ADR-05):** Hash-Ketten-Audit + Transactional-Outbox (`db/migrations/0003`).
- **Jobs (ADR-06):** pg-boss im Worker, idempotent.
- **Agenten (ADR-07):** Vier-Augen-Automat + Pseudonymisierungs-Gateway (Struktur/Guards).
- **Projektwahrheit (ADR-09):** Fragmente + Schema + Validatoren.
- Grenzen: reines Gerüst; keine Fachlogik, keine echten Daten.

## 5. Wie getestet

Validatoren lokal ausgeführt, alle Gates grün; Compose-Konfiguration normalisiert geprüft.
Evidenz: [../../evidence/stage-0/gate0-checklist.md](../../evidence/stage-0/gate0-checklist.md) ·
[Validator-Report](../../evidence/stage-0/validator-report.json) ·
[Compose-Config](../../evidence/stage-0/compose-config.txt)

Akzeptanz (Gate 0→1): `docker compose up` startet den Stack · Validatoren lokal **und** CI grün ·
Fragmente+Schema valide · ADR-Fragmente im Repo · Dossier-Skeletons je Baustein · CI nur synthetisch.

## 6. Sicherheit & Datenschutz

- **100 % AT-Datensouveränität**, kein US-Dienst im Datenpfad; host-agnostisch.
- **Kein Personenbezug im Repo/CI** (Guard-Validator K31); nur synthetische Testdaten.
- Bindendes nie autonom: Freigabe-Objekt (Vier-Augen), lückenloses Audit ab Tag 1 (K31).

## 7. Visual (Pflicht)

```mermaid
flowchart TB
    subgraph HARVEST["Profil Standard (Spec) — VEREVIA-Startpaket existiert noch nicht"]
      V["Standard:<br/>project.json + Schema + Validatoren + ADR"]
    end
    subgraph VV["VV-Fundament-Gerüst (AT/Linux/Python)"]
      REPO["Monorepo<br/>apps/web + apps/worker"]
      DB["Postgres<br/>RLS + Hash-Audit + Outbox"]
      KC["Keycloak (OIDC/2FA)"]
      OBJ["MinIO (S3)"]
      PT["project.json-Fragmente + Schema"]
      VAL["Python-Validatoren<br/>(gate-blockierend)"]
      CI["GitHub CI<br/>nur synthetisch"]
    end
    V -->|zur Spec bauen| REPO
    REPO --> DB
    REPO --> KC
    REPO --> OBJ
    PT --> VAL
    VAL --> CI
    VAL -->|Gate 0→1| GATE["grün ⇒ Module baubar"]
```

## 8. Nutzen in Klartext

Ab jetzt gibt es ein **geprüftes, sich selbst kontrollierendes Bau-Fundament**: Jedes künftige
Modul wird gegen dieselben harten Regeln gebaut (Mandantentrennung, ein Policy-Prüfpunkt,
lückenloses Audit, Vier-Augen, vollständige Doku). Fehler fliegen automatisch am Gate auf,
bevor etwas live geht — Echtbetrieb-Disziplin ab dem ersten Baustein.

## 9. Änderungshistorie

- 16.09.2026 — Stage 0 gebaut (Startpaket-Harvest); K22 auf „Bau gestartet/Stage 0".
