# Stage 0 — Verifikation Reparaturrunde 2 (gegen echte PostgreSQL 16)

> Reaktion auf die konsolidierten Befunde des 2. Fremdmodell-Reviews
> (Codex „nicht bestanden" + Gemini „bestanden mit Auflagen"). Bau-KI verifiziert;
> die eigentliche Freigabe des Gates erfordert ein erneutes (3.) Fremdmodell-Review + Betreiber-Freigabe.
> Umgebung: PostgreSQL 16.13, Node 22, Python 3.12. Nur synthetische Daten.

## F1 — Vier-Augen: `binding` server-seitig, Aufrufer-Umgehung geschlossen (Codex #7, CRITICAL)

`assertExecutable` akzeptiert kein `binding`-Flag mehr; die Verbindlichkeit wird aus Aktion +
Datenklasse **klassifiziert** (`isBinding`). Nicht-bindend läuft nur unter registrierter stehender
Klasse-Freigabe (fail-closed). Ausführbarer Adversarial-Test `vier_augen.test.ts`:

```
# tests 5
# pass 5
# fail 0
```

Der Test beweist u. a.: eine bindende Aktion (`person.delete`) ist NICHT mehr durch einen
Aufrufer-Wunsch entschärfbar; unbekannte Aktionen scheitern fail-closed.

## F2/F3 — Rollentrennung, Outbox-Recht, pgboss-Schema (Codex #4-new/#3-new, Gemini #1)

```
rolname       | rolsuper | rolbypassrls
vv_app        | f        | f
vv_worker     | f        | f
vv_bootstrap  | t        | f
pgboss-Schema-Eigentümer: vv_worker
EXECUTE vv_outbox_claim/done: vv_worker (+ Eigentümer vv_bootstrap) — NICHT vv_app
```

Gegenprobe an der laufenden DB:

```
vv_app  → SELECT vv_outbox_claim(1):  ERROR: permission denied for function vv_outbox_claim
vv_worker → SELECT count(*) FROM vv_outbox_claim(1): 0   (erlaubt, kein Fehler)
```

## F4 — Audit-Hash kanonisch inkl. id + TRUNCATE-Sperre (Codex #6-new, Gemini #2)

Zwei Einträge (Mandant aa); Kette + Reproduzierbarkeit an der DB nachgerechnet:

```
 id | kette_ok | hash_reproduzierbar_inkl_id
  1 | t        | t
  2 | t        | t
```

`kette_ok` = `prev_hash[n]` entspricht `entry_hash[n-1]`; `hash_reproduzierbar_inkl_id` = unabhängige
Nachberechnung über `jsonb_build_object(... 'id' ...)` stimmt mit dem Trigger-Hash überein
(beweist: id ist Teil des Hashes, kanonische Kodierung, keine Pipe-Mehrdeutigkeit).

Append-only (auch gegen den Tabelleneigentümer):

```
vv_app    UPDATE/DELETE/TRUNCATE audit_log:  ERROR: permission denied (kein Grant)
vv_bootstrap (Eigentümer) TRUNCATE audit_log: ERROR: audit_log ist append-only (Operation TRUNCATE nicht erlaubt).
Zeilen nach den Versuchen: 2 (unverändert)
```

## F5 — Validatoren gehärtet, adversarial ROT (Codex #5-new)

```
adr02  dynamischer import() mit Variable        → ROT (fail-closed, nicht statisch prüfbar)
adr04  Aktion ruft checkPolicy, ignoriert Entscheidung, DELETE → ROT (kein Guard vor Write)
db_live ohne DSN + VV_REQUIRE_LIVE=1            → Gate-Exit 1 (übersprungen ist im Gate KEIN PASS)
mermaid unbalancierte subgraph/end bzw. fehlende Direktive/Kante → ROT
```

Voller Lauf im LIVE-Modus (als vv_app, echte DB):

```
[PASS] ADR-01  LIVE: RLS/Rollen effektiv (echte PostgreSQL)  (8/8 ok)
GATE 0 -> 1: GRÜN — alle ADR-Invarianten erfüllt (inkl. Live-DB).
```

## F6 — Keycloak-Realm: Protocol-Mapper (Codex #10)

`vv-web` erhält Mapper `tenant_id` (User-Attribut→Claim), `roles-flat` (Realm-Rollen→`roles`,
multivalued) und `aud-vv-web` (Audience) — passend zu `auth.ts` (Issuer/Audience/tenant_id/roles).
Synthetischer Demo-User `demo-vorstand` (tenant aa, Rollen vorstand/mitglied) trägt die Claims.
**Offene Verifikation:** der End-to-End-Token-Test braucht ein laufendes Keycloak — im Sandbox
kein Docker-Daemon; im CI mit Keycloak-Service oder durch den Prüfer nachzuholen.

## F7 — Passwort-Setzen ohne String-Interpolation (Codex #7-new)

`00_init.sh` und CI setzen Rollen-Passwörter über psql-Variable + `format('%L', :'pw')` + `\gexec`
(kein `'${VAR}'` mehr). Heredoc/`-f -`-Form verifiziert (interpoliert korrekt; `\gexec` ohne `;`).

## F8 — Guard entpackt XLSX/ZIP (Codex #8-new)

`synthetic_guard` öffnet ZIP-Container (inkl. `.xlsx/.docx/...`) und scannt innere XML/Textteile
auf IBAN/E-Mail (maskiert). K31-Check grün auf dem aktuellen (nur synthetischen) Repo.

## Toolchain-Quergrün

```
Typecheck Web:    rc=0        Typecheck Worker: rc=0
docker compose config: OK     Worker-Adversarial-Test: 5/5
```

## Rest / bewusst Stage-1 (dokumentiert, nicht Stage-0-Gate)

- Voller Keycloak-Token-Integrationstest (Live-Realm) — s. F6, im CI mit KC-Service nachzuziehen.
- DB-Pool-Kapselung als Unit-of-Work statt freiem Export (Codex #5-Rest) — Invariante ist über den
  adr04-Write-Außerhalb-Check abgesichert; die typisierte Kapselung folgt beim Modul-Bau.
- RBAC-Rollen-Durchsetzung in `policy.ts` (Gemini #3) — bewusst Stage-1 (RBAC-Matrix als Daten).
- Supply-Chain: GitHub-Actions auf Commit-SHA + Container-Images auf Digest pinnen (Codex #16).
