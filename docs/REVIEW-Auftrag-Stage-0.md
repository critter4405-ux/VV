# Review-Auftrag — Stage 0 (Vier-Augen, Fremdmodell)

> **Zweck:** Unabhängige Prüfung des Stage-0-Bau-Gerüsts durch **zwei Fremdmodelle**
> (Bau-KI ≠ Prüf-KI). **Freigegeben 17.09.2026 (P38):** GPT-5.3 Codex **und** Gemini 3.1 Pro,
> jeweils **neueste Version**. Die Bau-KI (Claude Code + Opus 4.8) prüft ihr eigenes Gerüst **nicht** selbst.
> **Intern — nur für den Betreiber.**

## Prüfgegenstand

Repo `C:\Projekte\VV_Claude\vv` (Stage 0 = Fundament-Gerüst, kein Modul, keine echten Daten).
Referenz: `docs/bausteine/STAGE-0.md`, `docs/adr/ADR-01…11.md`, Register (K22/K28/K29/K30/K33, P37/P38).

## Auftrag an das Prüfmodell

Prüfe **kritisch und adversarial**, ob das Gerüst die entschiedenen Invarianten wirklich erzwingt
(nicht nur behauptet). Suche Lücken, Umgehungswege und stille Annahmen. Gib je Befund an:
**Schweregrad** (blockierend / hoch / mittel / niedrig), **Fundort** (Datei:Zeile), **Beleg/Reproduktion**,
**Empfehlung**. Kein Lob, keine Zusammenfassung ohne Befunde.

## Prüfpunkte (mind. diese)

1. **ADR-01 Mandantentrennung / RLS**
   - Hat **jede** Tabelle mit `tenant_id` RLS **und** eine Policy? (`db/migrations/*.sql`)
   - Ist `FORCE ROW LEVEL SECURITY` gesetzt, App-Rolle **ohne** BYPASSRLS? Kann der Tenant-Kontext (`app.tenant_id`) umgangen werden?
   - Prüfe den Validator `validators/checks/adr01_rls.py` auf False-Negatives (z. B. Tabelle mit `tenant_id` in Kommentar, Mehrzeilen-DDL, Policy auf falscher Tabelle).
2. **ADR-02 Modularer Monolith / Cross-Modul-Imports**
   - Erkennt `adr02_imports.py` alle Umgehungen (Alias-Imports, `import type`, dynamische `import()`, Barrel-Dateien, absolute Alias-Pfade `@/…`)?
3. **ADR-04 Zentraler Policy-Prüfpunkt**
   - Kann eine Aktion an `checkPolicy()` vorbei DB-Schreibzugriff bekommen? Ist die `*.action.ts`-Konvention ausreichend, oder braucht es eine erzwungene Schnittstelle?
   - Ist `policy.ts` wirklich deny-by-default (Stage-0-Stub prüfen)?
4. **ADR-05 Audit / Outbox** — Hash-Kette korrekt (`prev+content`)? Append-only auf DB-Rollenebene wirksam? Outbox-Idempotenz?
5. **ADR-06/07 Worker / Vier-Augen / Gateway** — Verhindert `vier_augen.ts` verbindliche Ausführung ohne Freigabe (Antragsteller ≠ Freigeber)? Lässt das Pseudonymisierungs-Gateway PII durch (Muster, Rückweg, Guard)?
6. **ADR-09 Projektwahrheit** — Deckt das JSON-Schema die Fragmente? Erzwingt der Merge „ein Tabellen-Eigentümer"? Sind Gate-Evidenzen real existent?
7. **K29 Bau-Dossier** — Prüft der Validator wirklich alle 9 Abschnitte + Mermaid + Evidenz-Link? Umgehbar durch Teilüberschriften?
8. **K31/ADR-10 Datenschutz** — Kcommt echter Personenbezug ins Repo/CI durch? Ist der `synthetic_guard` zu lasch/zu streng?
9. **Betrieb** — `docker compose up` real getestet (Web/API+Worker+Postgres+Keycloak+MinIO healthy)? Keycloak-Realm-Import korrekt? CI-Jobs gate-blockierend?
10. **Gesamt** — Gegenprobe: absichtlich eine Invariante verletzen und prüfen, ob die Validatoren **rot** werden (Exit ≠ 0).

## Rückgabe & weiteres Vorgehen (Vier-Augen-Schleife)

- Befundliste (s. o.) je Modell, plus ein **Gesamturteil**: `bestanden` / `bestanden mit Auflagen` / `nicht bestanden`.
- Befunde gehen zurück an die **Bau-KI** (Reparatur), dann erneute Prüfung; **0 Reparaturrunden** bei sicherheitskritischen Befunden → sofort dem Betreiber vorlegen (B09-1).
- **Freigabe des Betreibers** erst nach grünem Vier-Augen-Ergebnis. Ergebnis + Evidenz nach `vv/evidence/stage-0/` und ins Register (neuer P-Eintrag).

## Modelle & Aufwand

- Prüf-KI 1: **GPT-5.3 Codex** (neueste Version) — Fokus Security/Infrastruktur.
- Prüf-KI 2: **Gemini 3.1 Pro** (neueste Version) — Fokus Monorepo-Gesamtanalyse (großer Kontext).
- Aufwand **hoch**. Belegt: mehrere Modelle parallel finden ~⅓ mehr Fehler.
