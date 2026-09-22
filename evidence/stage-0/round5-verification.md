# Stage 0 — Verifikation Reparaturrunde 5 (Bestätigung, gegen echte PostgreSQL 16)

> Finale Bestätigungsrunde. **Codex** (Harness in WSL): PASS=39/FAIL=2, H1 **PASS**, H2 **PASS** — die
> 2 FAILs waren ein Scan-Artefakt (K31 fand in der ungetrackten `round4.patch` eine Commit-Trailer-Mail;
> „keine getrackten Dateien geändert"). **Gemini:** H1 **gelöst**, H2 **teilweise** — ein feiner, echter
> Race im Reaper. Dieser wird hier behoben (H3) und verifiziert.

## H3 — Reaper prüft das Lease (Gemini, Race in H2)

Vorher reapte `vv_outbox_claim` Schritt (1) alle Einträge mit `attempts >= 5` — auch einen gerade
**aktiv verarbeiteten** 5. Versuch (Lease läuft noch). Ein nebenläufiger Worker hätte ihn fälschlich
als tot markiert, während der erste ihn noch erfolgreich abschließt. Fix: der Reaper reapt nur noch
Einträge mit **abgelaufenem Lease**:
```sql
UPDATE outbox SET dead_at = now(), ...
  WHERE processed_at IS NULL AND dead_at IS NULL AND attempts >= 5
    AND (locked_until IS NULL OR locked_until < now());
```

Nachweis an echter DB:
```
Test A (Hard-Crash, Lease abgelaufen):   nach 5 Versuchen  5/dead=true            (Reaper -> DLQ, weiter ok)
Test B (5. Versuch in-flight, Lease aktiv):
   nach 5. Claim:                        5/dead=false/locked=true
   nebenläufiger Worker-B-Claim:         dead=false        (in-flight NICHT getötet)
   Worker A schließt ab (vv_outbox_done): processed=true/dead=false   (korrekt verarbeitet)
```

## Bestätigung H1/H2 (Runde 5)

- **Codex (WSL-Harness):** H1 Freigeber-Bindung PASS, H2 Hard-Crash PASS; 39 Proben grün. Die 2 FAILs
  stammen aus der ungetrackten `round4.patch` (K31-Scan), nicht aus dem Produkt.
- **Gemini (statisch):** H1 GELÖST (vv_decide_approval zieht Freigeber aus app.actor; vv_app hat kein
  UPDATE auf approval; SoD in DB+Code; app.actor via SET LOCAL). H2 Logik korrekt, nur der Reaper-Race
  (= H3, hier behoben).

## Quergrün

```
LIVE-Validatoren (vv_app): GATE 0->1 GRÜN (inkl. Live-DB) · Typecheck web/worker rc=0 · Worker-Test 7/7
```

## Aufräum-Hinweis / Werkzeug

Ungetrackte Scratch-Dateien im Repo-Root (`round4.patch`, `ergebnis.txt`, `ergebnis.md`) verfälschen den
K31-Scan des Harness (Commit-Trailer-Mail). Sie sind entfernt; künftige Harness-Läufe sollten nur den
**getrackten** Stand prüfen (git-archive statt cp -r).

## Weiterhin bewusst Stage-1

Volle OIDC-gebundene Freigeber-Identität je Einzelperson (app.actor am Endpunkt aus dem Token),
DB-Pool als Unit-of-Work, Validatoren per TS-AST, Keycloak-Token-Integrationstest, Supply-Chain-Pinning;
unabhängige Linux-Verifikation = GitHub-CI (`db-integration`).
