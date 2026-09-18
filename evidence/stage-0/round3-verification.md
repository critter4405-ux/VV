# Stage 0 — Verifikation Reparaturrunde 3 (gegen echte PostgreSQL 16)

> Reaktion auf das 3. Fremdmodell-Review: **Codex „nicht bestanden"** (1 CRITICAL + 4 HOCH + 2 MITTEL)
> und **Gemini „bestanden mit Auflagen"** (F6 grün; 2 Auflagen). Eine konsolidierte Runde (G1–G9),
> von der Bau-KI verifiziert. Freigabe des Gates erfordert erneutes Fremdmodell-Review + Betreiber-Freigabe.
> Umgebung: PostgreSQL 16.13, Node 22 (Typecheck/Test), Python 3.12. Nur synthetische Daten.

## G1 — Vier-Augen gegen Metadaten-Spoofing (Codex #1, CRITICAL)

Wurzel: `actionClass`/`state`/`approvedBy`/`token` waren Aufrufer-Daten. Fix: **Effekt-Registry**
(fixe Aktions-/Senken-Identität), **Executor** als einziger Pfad zu bindenden Senken, Freigabe
**atomar aus der DB** (`vv_consume_approval`: fremd-genehmigt, scope-gebunden, ablaufend, einmalig).

Unit-Adversarial-Test (`vier_augen.test.ts`):
```
# tests 7   # pass 7   # fail 0
```
deckt: Umetikettieren erreicht die Zahlungs-Senke nicht · erfundene Freigabe abgewiesen ·
Reviewer gleiche Modellfamilie abgewiesen · Replay ROT · abgelaufene Freigabe ROT · unbekannter
Effekt fail-closed.

An echter PostgreSQL (end-to-end):
```
vv_app legt Freigabe an + fremde Genehmigung (erlaubte Spalten):  status=approved approved_by=human-2 reviewer=gpt
vv_worker Consume #1:                                             t   (eingelöst)
vv_worker Consume #2 (Replay):                                    f   (nichts mehr einlösbar)
Selbst-Freigabe approved_by=requested_by:                         ERROR approval_four_eyes (CHECK)
vv_app SELECT vv_consume_approval(...):                           ERROR permission denied for function
vv_app UPDATE approval SET consumed_at=...:                       ERROR permission denied for table approval
```

## G4 — vv_app kann Outbox nicht mehr direkt unterdrücken (Codex #4)

```
vv_app UPDATE outbox ...:  ERROR permission denied for table outbox
vv_app DELETE FROM outbox: ERROR permission denied for table outbox
vv_app INSERT INTO outbox: erlaubt (Erzeugen bleibt Teil der Fach-Transaktion)
```
Status/Lease (`processed_at`/`locked_until`) ändert nur der Worker über die SECURITY-DEFINER-Funktionen.

## G2 — ADR-02 Template-Literal-Interpolation (Codex #2)

```
import(`../${forbiddenModule}/rbac.action.ts`)   -> ADR-02 ROT (nicht statisch prüfbar)
import(`./person.action.ts`)  (ohne ${})         -> nicht beanstandet (statisch)
```

## G3/G9 — ADR-04 String-Decoy + Destrukturierung (Codex #3, Gemini)

Längentreues Blanken: Guard/Decision auf strings-geblankter Quelle, Writes auf strings-erhaltener.
```
const decoy="if (!decision.allowed){return;}"; DELETE   -> ADR-04 ROT (Guard nur im String)
const { allowed } = checkPolicy(...); if(!allowed) return; UPDATE -> ADR-04 GRÜN
person.action.ts (echte Aktion)                          -> ADR-04 GRÜN
```

## G5 — Guard: Archiv-Dateinamen maskiert + gescannt (Codex #5)

```
probe.zip::eintrag[0]:name   -> echte E-Mail? (pe***id)      (Dateiname maskiert, per Index benannt)
probe.zip::eintrag[0]:inhalt -> AT-IBAN-Muster (AT***01)
Klartext-Dateiname im Log geleakt? False    Klartext-IBAN geleakt? False
```

## G6 — Report: SKIP ist kein PASS (Codex #6)

```
lokal ohne DSN:  passed=False  static_passed=True  gate_passed=False  total_skipped=1
LIVE-Check „passed"-Feld im JSON:  False
```

## G7 — Mermaid echter Parser (Codex #7)

Validator zusätzlich: Klammerbalance + classDiagram-Inhalt (leeres/kaputtes Diagramm jetzt ROT).
Unabhängiger Parser (mmdc) über alle Dossier-Diagramme:
```
Mermaid-Parse: 14 ok, 0 fehlerhaft von 14
```
CI-Job `mermaid-lint` rendert jede extrahierte `.mmd` mit `@mermaid-js/mermaid-cli` (Syntaxfehler = Fehlschlag).

## G8 — Outbox retry_count + DLQ (Gemini MITTEL)

```
Poison-Eintrag nach 5 Fehlversuchen:  attempts=5  dead=true  last_error='deterministischer Fehler'
Toter Eintrag erneut geclaimt?         0  (DLQ wird nie erneut zugestellt -> keine Endlosschleife)
```

## Weiteres Grün

```
Audit: kette_ok=t, hash_reproduzierbar_inkl_id=t (2 Einträge); TRUNCATE auch für Eigentümer blockiert
RLS:   ohne Kontext 0, Mandant aa=3, Mandant bb=1 (kein Cross-Tenant-Leak)
LIVE-Validatoren (vv_app): [PASS] ADR-01 LIVE 8/8 -> GATE 0->1 GRÜN (inkl. Live-DB)
Typecheck web rc=0 · Typecheck worker rc=0 · Worker-Test 7/7 · mermaid 14/14
```

## Ehrlich offen / bewusst Stage-1

- **Unabhängiger Live-Lauf beim Prüfer:** Codex konnte den PostgreSQL-16-Test lokal nicht ausführen
  (kein Docker/WSL). Der **unabhängige** Live-Nachweis liegt im **GitHub-CI-Job `db-integration`**
  (Postgres-16-Service auf GitHub-Runnern, außerhalb der Bau-Sandbox): Migrationen + RLS-Gegenprobe +
  vv_app-kann-Outbox-nicht-Gegenprobe. Dieser Lauf ist die vom Prüfer geforderte unabhängige Wiederholung.
- **Keycloak-Token-Integrationstest** gegen laufendes KC — im Sandbox kein Docker; CI mit KC-Service/Prüfer.
- **Vier-Augen als volles DB-Zustandsautomat** und **DB-Pool als typisierte Unit-of-Work** (statt
  Validator-Heuristik) folgen beim Modul-Bau; der zentrale Effekt-Executor ist dafür jetzt die Basis.
- **Validatoren final per TS-AST** (statt längentreuem Blanken) — die adversarialen Umgehungen sind
  geschlossen, AST ist die robustere Endstufe.
- **Supply-Chain:** GitHub-Actions auf Commit-SHA + Images auf Digest pinnen.
