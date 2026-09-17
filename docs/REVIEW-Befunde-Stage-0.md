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
