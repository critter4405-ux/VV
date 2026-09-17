# VV — Fundament-Repo (Stage 0)

> **Intern — nur für den Betreiber.** Stage-0-Bau-Gerüst für „VV — Der vollautomatisierte Verein".
> Erzeugt im Bau-Start K22 (Stage 0 = Fundament-Infrastruktur). **Kein Modul-Bau. Keine echten/personenbezogenen Daten.**

Dieses Repo ist das **geprüfte Bau-Gerüst**, gegen das danach jedes Modul gebaut wird
(Startpaket-Harvest, Profil „Standard" — VEREVIA-Inhalte gestrippt, umgestellt auf VV/AT/Linux/Python).

## Leitplanken (nicht verhandelbar)

- **100 % AT-Datensouveränität** — kein US-Dienst im Datenpfad; host-agnostisch (Docker + Postgres + eigene Auth).
- **Echtbetrieb, nicht Pilot-Sparversion** (K31) — Strukturen/Compliance ab Tag 1 vollständig.
- **Vier-Augen** (Bau-KI ≠ Prüf-KI) + **Bau-Dossier** als harte DoD ab Baustein 1 (K29).
- **Nichts Bindendes ohne Freigabe**; lückenloses Audit-Prinzip.
- **Ebenentrennung:** Register = Mensch/Strategie · `project.json` = Maschine · ADR = Architektur.
- **CI/Repo nie mit echten/personenbezogenen Daten** — nur Code + synthetische Testdaten.

## Aufbau

| Pfad | Inhalt |
|---|---|
| `docker-compose.yml` | lokaler Stack: Web/API + Worker + Postgres + Keycloak + MinIO |
| `apps/web/` | modularer Monolith (Next.js/TS), zentraler Policy-Prüfpunkt (ADR-02/04) |
| `apps/worker/` | Agenten-/Job-Worker (pg-boss), Vier-Augen-Automat + Pseudonymisierungs-Gateway (ADR-06/07) |
| `db/migrations/` | **ein** Migrations-Set: RLS+Policies (ADR-01), Hash-Audit + Outbox (ADR-05), Job-Queue (ADR-06) |
| `db/seed/` | ausschließlich **synthetische** Testdaten |
| `project/schema/` | JSON-Schema der Projektwahrheit (ADR-09) |
| `project/fragments/` | `project.json` in Fragmenten je Baustein (ADR-09) |
| `validators/` | Python-Validatoren, die die ADR-Invarianten **gate-blockierend** erzwingen |
| `docs/adr/` | ADR-01…11 als Referenz-Layer-Fragmente |
| `docs/bausteine/` | Bau-Dossier je Baustein (9-teilige Vorlage, K29) + `STAGE-0.md` |
| `evidence/stage-0/` | Evidenz-Artefakte (Validator-Report, Compose-Check) |
| `scripts/` | Doku-Pipeline: `build_html.py`, `fix_lists.py`, `mermaid.min.js` |
| `.github/workflows/ci.yml` | CI: Build + Validatoren gate-blockierend, nur synthetische Daten |

## Schnellstart (lokal)

```bash
# 1) Stack starten (Gate-0-Nachweis)
cp .env.example .env
docker compose up -d          # Web/API + Worker + Postgres + Keycloak + MinIO

# 2) Validatoren gate-blockierend ausführen
python3 -m pip install -r validators/requirements.txt
python3 -m validators.validate            # Exit-Code != 0 blockt das Gate

# 3) Doku rendern
python3 scripts/build_html.py docs/bausteine/STAGE-0.md docs/bausteine/STAGE-0.html "Stage 0 — Startpaket-Harvest" "Bau-Log" "VV · intern"
```

## Definition of Done (Gate 0→1)

- [ ] `docker compose up` startet den Stack lokal (Web/API + Worker + Postgres + Keycloak + MinIO).
- [ ] Alle Python-Validatoren laufen lokal **und** in CI gate-blockierend grün.
- [ ] `project.json`-Fragmente + Schema vorhanden und valide; ADR-Fragmente im Repo.
- [ ] Bau-Dossier-Skeleton (9 Abschnitte) je vorhandenem Baustein angelegt.
- [ ] CI grün mit ausschließlich synthetischen Daten; kein Personenbezug im Repo/CI.
- [ ] Kurz-Bau-Dossier „Stage 0" + Evidenz verlinkt.

## Modelle (Bau-Governance)

- **Bau:** Claude Code + Opus 4.8 (Aufwand hoch).
- **Review/Prüfung:** Fremdmodell (GPT-5.3 Codex **oder** Gemini 3.1 Pro, Aufwand hoch) — Vier-Augen (Bau-KI ≠ Prüf-KI).
