# Kalibrierung GPT-6 Sol als Prüf-KI — Auswertung (Blindtest an Stage 0)

> **Stand:** 24.09.2026 · **Auswertung:** Bau-KI Claude Opus 5.5 · **Entscheidung:** Betreiber (bestätigt 24.09.2026) · Register **P53**
> **Prüfstand:** Commit `bff8e58f45ca8a9607cb226edf1a3cbb04e8531b` („Stage 0 Reparaturrunde 2 (F1–F8)", 17.09.2026) = exakt der Stand, den GPT-5.6 Sol in Runde 3 geprüft hat. Blind exportiert (`git archive`, ohne `.git`, ohne spätere Commits/Hinweise); Prompt = damaliger Prüfauftrag `docs/REVIEW-Auftrag-Stage-0.md` wortgleich.
> **Prüfmodell:** GPT-6 Sol (OpenAI), statisch (keine Docker/PostgreSQL in der Prüfumgebung). Bericht: [bericht-gpt6sol.md](bericht-gpt6sol.md).
> **Antwortschlüssel:** `docs/REVIEW-Befunde-Stage-0.md`, Runde 3 (GPT-5.6 Sol: 1 CRITICAL + 4 HOCH + 2 MITTEL) — dem Prüfmodell nicht bekannt.

## Vollständigkeit

Vom Prüfmodell vor Befunden bestätigt: 3/3 Teile, 95/95 Dateien, SHA-256 je Datei gegen Manifest, Endmarke `BUNDLE COMPLETE: 95 FILES`. Kein Befund aus Upload-Artefakten.

## Treffer gegen den Schlüssel (Runde 3)

| Schlüssel | Schwere | Inhalt | GPT-6 Sol | Wertung |
|---|---|---|---|---|
| **G1** | **CRITICAL** | Vier-Augen über Metadaten-Spoofing (actionClass/state/approvedBy/token = Aufrufer-Daten; In-Memory-Token nach Neustart wiederverwendbar) | Befund 1 (BLOCKIEREND) — Kern exakt benannt inkl. Neustart/zweiter Worker, `assertTransition` ungenutzt | **Treffer (Pflichtbefund)** |
| G3 | hoch | ADR-04-Guard austricksbar (String-Decoy) | Befund 2 — anderer Trick derselben Lücke (`if (!decision.allowed) { if (false) return; }`), reproduziert, Gate grün | Treffer (gleichwertig) |
| G2 | hoch | ADR-02: dyn. `import(\`../${x}/…\`)` | Befund 8 — nur als „Template-Literal-Wege problematisch" erwähnt, keine Reproduktion | Teiltreffer |
| G4 | hoch | `vv_app` UPDATE/DELETE auf `outbox` (Zustellung unterdrückbar) | nicht gemeldet (Befund 6 nennt nur `approval`, obwohl beide in `0005_grants.sql:8`) | verfehlt |
| G5 | hoch | Guard loggt inneren Archiv-Dateinamen im Klartext | nicht gemeldet | verfehlt |
| G6 | mittel | SKIP im Report zugleich `passed=true` | nicht gemeldet | verfehlt |
| G7 | mittel | Mermaid-Prüfung kein echter Parser | nicht gemeldet | verfehlt |

**Summe Schlüssel:** CRITICAL 1/1 · HOCH 2,5/4 · MITTEL 0/2.

## Weitere Befunde — am Code `bff8e58` geprüft

| GPT-6 | Inhalt | Beleg am Prüfstand | Wertung | Später im Projekt |
|---|---|---|---|---|
| 6 | `vv_app` UPDATE/DELETE auf `approval`, Freigeber-String frei | `0005_grants.sql:8` | **echt** | = H1 (Runde 4) |
| 12 | Outbox-Lease ohne Fencing (`vv_outbox_done(p_id)` ohne Token) | `0003_audit_outbox.sql:114–116` | **echt** | = H-07/R8 (M05-Reparaturrunde 1) |
| 11 | CI: Worker nur Typecheck, kein `npm test`; kein Stack-Smoke | `ci.yml:99` | **echt** | Worker-Test in P45; Stack-Smoke = H-13 (Stage-1) |
| 15 | Actions/Images nicht auf SHA/Digest gepinnt | `ci.yml` `@v4.2.2` u. a. | **echt** | P47 |
| 2 (Teil) | Dynamisch zusammengesetztes DELETE außerhalb Action grün | Regex-Heuristik `adr04_policy.py:50–51` | **echt** | H-04 (Stage-1, TS-AST) |
| 3 | ADR-01/Live prüfen nur Policy-Existenz, nicht Semantik; `relrowsecurity` ungeprüft | `db_live.py:45–46` | **echt** | M-01 (Stage-1) |
| 4 | K31 erkennt nur IBAN/E-Mail, Binärformate übersprungen | `synthetic_guard.py:16–31` | **echt** | H-12 (Stage-1) |
| 8 | ADR-02: `.tsx`, `../../`-Pfade | `adr02_imports.py` | **echt** | H-08 (Stage-1) |
| 10 | Evidenz nur `exists()`; Compose-Evidenz veraltet | `evidence.py:17` | **echt** | H-10 (Stage-1) |
| 13 | Recon ohne Spalten-/tenant_scoped-Abgleich, keine quoted identifiers | `project_recon.py` | **echt** | H-09/M-02 (Stage-1) |
| 14 | K29-Evidenzlink nicht auf §5 beschränkt | `k29_dossier.py` | **echt** | H-11 (Stage-1) |
| 9 | Gateway regex-basiert, nirgends vorgeschaltet | kein Aufrufer in `apps/worker/src` | **echt (Residuum)** | H-01/B-04 (bis Agenten-Bau) |
| 5 | Audit nur Konvention (`writeAudit` freiwillig) | `audit.ts` | Design (Stage 0) | in M05 DB-seitig erzwungen; R1 |
| 7 | Tenant-Kontext als String an Modulfunktionen | `tenant.ts` | Design (Tenant aus verifiziertem JWT) | Stage-1-Kontext-Typisierung |

**Fehlalarme:** keine. Zwei Befunde (5, 7) sind bewusste Stage-0-Designkompromisse, sachlich zutreffend beschrieben.

## Vergleich mit GPT-5.6 Sol (Runde 3, gleicher Stand)

- GPT-5.6 Sol: 7 Befunde, davon alle 7 im Schlüssel (per Definition).
- GPT-6 Sol: 15 Befunde, 0 Fehlalarme; CRITICAL gefunden; 4 Schlüssel-Einzelfälle verfehlt (G4–G7), dafür **mind. 4 echte, damals übersehene Befunde** (H1, Lease-Fencing, fehlende Worker-Tests in CI, Supply-Chain), die erst in späteren Runden auftauchten, plus die komplette Validator-Lückenklasse (später H-04/H-08–H-12/M-01).
- Eigene adversariale Gegenproben (11 manipulierte Repos, 10 davon fälschlich grün) — hohe Prüftiefe am Gate.

## Urteil (Entscheidungsregel Kalibrierungsauftrag §4)

**BESTANDEN** — Pflichtbefund gefunden, Fehlalarme null. **GPT-6 Sol wird Codex-Prüfer für M05 Phase C und künftig** (Betreiber-Bestätigung 24.09.2026).

**Auflagen für den Einsatz:**

1. Einzelfall-Lücken (G4–G7 verfehlt) → **Gemini bleibt zweite, unabhängige Prüfinstanz** (Fremdfamilie, Vier-Augen unverändert).
2. Der Kalibrierungslauf war rein statisch → im M05-Review ist der **Live-Lauf `scripts/review_m05.sh` Pflicht**; Umgebungsprobleme getrennt melden.
