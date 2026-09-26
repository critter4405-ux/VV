# CodeQL im Pull Request #21 — Einstufung und Behebung

> 26.09.2026 · PR #21 `feat/c1-kontext-signatur` → `master` · Merge von GitHub blockiert: „3 security relevant alerts“ (neu im PR). Einstufung durch die Bau-KI, Entscheidung zu #32 beim Betreiber.

| Alert | Regel | Fundort | Einstufung | Maßnahme |
|---|---|---|---|---|
| #30 (High) | Polynomial regular expression on uncontrolled data | `apps/ticket/src/ticket.ts` (`b64url`, `/=+$/`) | **Zutreffend (Code-Hygiene).** Die Eingabe ist ein selbst erzeugter HMAC/JSON-Puffer, also nicht angreifergesteuert. Trotzdem gilt: kein Regex über Daten. | **Behoben:** `buf.toString("base64url")` (Node-eigen, gleiches Format) |
| #31 (High) | Potential file system race condition | `apps/ticket/src/keyring.ts` (`statSync` → `readFileSync`) | **Zutreffend, geringe Wirkung.** Zwischen `stat` und `read` konnte die Datei beim Schlüsselwechsel getauscht werden (falscher Cache-Stempel). Schreiben kann nur der Betreiber. | **Behoben:** `openSync` + `fstatSync` + Lesen über denselben Deskriptor |
| #32 (High) | User-controlled bypass of security check | `apps/web/src/server.ts:30` (`if (req.url === "/api/me")`) | **Fehlalarm.** Die Bedingung ist **Routing**, keine Berechtigungsprüfung. Berechtigt wird ausschließlich durch `verifyBearer` (Signatur/Issuer/Audience des Tokens) und in der DB durch das Ticket. Eine andere URL führt nur zur harmlosen Hinweisantwort ohne Daten. Es gibt keinen Pfad, auf dem die URL den Token-Check überspringt und Daten liefert. | **Betreiber:** Alert auf GitHub als *False positive* schließen („Dismiss alert“ → *False positive*, Kommentar: „Routing, keine Autorisierung; Berechtigung durch verifyBearer + DB-Ticket, siehe evidence/c1/codeql-pr21.md“) |

**Nachweis nach Behebung:** Ticket-Dienst Typecheck rc=0, Tests 21/21; C-1 Ende-zu-Ende grün ([c1-e2e.txt](c1-e2e.txt)); C-1-Gegenproben 83/83 ([c1-asserts.txt](c1-asserts.txt)).

**Nicht blockierend, bereits vor C-1 vorhanden (Backlog, kein Teil dieses PR):** #1/#2 Regex in `validators/checks/k29_dossier.py` (Prüfwerkzeug) · #18 Heartbeat-Datei unter `/tmp` im Worker · Warnungen „File is not always closed“, „Empty except“, „Unused global“ in Validatoren/Skripten. Vorschlag: gesammelt in einem eigenen Aufräum-PR.
