# C-1 „Kontext-Signatur" — Verifikation (Bau)

> **Stand:** 25.09.2026, **nach Reparatur Review R1** ([review-r1/](review-r1/)) · Branch `feat/c1-kontext-signatur` (ab `master` `fa46fdb`) · Bau-KI Claude Code + Opus 5.5 · nur synthetische Daten.
> **Umgebung:** frische PostgreSQL 16.13 ([pg-version.txt](pg-version.txt)), Migrationen 0001–0013 + Seeds, Rollen-Passwörter wie CI, Wegwerf-Ticket-Schlüssel per Betreiber-Skript (`rotate_ticket_key.sh init`).
> **Unabhängige Wiederholung:** GitHub-CI (`vv-ci`, Job `db-integration` + `typecheck-ticket`) und Prüf-Harness [scripts/review_c1.sh](../../scripts/review_c1.sh) (Docker/WSL, für den Codex-Live-Lauf).

## Ergebnis

| Lauf | Ergebnis | Datei |
|---|---|---|
| Migrationen 0001–0013 + Seeds (frisch) | fehlerfrei | [migration.txt](migration.txt) |
| Validatoren LIVE (`VV_REQUIRE_LIVE=1`, inkl. C-1) | grün | [validator-live.txt](validator-live.txt), [validator-report.json](validator-report.json) |
| Validator-Selbsttest | 25/25 | [selftest.txt](selftest.txt) |
| Sicherheits-Gegenproben Stage 0 (auf Ticket-Weg) | 38/38 | [db-asserts.txt](db-asserts.txt) |
| M05-Gegenproben (auf Ticket-Weg) | 140/140 | [db-asserts.txt](db-asserts.txt), [m05-asserts.json](m05-asserts.json) |
| **C-1-Gegenproben DoD 1–7 + Review R1** | **83/83** | [c1-asserts.txt](c1-asserts.txt), [c1-asserts.json](c1-asserts.json) |
| **C-1 Ende-zu-Ende** (Token → Ticket-Dienst → Web → DB, fail-closed) | 10/10 | [c1-e2e.txt](c1-e2e.txt) |
| Tests Web / Worker / Ticket-Dienst | 23/23 · 18/18 · 21/21 | [test-web.txt](test-web.txt), [test-worker.txt](test-worker.txt), [test-ticket.txt](test-ticket.txt) |
| Typecheck Web / Worker / Ticket | rc=0 | [typecheck.txt](typecheck.txt) |
| `npm audit --omit=dev --audit-level=high` (3 Apps) | 0 | [npm-audit.txt](npm-audit.txt) |
| Worker-Start-Probe (echter Start, `vv_worker`) | grün | [worker-smoke.txt](worker-smoke.txt) |
| `docker compose config` (inkl. Dienst `ticket`, Secret, internes Netz) | valide | [compose-config.txt](compose-config.txt) |
| Migrationen 0006–0013 erneut (Idempotenz), danach C-1 erneut | fehlerfrei · 83/83 | [idempotenz.txt](idempotenz.txt), [c1-asserts-nach-idempotenz.txt](c1-asserts-nach-idempotenz.txt) |
| Leistung | `vv_set_context` < 1 ms, RLS als InitPlan, M05-Liste nach R1 5,3 s / 3 008 Mitglieder | [perf.md](perf.md) |

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

## Reparatur Review R1 (Codex GPT-6 Sol + Gemini 3.1 Pro)

Einstufungen: [Codex](review-r1/EINSTUFUNG-Codex-R1.md) · [Gemini](review-r1/EINSTUFUNG-Gemini-R1.md) · Berichte wörtlich im selben Ordner. Betreiber-Entscheidungen 25.09.2026: M-01 → Einmal-Ticket; G3 → keine Toleranz auf `exp`.

| Befund | Reparatur | Nachweis |
|---|---|---|
| H-01 Ablauf innerhalb einer Protokollnachricht/`DO`-Block | Kontext- und Einmal-Prüfung gegen `clock_timestamp()`; End-Prüfung `vv_ctx_require_valid` in 3 Listen | c1-asserts „R1/H-01“ (7 Proben) |
| M-01 Aging-up ohne Einmal-Ticket | Wrapper `m05_decide_proposal` → `vv_ticket_once('m05.decide_proposal')` (9 Befehle) | „R1/M-01“, „DoD5: alle 9 …“ |
| N-01 doppelte JSON-Schlüssel | Schlüsselzahl über `json` = 5 | „R1/N-01“ |
| N-02 S0-2 erreicht Guard nicht | Probe App → Definer-Funktion (Testfunktion, zurückgerollt) | „R1/N-02“ |
| N-03 Validator dynamische GUC | jedes `set_config`/`current_setting`/`SET x.y` im produktiven App-Code rot; Uhr-Check; Live-Invariante M05-Fachkontext | Selbsttest 25/25, validator-live |
| CI rot (DoD5 „abgelaufen“) | frische Tickets je Einmal-Probe, Mehrfach-Lesen über schnelle Sicht | CI im PR |
| E-1 Leistung (Bau-KI) | Kontextfunktionen `plpgsql` (Plan-Cache) | [perf.md](perf.md) |
| G2/G3 Doku | Restrisiko Ticket-Wiederverwendung, Zeitsync-Auflage, `iat`-Toleranz-Probe | Dossier §3/§6, „R1/G3“ |

**Negativnachweis:** Dieselben Gegenproben gegen die Migration 0013 aus `c696df5` (vor der Reparatur): 10 Proben rot (M-01 ×2, 9-Befehle-Liste, H-01 ×6, N-01), siehe [negativnachweis-r1-alter-stand.txt](review-r1/negativnachweis-r1-alter-stand.txt). G3- und N-02-Proben sind reine Abdeckungsproben und waren schon vorher grün.
