# C-1 „Kontext-Signatur" — Verifikation (Bau)

> **Stand:** 25.09.2026 · Branch `feat/c1-kontext-signatur` (ab `master` `fa46fdb`) · Bau-KI Claude Code + Opus 5.5 · nur synthetische Daten.
> **Umgebung:** frische PostgreSQL 16.13 ([pg-version.txt](pg-version.txt)), Migrationen 0001–0013 + Seeds, Rollen-Passwörter wie CI, Wegwerf-Ticket-Schlüssel per Betreiber-Skript (`rotate_ticket_key.sh init`).
> **Unabhängige Wiederholung:** GitHub-CI (`vv-ci`, Job `db-integration` + `typecheck-ticket`) und Prüf-Harness [scripts/review_c1.sh](../../scripts/review_c1.sh) (Docker/WSL, für den Codex-Live-Lauf).

## Ergebnis

| Lauf | Ergebnis | Datei |
|---|---|---|
| Migrationen 0001–0013 + Seeds (frisch) | fehlerfrei | [migration.txt](migration.txt) |
| Validatoren LIVE (`VV_REQUIRE_LIVE=1`, inkl. C-1) | grün | [validator-live.txt](validator-live.txt), [validator-report.json](validator-report.json) |
| Validator-Selbsttest | 22/22 | [selftest.txt](selftest.txt) |
| Sicherheits-Gegenproben Stage 0 (auf Ticket-Weg) | 38/38 | [db-asserts.txt](db-asserts.txt) |
| M05-Gegenproben (auf Ticket-Weg) | 140/140 | [db-asserts.txt](db-asserts.txt), [m05-asserts.json](m05-asserts.json) |
| **C-1-Gegenproben DoD 1–7** | **70/70** | [c1-asserts.txt](c1-asserts.txt), [c1-asserts.json](c1-asserts.json) |
| **C-1 Ende-zu-Ende** (Token → Ticket-Dienst → Web → DB, fail-closed) | 10/10 | [c1-e2e.txt](c1-e2e.txt) |
| Tests Web / Worker / Ticket-Dienst | 23/23 · 18/18 · 21/21 | [test-web.txt](test-web.txt), [test-worker.txt](test-worker.txt), [test-ticket.txt](test-ticket.txt) |
| Typecheck Web / Worker / Ticket | rc=0 | [typecheck.txt](typecheck.txt) |
| `npm audit --omit=dev --audit-level=high` (3 Apps) | 0 | [npm-audit.txt](npm-audit.txt) |
| Worker-Start-Probe (echter Start, `vv_worker`) | grün | [worker-smoke.txt](worker-smoke.txt) |
| `docker compose config` (inkl. Dienst `ticket`, Secret, internes Netz) | valide | [compose-config.txt](compose-config.txt) |
| Migrationen 0006–0013 erneut (Idempotenz), danach C-1 erneut | fehlerfrei · 70/70 | [idempotenz.txt](idempotenz.txt), [c1-asserts-nach-idempotenz.txt](c1-asserts-nach-idempotenz.txt) |
| Leistung | `vv_set_context` < 1 ms, RLS als InitPlan | [perf.md](perf.md) |

## Negativnachweis (alter Stand)

Die Codex-Reproduktion aus P54 **gelingt** am alten Stand `master` `fa46fdb` (Mandant B gelesen; Antragsteller `sub-schrift-aa` + Freigeber `sub-vorstand-aa` in einer Verbindung → `approved`; 19 direkte Tabellenrechte von `vv_app`) — [negativnachweis-master.txt](negativnachweis-master.txt). Am neuen Stand wird sie verweigert (c1-asserts „DoD1“).

## Umstellung der bestehenden Gegenproben (DoD 9, ohne Abschwächung)

- **Kontext:** `set_config('app.tenant_id'/'app.actor')` → `vv_set_context(<Ticket>)` (vv_app), `vv_worker_context(<Mandant>)` (vv_worker), `vv_bootstrap_context(…)` (Betreiber-Testdaten).
- **Stärker statt schwächer:** Wo `vv_app` früher Zeilen einfügen durfte und die DB sie normalisierte/abwies (S0-1, S0-2, Event-Spoofing, `approval`-Lesen), prüfen die Proben jetzt „**kein Recht**“ (permission denied). Die Normalisierung (Trigger) selbst wird zusätzlich über die Definer-Rolle nachgewiesen — so wie alle Fachfunktionen schreiben.
- **Entscheidungslogik** (SoD, R3 Attestation, R4 Freigeber-Recht): `vv_decide_approval` ist nicht mehr direkt für `vv_app` freigegeben (sonst ließe sich das Einmal-Ticket der Befehle umgehen); die Logik wird unverändert über die Definer-Rolle geprüft, dazu neu „vv_app kann vv_decide_approval nicht aufrufen“.
- **RLS-Isolation:** statt `SELECT count(*) FROM person` (jetzt: kein Recht) über `basis01_list_persons()` mit Tickets für A und B.

## Im Bau zusätzlich gehärtet

- **SoD-Trigger fail-closed:** `role_assignment`-Schreiben ohne passenden geprüften Kontext wird abgewiesen (vorher ließ fehlender Kontext die SoD-Prüfung leerlaufen — nur für Superuser erreichbar, trotzdem geschlossen).
- **pg-boss-Funktionen** nicht mehr für PUBLIC ausführbar (die App hatte dort ohnehin keine Schema-Nutzung).
- **Validatoren:** `CREATE UNLOGGED/TEMP TABLE` wird im Tabellen-Abgleich (ADR-09) und in der RLS-Prüfung (ADR-01) erkannt; ADR-04 wertet `SELECT … FROM basis0x_…()` als Fachbefehl (nur aus `*.action.ts`).
