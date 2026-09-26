# Gate-Checkliste C-1 „Kontext-Signatur" — Definition of Done (Bau-Auftrag v1.0, §5)

> Stand: Bau-Verifikation 25.09.2026, nach Reparatur Review R1, Branch `feat/c1-kontext-signatur`, frische PostgreSQL 16.13. Vier-Augen-Review **konvergiert** (R1 Codex + Gemini, Reparatur, R2 Gemini „bestanden“; Codex-Live-Runde 2 entfallen, Betreiber-Entscheidung — [Abschluss R2](review-r2/ABSCHLUSS-R2.md)). **Gate gesperrt** bis der Betreiber per Pull Request freigibt.

| # | DoD-Punkt | Nachweis | Status |
|---|---|---|---|
| 1 | **C-1 geschlossen:** P54-Repro schlägt fehl (`set_config` Mandant B → nichts; Antragsteller + Freigeber in einer Verbindung verweigert) | [c1-asserts.txt](c1-asserts.txt) „DoD1“ (7 Proben) · alter Stand zum Vergleich: [negativnachweis-master.txt](negativnachweis-master.txt) | erfüllt |
| 2 | **Ohne Ticket kein Zugriff**, Direkt-Grants entfernt und geprüft | c1-asserts „DoD2“ (Tabellen/Spalten/Sequenzen alle Schemata = 0, exakte Funktions-Positivliste, kein TEMP/CREATE, 7 Befehle ohne Ticket verweigert) · Validator C-1 LIVE | erfüllt |
| 3 | **Fälschung und Ablauf** verweigert (Signatur, Kennung, `exp`, Nutzlast) | c1-asserts „DoD3“ (14 Varianten + Ablauf mitten in der Transaktion) · „R1/H-01“ (Ablauf in einer Protokollnachricht und im `DO`-Block) · „R1/N-01“ | erfüllt (nach R1) |
| 4 | **Mandantentrennung:** Ticket A öffnet nie B | c1-asserts „DoD4“ · [c1-e2e.txt](c1-e2e.txt) (Mandant B im Token → 403) | erfüllt |
| 5 | **Einmal-Tickets:** zweite verbindliche Aktion verweigert, Lesen 60 s mehrfach | c1-asserts „DoD5“ (seriell, gleiche Transaktion, parallel, Freigabe, 9 Befehle statisch) · „R1/M-01“ (Aging-up) | erfüllt (nach R1) |
| 6 | **Worker-Trennung:** keine Nutzer-Funktion, kein menschlicher Akteur; Worker-Start-Probe grün | c1-asserts „DoD6“ · [worker-smoke.txt](worker-smoke.txt) | erfüllt |
| 7 | **Schlüsselwechsel:** alt + neu in der Übergangszeit, danach alt verweigert, Audit | c1-asserts „DoD7“ (echtes `rotate_ticket_key.sh rotate/retire`, `valid_until`, Audit je Mandant, Geheimnis gelöscht) | erfüllt |
| 8 | **Fail-closed:** Ticket-Dienst weg → 503, kein Datenzugriff, kein Rückfall | [c1-e2e.txt](c1-e2e.txt) · [test-web.txt](test-web.txt) (`server.test.ts`) | erfüllt |
| 9 | **Regression:** Stage 0, M05, R1–R8, G-1–G-3, R2-Fixes grün, auf Ticket-Weg umgestellt, nicht abgeschwächt | [db-asserts.txt](db-asserts.txt) (Stage-0 38/38, M05 140/140) · [test-web.txt](test-web.txt) · [test-worker.txt](test-worker.txt) | erfüllt |
| 10 | **Validatoren + Selbsttest** grün; neue Proben „keine Direkt-Grants an vv_app“, „keine `set_config('app.…')` in der App“ | [validator-live.txt](validator-live.txt) · [validator-report.json](validator-report.json) · [selftest.txt](selftest.txt) (25/25, davon 9 C-1) | erfüllt |
| 11 | **Bau-Dossier** (K29, 9-teilig + Mermaid), Evidenz `evidence/c1/`, Register-Eintrag | [VV-SEC-01.md](../../docs/bausteine/VV-SEC-01.md) · dieses Verzeichnis · Register P59 (Projekt) | erfüllt |
| 12 | **Typecheck/Tests** Web/Worker/Ticket grün, `npm audit` 0, `docker compose config` valide, **CI auf GitHub grün** | [typecheck.txt](typecheck.txt) · [test-ticket.txt](test-ticket.txt) · [npm-audit.txt](npm-audit.txt) · [compose-config.txt](compose-config.txt) · CI: im Pull Request | erfüllt (CI `8d6d16e`: vv-ci 11/11, CodeQL grün) |

**Zusatz:** Migrationen 0006–0013 idempotent ([idempotenz.txt](idempotenz.txt), danach C-1-Proben erneut 83/83: [c1-asserts-nach-idempotenz.txt](c1-asserts-nach-idempotenz.txt)) · RLS-Leistung gemessen ([perf.md](perf.md)).
