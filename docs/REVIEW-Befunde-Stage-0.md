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
