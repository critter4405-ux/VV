# Stage 0 — Konsolidierte Mängelliste (Vier-Augen-Review) & Reparatur-Backlog

> **Stand:** 17.09.2026 · **Urteil beider Prüf-KI: NICHT BESTANDEN** · **Gate 0→1 gesperrt.**
> Prüf-KI 1 = **GPT-5.6 Codex** (Ausführungs-Review, am Code verifiziert, 18 Befunde).
> Prüf-KI 2 = **Gemini 3.1 Pro** (statisches Review, 5 Befunde + 1 neue Nuance) — bestätigt Codex ohne Widerspruch.
> Bau-KI = Claude Code + Opus 4.8 (prüft nicht selbst — Vier-Augen gewahrt). Intern, nur Betreiber.

## Abdeckung & Provenienz

- Codex hat lokal ausgeführt (Validatoren grün/rot, echte PostgreSQL, Compose) — deckt **auch** `validators/`, `project/`, `scripts/` ab.
- Geminis Upload war am Ende abgeschnitten (`validators/`, `project/`, `scripts/` fehlten in seinem Kontext); es bestätigt App-/DB-/Doku-Ebene und ergänzt die **Audit-Race-Condition**.
- Konsolidiert = Vereinigung, dedupliziert. Keine Widersprüche.

## Reparatur-Backlog (Arbeitspakete, nach Priorität)

### WP0 — Repo-Hygiene *(ermöglicht History/Undo/Secret-Scan)*

