# Stage 0 — Verifikation Reparaturrunde 4 (gegen echte PostgreSQL 16)

> Reaktion auf das 4. Fremdmodell-Review. Codex und Gemini sind auf **zwei** echten Befunden
> zusammengelaufen; alles andere war entweder schon erledigt/verifiziert oder ein Umgebungs-/
> Upload-Artefakt (Geminis „db.ts abgeschnitten" = Upload-Truncation — die Datei ist vollständig,
> Typecheck rc=0; Codex' „PASS=8 FAIL=28" = Git-Bash-Pfad-Bug im Prüf-Harness, kein Produktfehler).
> Umgebung: PostgreSQL 16, Node 22, Python 3.12. Nur synthetische Daten.

## H1 — approved_by an transaktionsgebundenen Actor gebunden (Codex + Gemini, HOCH)

Vorher: `approved_by` war ein von `vv_app` frei schreibbarer String → ein kompromittiertes Web-Layer
konnte einen beliebigen fremden Freigeber-Namen eintragen. Jetzt:
- `vv_app` verliert das direkte `UPDATE` auf `approval` (auch spaltenweise).
- Die Entscheidung läuft nur über `vv_decide_approval(id, decision, reviewer_model)` (SECURITY DEFINER):
  setzt den Freigeber DB-seitig aus `current_setting('app.actor')` (transaktionsgebunden, aus
  verifizierten OIDC-Claims am Entscheidungs-Endpunkt), erzwingt `app.actor <> requested_by`.
- `apps/web/src/platform/tenant.ts`: `withTenant(..., actor)` setzt `app.actor` per SET LOCAL.

Nachweis an echter DB:
```
A1  vv_app UPDATE approval SET approved_by=...:   ERROR permission denied  (kein UPDATE-Recht)
A2a vv_decide_approval ohne app.actor:            ERROR „kein app.actor gesetzt"
A2b app.actor == requested_by:                    ERROR „Antragsteller darf nicht selbst freigeben (SoD)"
A2c app.actor='human-2' (fremd):                  approved/human-2  (Freigeber = app.actor, NICHT aus Body)
A3  Worker-Consume danach:                        einmal t, Replay f
```
Grenze (bewusst): `app.actor` wird vom Web-Layer aus dem verifizierten Token gesetzt (wie
`app.tenant_id`). Volle Nicht-Abstreitbarkeit je Einzelperson ist Auth-Layer/Stage-1; DB-seitig ist
der Freigeber jetzt an den Session-Actor gebunden und nicht mehr als freier Body-String fälschbar.

## H2 — Outbox-DLQ auch bei HARTEM Crash (Gemini, MITTEL)

Vorher: `vv_outbox_claim` filterte nicht auf `attempts`. Bei einem harten Worker-Crash (OOM/kill)
läuft der `catch`-Block nicht, `vv_outbox_fail` wird nie gerufen → das Lease läuft ab und dasselbe
Giftelement wird endlos neu geholt. Jetzt in `vv_outbox_claim` (plpgsql):
1. **Reaper:** `UPDATE ... SET dead_at=now() WHERE attempts >= 5` — verschiebt überzählige Elemente
   DB-seitig in die DLQ, unabhängig von `vv_outbox_fail`.
2. **Claim** holt nur noch Einträge mit `attempts < 5`.

Nachweis (Hard-Crash-Simulation: Claim ohne `vv_outbox_fail`, Lease-Ablauf):
```
Runde 1..5: geclaimt=1  attempts=1..5  dead=false
Runde 6:    geclaimt=0  attempts=5     dead=true      (Reaper -> DLQ)
erneuter Claim danach: 0                                (kein Re-Claim)
```
Der Soft-Fail-Pfad (`vv_outbox_fail` nach `catch`) bleibt zusätzlich aktiv (Runde-3-Nachweis).

## Quergrün

```
Typecheck web rc=0 · Typecheck worker rc=0 · Worker-Adversarial-Test 7/7
LIVE-Validatoren (vv_app): [PASS] ADR-01 LIVE 8/8 -> GATE 0->1 GRÜN (inkl. Live-DB)
approved_by-Bindung A1–A3 grün · G8 Hard-Crash-Reaper grün
```

## Einordnung der Review-Runde-4-Artefakte

- Geminis KRITISCH „apps/worker/src/db.ts abgeschnitten / Build kaputt" + „effects.ts/vier_augen.ts/
  approval_store.ts fehlen": **Upload-Truncation bei Gemini** (Teil 1 kam nur bis db.ts an). Die
  Dateien sind vollständig vorhanden, Typecheck rc=0, Worker-Test 7/7.
- Codex „PASS=8 FAIL=28": **Git-Bash-Pfad-Bug im Prüf-Harness** (globales MSYS_NO_PATHCONV brach die
  Host-Pfad-Umwandlung für `docker cp`), kein Produktbefund — Codex hat das selbst so eingeordnet.
  Der Harness wurde korrigiert (Lauf in WSL empfohlen).

## Weiterhin bewusst Stage-1

Volle Auth-gebundene Freigeber-Identität je Einzelperson (OIDC-Session → app.actor am Endpunkt),
DB-Pool als typisierte Unit-of-Work, Validatoren final per TS-AST, Keycloak-Token-Integrationstest,
Supply-Chain-Pinning (Actions-SHA/Image-Digest). Unabhängige Linux-Verifikation = GitHub-CI
(`db-integration`), frei von Windows-Pfadproblemen.