- `git init` + erster Commit des sauberen Stands; `.gitignore` prüfen (kein `.env`). *(Codex #18)*
- Secret-History-Scan (gitleaks/trufflehog) über alle Commits. *(Codex #18)*

### WP1 — Mandantentrennung / DB **[blockierend]**

- `apps/web/src/platform/tenant.ts`: echter Transaktions-Wrapper `BEGIN → SET LOCAL → fn → COMMIT/ROLLBACK`; Tenant serverseitig aus **verifizierten Claims**, nie roh aus dem Request. *(Codex #3, Gemini A)*
- `vv_app` explizit **`NOSUPERUSER NOBYPASSRLS`**, besitzt keine Tabellen; getrennter Bootstrap-/Migrations-Superuser (nicht = App-Rolle). *(Codex #2, #15)*
- initdb: Migrationen+Seed **top-level** oder per Wrapper-Skript mit `psql -v ON_ERROR_STOP=1` einspielen (Unterverzeichnis-Mount wird ignoriert). *(Codex #1)*
- Zusammengesetzte FKs `(tenant_id, id)` + `UNIQUE(tenant_id, id)` auf allen tenant-gebundenen Beziehungen. *(Codex #4)*

### WP2 — Audit & Events **[blockierend/hoch]**

- Hash-Kette **DB-seitig in serialisierter Funktion/Trigger** (kein App-Read-then-write) → verhindert Fork/Race; Hash über **alle** unveränderlichen Felder (tenant_id, actor, occurred_at, id, action, subject, payload), kanonisch. *(Gemini B, Codex #6)*
- Audit-Tabelle eigener Rolle `vv_audit_writer`; **UPDATE/DELETE/TRUNCATE** per Privileg + Trigger sperren; `writeAudit` nutzt Audit-Rolle **in derselben Transaktion** wie die Datenänderung. *(Codex #6, Gemini B)*
- Outbox: Schlüssel `(tenant_id, idempotency_key)`; Consumer mit `FOR UPDATE SKIP LOCKED`, Leasing, DLQ; Worker liest die Outbox real. *(Codex #13)*

### WP3 — Zentraler Policy-Prüfpunkt **[blockierend]**

- `policy.ts` **default-deny** (kein `allowed:true`-Start); explizite Allow-Regel nötig. *(Codex #5, Gemini C)*
- DB-Pool nicht frei exportieren; Schreibzugriff nur über typisierte, policy-erzwingende Unit-of-Work/Service-Schnittstelle. *(Codex #5)*

### WP4 — Worker-Governance **[hoch]**

- Vier-Augen als **DB-Zustandsautomat** mit erlaubten Übergängen, Reviewer-Nachweis, Human-Approval, Token mit Ablauf/Scope + **atomarem Consume**; jede bindende Senke nur über diesen Executor; `assertExecutable` ruft den Reviewer-Check; Klassifizierung nicht caller-gesteuert; Worker importiert die Guards. *(Codex #7)*
- Gateway: RegExp-`lastIndex` je Aufruf zurücksetzen/neu erzeugen; strukturierte Allowlist statt reiner Regex; Klartext-Mapping lokal (nicht serialisierbar); direkte Modell-Clients außerhalb des Gateways verbieten. *(Codex #8, Gemini D)*
- **Guardrail (Gemini-Konzept, für späteren KI-Bau):** kein stiller Fallback auf Non-AT/EU → **Fail-Fast (503)**.

### WP5 — Validatoren härten **[hoch]**

- ADR-01/-04: Migrationen in **echter ephemerer PostgreSQL** ausführen und `pg_class`/`pg_policy`/`pg_roles`/effektive Privilegien abfragen (statt Text-Muster). *(Codex #14, Gemini A)*
- ADR-02: TS per **AST/Dependency-Graph**; dynamische `import()`/Re-Exporte/Schreibpfade außerhalb `*.action.ts` erkennen. *(Codex #14)*
- `project.json`: real erzeugte Tabellen via `information_schema` gegen Fragmente abgleichen (fehlende Deklaration = Fail); Schema `additionalProperties:false`. *(Codex #15)*
- K29: Mindest-Inhalt je Abschnitt, Dead-Link-Check, **Mermaid-Syntaxprüfung** (`mmdc`). *(Codex #14, Gemini E)*
- `synthetic_guard`: alle Dateien inkl. **CSV/Binär/Archiv**, **rekursives JSON/JSONB**, Treffer nie im Klartext loggen (Hash/Maske), eigenen Report ausschließen, Fehl-Report **nicht** als CI-Artefakt hochladen. *(Codex #9)*
- Plattformneutraler Runner, `PYTHONUTF8`, Report atomar nach dem Scan schreiben. *(Codex #17)*

### WP6 — Auth / Secrets / CI **[hoch]**

- Echte **OIDC-Validierung** (Signatur/Issuer/Audience/Rollen); HTTP-Endpunkte authentifiziert. *(Codex #10)*
- Pro Dienst getrennte Least-Privilege-Secrets; Worker nutzt `vv-worker`; keine Admin-/Root-Credentials in App-Containern. *(Codex #10)*
- Lockfiles + `npm ci`, Image-**Digests** (kein `latest`), SHA-gepinnte Actions, Dependency-/Secret-/Image-Scans; **CI-Integrationstest** (`docker compose up --wait`, Migrationen, Realm, MinIO-Bucket, RLS-Gegenprobe). *(Codex #11, #16)*
- Healthchecks auf semantische Readiness (Keycloak `/health/ready`, Worker-Heartbeat). *(Codex #11)*

### WP7 — Scope-Ehrlichkeit ADR-08/11 *(Betreiber-Entscheidung 17.09.2026: spätere Infra-Stufe)*

- Zu weit gehende Stage-0-Behauptungen zurücknehmen: ClamAV, Backup/PITR, Offsite-WORM, Monitoring/Alerting, `sops`/`age` sind **spätere Infra-Stufe** (ADR-08/11), nicht Stage-0-Umfang. *(Codex #12)*
- `db-rls-proof.txt` durch **reproduzierbaren, ehrlichen** Nachweis ersetzen (aus CI-Lauf gegen echte PostgreSQL); Seed enthält **zwei** synthetische Mandanten, damit der Isolationstest zum Nachweis passt. *(Codex #15)*

## Definition of Done der Reparatur (erneutes Gate)

- Alle WP0–WP7 umgesetzt; Validatoren **gegen echte PostgreSQL + AST** grün (lokal + CI, gate-blockierend).
- `docker compose up --wait` startet den Stack **mit angewandten Migrationen** + bestandener RLS-Gegenprobe.
- Git-Repo + sauberer Secret-Scan; kein Personenbezug im Repo/CI.
- **Erneutes Fremdmodell-Review** (Codex + Gemini, korrekt eingelesen) → **Betreiber-Freigabe**.

## Nicht Teil dieser Runde (bewusst)

- Fachmodule (M##), Agenten-Fachlogik, Live-Bank/SEPA, Prod-Deploys, echte Daten.
- ADR-08/11-Betriebskomponenten (spätere Infra-Stufe, s. WP7).

---

# Runde 2 — 2. Fremdmodell-Review des reparierten Stands (17.09.2026)

> **Codex (GPT-5.6 Sol, high) = „nicht bestanden"** · **Gemini (3.1 Pro, high) = „bestanden mit Auflagen"**.
> Beide gegen den reparierten Stand (WP0–WP7). Konsolidiert, dedupliziert. Gate blieb gesperrt.
> Reaktion: **eine konsolidierte Reparaturrunde 2 (F1–F8)** durch die Bau-KI, gegen echte
> PostgreSQL 16 + adversarial verifiziert (`evidence/stage-0/round2-verification.md`).

## Befunde Runde 2 → Fix (F#)

| F | Schwere | Befund (Herkunft) | Fix | Verifiziert |
|---|---------|-------------------|-----|-------------|
| **F1** | **CRITICAL** | Vier-Augen über `binding:false` durch Aufrufer umgehbar — `assertExecutable` übersprang Reviewer/Zustand/Token (Codex #7, aus Reparaturrunde 1 stammend) | `binding` server-seitig aus Aktion+Datenklasse klassifiziert (`isBinding`), kein Aufrufer-Flag mehr; nicht-bindend nur unter registrierter stehender Klasse-Freigabe (fail-closed); ausführbarer Adversarial-Test | 5/5 Tests, Umgehung ROT |
| **F2** | hoch | Outbox-`EXECUTE` an `vv_app`; Web & Worker teilten eine Rolle (Codex #4-new, Gemini #1) | eigene Rolle `vv_worker`; EXECUTE nur `vv_worker`, von `vv_app` entzogen; Worker verbindet als `vv_worker` (`WORKER_DATABASE_URL`) | `vv_app` → permission denied; `vv_worker` → ok |
| **F3** | hoch | pg-boss brauchte DB-weites `CREATE SCHEMA`, `vv_app` fehlte es (Codex #3-new) | Schema `pgboss AUTHORIZATION vv_worker` DB-seitig; PgBoss mit `schema:'pgboss'` | Eigentümer `vv_worker` bestätigt |
| **F4** | hoch | Audit-Hash ließ `id` aus, Pipe-Verkettung nicht injektiv, kein TRUNCATE-Block (Codex #6-new, Gemini #2) | Hash über `jsonb_build_object(...)` inkl. `id`+`prev_hash` (kanonisch); `BEFORE TRUNCATE`-Trigger | Kette+Reproduktion inkl. id = t/t; TRUNCATE auch für Eigentümer blockiert |
| **F5** | hoch | Validatoren-Scheinsicherheit: dyn. Import umging ADR-02, ignorierte Policy-Entscheidung umging ADR-04, „Live übersprungen" zählte als PASS, Mermaid nur Muster (Codex #5-new) | adr02 verbietet dyn. `import()` mit Nicht-Literal (fail-closed); adr04 verlangt negativen Guard vor Write + explizite Datei-Allowlist; `db_live` SKIPPED≠PASS, `VV_REQUIRE_LIVE` erzwingt FAIL; Mermaid strukturell | alle vier Umgehungen ROT; LIVE-Gate 8/8 |
| **F6** | hoch | Keycloak-Realm ohne Mapper für `tenant_id`/`roles`/Audience — Token passte nicht zu `auth.ts` (Codex #10) | Mapper `tenant_id`/`roles-flat`/`aud-vv-web` + synthetischer Demo-User | Realm-JSON valide; **Live-Token-Test offen** (kein KC im Sandbox) |
| **F7** | mittel | `ALTER ROLE ... PASSWORD '${VAR}'` string-interpoliert (Quoting/Injection) (Codex #7-new) | psql-Variable + `format('%L', :'pw')` + `\gexec` (init + CI) | Heredoc/`-f -`-Form verifiziert |
| **F8** | mittel | Guard entpackte XLSX/ZIP nicht (Codex #8-new) | ZIP-Container öffnen, innere XML/Text scannen (maskiert) | K31 grün |

## Auflagen aus Gemini „bestanden mit Auflagen"

- Gemini #1 (Rollentrennung) = **F2** erledigt. Gemini #2 (kanonischer Hash) = **F4** erledigt.
- Gemini #3 (RBAC-Rollen in `policy.ts` durchsetzen) = **bewusst Stage-1** (RBAC-Matrix als Daten in Postgres beim Modul-Bau).
- Gemini #4 (adr04 vertraute ganzem `platform/`) = in **F5** erledigt (explizite Datei-Allowlist statt Ordner).

## Bewusst Stage-1 / dokumentierte Residuen (nicht Stage-0-Gate)

- Keycloak-Token-Integrationstest gegen laufendes KC (F6) — CI mit KC-Service / Prüfer.
- DB-Pool als typisierte Unit-of-Work statt freiem Export (Codex #5-Rest) — Invariante via adr04-Check abgesichert.
- Supply-Chain-Pinning: Actions auf Commit-SHA, Images auf Digest (Codex #16).

## Status nach Runde 2

Bau-KI-seitig F1–F8 umgesetzt und gegen **echte PostgreSQL 16 + adversarial** verifiziert
(`evidence/stage-0/round2-verification.md`). **Gate 0→1 bleibt gesperrt** bis zum **3.
Fremdmodell-Review** (Codex + Gemini gegen diesen Stand) **und Betreiber-Freigabe**.

---

# Runde 3 — 3. Fremdmodell-Review + Reparaturrunde 3 (17.–18.09.2026)

> **Codex (GPT-5.6 Sol, high) = „nicht bestanden"** (1 CRITICAL + 4 HOCH + 2 MITTEL).
> **Gemini (3.1 Pro, high) = „bestanden mit Auflagen"** (F6 nach vollständigem Upload grün; 2 Auflagen).
> Beide gegen den Runde-2-Stand. Konsolidierte Reparaturrunde 3 (G1–G9), gegen echte PostgreSQL 16 +
> adversarial verifiziert (`evidence/stage-0/round3-verification.md`). Gate blieb gesperrt.

## Befunde Runde 3 → Fix (G#)

| G | Schwere | Befund (Herkunft) | Fix | Verifiziert |
|---|---------|-------------------|-----|-------------|
| **G1** | **CRITICAL** | Vier-Augen über Metadaten-Spoofing umgehbar: `actionClass`/`state`/`approvedBy`/`token` waren Aufrufer-Daten — Zahlung als `reminder` etikettierbar, „approved" erfindbar, In-Memory-Token nach Neustart wiederverwendbar (Codex #1) | Effekt-Registry (fixe Aktions-/Senken-Identität) + Executor als einziger Pfad zu bindenden Senken + Freigabe **atomar aus der DB** (`vv_consume_approval`: fremd-genehmigt/scope/ablauf/einmal); Reviewer-Unabhängigkeit als DB-CHECK | Unit 7/7 + DB end-to-end (Replay ROT, Selbst-Freigabe ROT, vv_app denied) |
| **G4** | hoch | vv_app hatte direkt UPDATE/DELETE auf `outbox` → Zustellung unterdrückbar trotz entzogenem Consumer-Recht (Codex #4) | vv_app nur INSERT+SELECT auf outbox; Status/Lease nur über Worker-Funktionen | DB: UPDATE/DELETE outbox → permission denied |
| **G2** | hoch | ADR-02-Validator: `import(\`../${x}/…\`)` galt als statisches Literal (Codex #2) | Template-Literal mit `${…}` = Verstoß (fail-closed); statisches Template ohne Interpolation bleibt ok | adversarial ROT / statisch grün |
| **G3** | hoch | ADR-04-Validator: Guard in einem String-Literal versteckt zählte als echt (Codex #3) | Längentreues Blanken: Guard/Decision auf strings-geblankter, Writes auf strings-erhaltener Quelle | Decoy ROT, echte Aktion GRÜN |
| **G9** | niedrig | ADR-04: Destrukturierung `const { allowed } = checkPolicy()` nicht erkannt → False-Positive (Gemini) | Destrukturierung + benannte Variable werden erkannt | destrukturierte Aktion GRÜN |
| **G5** | hoch | Guard loggte inneren Archiv-Dateinamen unmaskiert (neuer PII-Leak, Codex #5) | Eintrag per Index benannt; Dateiname maskiert **und** selbst gescannt | kein Klartext-Name/-IBAN im Log |
| **G6** | mittel | Report wies SKIP zugleich als `passed=true` aus (Codex #6) | `passed=false` für reine Skips; getrennte Felder `static_passed`/`gate_passed`/`skipped` | JSON: skip → passed=False |
| **G7** | mittel | Mermaid-Prüfung kein echter Parser: unbalancierte Klammern / leeres classDiagram grün (Codex #7) | Validator: Klammerbalance + classDiagram-Inhalt; CI-Job `mermaid-lint` mit echtem Parser (mmdc) | Validator ROT bei kaputt; mmdc 14/14 ok |
| **G8** | mittel | Outbox ohne Max-Retries/DLQ → Poison-Pill-Endlosschleife (Gemini) | `attempts`+`dead_at`+`vv_outbox_fail`: nach N Versuchen DLQ, sonst Retry; Worker-Fehlerpfad | DB: attempts=5 → dead, kein Re-Claim |

## „Nicht unabhängig verifiziert" (Codex) — Antwort

Codex konnte den PostgreSQL-16-Live-Test **lokal** nicht ausführen (kein Docker/WSL). Der geforderte
**unabhängige** Live-Lauf ist der **GitHub-CI-Job `db-integration`** (Postgres-16-Service auf
GitHub-Runnern, außerhalb der Bau-Sandbox): Migrationen + RLS-Gegenprobe + „vv_app kann Outbox nicht"-
Gegenprobe. Er läuft bei jedem Push gate-blockierend — das ist die unabhängige Wiederholung.

## Bewusst Stage-1 / dokumentierte Residuen

- Vier-Augen als **voller DB-Zustandsautomat** + DB-Pool als typisierte **Unit-of-Work** (der Effekt-
  Executor ist die Basis dafür); Validatoren final per **TS-AST** statt Blanken; Keycloak-Token-
  Integrationstest gegen laufendes KC; Supply-Chain-Pinning (Actions-SHA/Image-Digest).

## Status nach Runde 3

Bau-KI-seitig G1–G9 umgesetzt und gegen **echte PostgreSQL 16 + adversarial** verifiziert
(`evidence/stage-0/round3-verification.md`). **Gate 0→1 bleibt gesperrt** bis zum **4.
Fremdmodell-Review** (Codex + Gemini gegen diesen Stand) **und Betreiber-Freigabe**.

---

# Runde 4 — 4. Fremdmodell-Review + Reparaturrunde 4 (18.–22.09.2026)

> **Codex** (harness-basiert; PASS=8/FAIL=28 waren Git-Bash-Pfadartefakte, kein Produkturteil — von
> Codex so eingeordnet) und **Gemini** („nicht bestanden", aber dominiert von Upload-Truncation).
> Beide sind auf **zwei** echten Befunden zusammengelaufen; konsolidierte Reparaturrunde 4 (H1/H2),
> gegen echte PostgreSQL 16 verifiziert (`evidence/stage-0/round4-verification.md`).

## Befunde Runde 4 → Fix

| # | Schwere | Befund (Herkunft) | Fix | Verifiziert |
|---|---------|-------------------|-----|-------------|
| **H1** | hoch | `approved_by` war ein von vv_app frei schreibbarer String → fremder Freigeber-Name fälschbar (Codex + Gemini) | vv_app verliert direktes UPDATE auf approval; Entscheidung nur über `vv_decide_approval` (SECURITY DEFINER), Freigeber aus `app.actor` (transaktionsgebunden, verifizierte Claims), `app.actor <> requested_by` erzwungen; `withTenant(...,actor)` setzt app.actor | vv_app UPDATE approved_by → denied; ohne actor → ROT; actor==requester → ROT (SoD); fremder actor → approved_by=actor; Consume einmal, Replay ROT |
| **H2** | mittel | `vv_outbox_claim` ohne `attempts`-Filter → bei HARTEM Crash (kein catch/`vv_outbox_fail`) endloser Re-Claim (Gemini) | Claim jetzt plpgsql: Reaper `dead_at=now() WHERE attempts>=5` (DLQ auch ohne vv_outbox_fail) + Claim nur `attempts<5` | Hard-Crash-Simulation: nach 5 Claims dead, kein Re-Claim |

## Als Artefakt eingeordnet (kein Produktbefund)

- Geminis KRITISCH „db.ts abgeschnitten / Build kaputt" + „TS-Dateien fehlen" = **Upload-Truncation**
  (Teil 1 kam nur bis db.ts an). db.ts vollständig, Typecheck rc=0, Worker-Test 7/7, G1-Dateien vorhanden.
- Codex „FAIL=28" = **Git-Bash-Pfad-Bug im Prüf-Harness** (globales MSYS_NO_PATHCONV brach die
  Host-Pfad-Umwandlung); Harness korrigiert (WSL-Lauf empfohlen). Der unabhängige Linux-Live-Lauf ist
  ohnehin der CI-Job `db-integration`.

## Status nach Runde 4

H1/H2 umgesetzt und gegen echte PostgreSQL 16 verifiziert. **Gate 0→1 bleibt gesperrt** bis
erneutes Fremdmodell-Review gegen diesen Stand + Betreiber-Freigabe. Die zwei Prüfer haben in
Runde 4 keine weiteren belastbaren neuen Produktbefunde geliefert.

---

# Runde 5 — Bestätigungs-Review + H3 (22.09.2026)

> **Codex** (Harness in WSL): PASS=39/FAIL=2, **H1 PASS, H2 PASS** — die 2 FAILs waren ein K31-Scan-
> Artefakt (Commit-Trailer-Mail in der ungetrackten `round4.patch`), kein Produktbefund. **Gemini:**
> H1 **gelöst**, H2 mit einer Auflage — ein feiner, echter Reaper-Race.

| # | Schwere | Befund (Herkunft) | Fix | Verifiziert |
|---|---------|-------------------|-----|-------------|
| **H3** | mittel | Reaper in `vv_outbox_claim` prüfte das Lease nicht → ein aktiv verarbeiteter 5. Versuch (Lease aktiv) konnte durch einen nebenläufigen Worker fälschlich als tot markiert werden (Gemini R5) | Reaper reapt nur `attempts>=5` **UND** abgelaufenes Lease (`locked_until IS NULL OR locked_until < now()`) | Hard-Crash → DLQ; in-flight NICHT getötet, Worker schließt ab → processed=true/dead=false |

**Status nach Runde 5:** H1 und H2 von beiden Prüfern bestätigt; die einzige echte Auflage (H3
Reaper-Race) ist behoben und gegen echte PostgreSQL 16 verifiziert. Keine weiteren belastbaren
Produktbefunde. Der Review ist damit konvergiert — Empfehlung: **Stage-0-Freigabe durch den Betreiber.**
