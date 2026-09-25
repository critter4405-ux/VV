# Review-Auftrag — C-1 „Kontext-Signatur" (Ticket-Dienst) · Vier-Augen, Fremdmodell

> **Zweck:** Unabhängige Sicherheitsprüfung des Bauschritts C-1 durch **zwei Fremdmodelle**: GPT-6 Sol (Codex, mit eigenem Live-Lauf) und Gemini 3.1 Pro. Bau-KI (Claude Code + Opus 5.5) ≠ Prüf-KI.
> **Stand:** 25.09.2026 · Branch `feat/c1-kontext-signatur`, Commit siehe `git log -1` · **Intern — nur für den Betreiber.** Nur synthetische Daten.
> **Rolle des Prüfers:** Du prüfst und meldest. Du reparierst nicht selbst und übernimmst die Nachweise der Bau-KI nicht, sondern wiederholst sie selbst.

## Worum es geht

Befund C-1 (Review M05 Runde 2): Mit den DB-Zugangsdaten der Web-App (`vv_app`) ließen sich `app.tenant_id`/`app.actor` frei setzen. **Schutzziel B** (Grill P58): Auch eine **vollständig übernommene App** kann nur im Namen von Nutzern handeln, deren echte Anfrage gerade durchläuft — keine erfundenen Nutzer/Mandanten, nichts offline im Namen Dritter. Gebaut: eigener Ticket-Dienst (prüft Keycloak-Access-Token, stellt 60-s-HMAC-Tickets aus), DB prüft das Ticket per pgcrypto, Einmal-Tickets für Verbindliches, keine Direktrechte für `vv_app`, Worker mit fester Positivliste, Schlüsselwechsel, fail-closed.

**Angreifermodell für diese Prüfung:** Der Angreifer hat die Web-App vollständig übernommen — er besitzt die `vv_app`-DB-Zugangsdaten, kann beliebiges SQL senden, sieht alle durchlaufenden Access-Tokens und Tickets und kann den Ticket-Dienst im internen Netz aufrufen. Er besitzt **nicht**: den Ticket-Schlüssel, den Keycloak-Realm-Schlüssel, Superuser-/Bootstrap- oder `vv_worker`-Zugang.

## Prüfgegenstand

- **Spezifikation:** Bau-Auftrag `VV_C1_Bau-Auftrag_Kontext-Signatur.md` v1.0 (liegt bei) · Register P54, P57, P58 · ADR-01/03/04/05/07/11.
- **DB:** `db/migrations/0013_kontext_signatur.sql` (Kern) · angepasste Seeds `db/seed/*.sql`.
- **Ticket-Dienst:** `apps/ticket/src/*` (`ticket.ts`, `verify.ts`, `keyring.ts`, `server.ts`, `ratelimit.ts`, `index.ts`), `apps/ticket/Dockerfile`.
- **Web:** `apps/web/src/platform/ticket.ts`, `platform/tenant.ts`, `platform/policy.ts`, `server.ts`, `index.ts`, `modules/*/*.action.ts`, `modules/mitglieder/mitglieder.routes.ts`.
- **Worker:** `apps/worker/src/jobs/m05.ts`, `agents/approval_store.ts`.
- **Betrieb:** `docker-compose.yml` (Dienst `ticket`, Secret, Netz), `scripts/rotate_ticket_key.sh`, `.env.example`.
- **Prüfwerkzeuge:** `scripts/c1_db_asserts.py`, `scripts/c1_e2e.sh`, `scripts/ci_db_asserts.sh`, `scripts/m05_db_asserts.py` (auf Ticket-Weg umgestellt), `scripts/vv_ticket.py`, `validators/checks/c1_context.py`, `validators/selftest.py`, `.github/workflows/ci.yml`.
- **Doku/Evidenz:** `docs/bausteine/VV-SEC-01.md`, `evidence/c1/*`, `project/fragments/VV-SEC-01.project.json`.

## Reproduzierbarer Live-Lauf (Pflicht für Codex)

- **Codex (Docker in WSL, LF-Checkout):** aus dem Repo-Root `bash scripts/review_c1.sh` (optional `VV_KEEP_DB=1` für eigene SQL-Nachproben; Zugang: `127.0.0.1:55434`, Nutzer `vv_app`/`vv_worker`/`vv_bootstrap`, Passwort `change_me_dev_only`; der Wegwerf-Keyring liegt dann unter `review-c1-out/ticket_keyring.json`, Tickets erzeugt `python3 scripts/vv_ticket.py mint --tenant … --actor …` mit `VV_TICKET_KEYRING=…`). Das Skript arbeitet read-only auf einer Temp-Kopie: frische PostgreSQL 16, Migrationen 0001–0013 + Seeds, Keyring per Betreiber-Skript, Validatoren LIVE, Selbsttest, Gegenproben (Stage 0, M05, C-1 inkl. echtem Schlüsselwechsel), Typecheck + Tests (Web/Worker/Ticket), `npm audit`, **Ende-zu-Ende** (Token → Ticket-Dienst → Web → DB, fail-closed), Idempotenz. Es liefert PASS/FAIL je Schritt, das Urteil ziehst du.
- **Bitte eigene Angriffe live versuchen** (mit `VV_KEEP_DB=1`), mindestens die unten unter Punkt 1–6 genannten.
- **Gemini (statisch):** Quelltexte als nummerierte Bundle-Dateien (`VV_C1_Review_Teil1.md` … „Teil n/N“). Bitte zuerst bestätigen, dass jedes Bundle bis `=== ENDE TEIL n ===` vollständig angekommen ist. Ohne vollständigen Upload ist kein Befund zu „fehlenden/abgeschnittenen" Dateien zulässig.

## Prüfpunkte (mindestens)

1. **Kontext nicht fälschbar:** Kann `vv_app` Mandant/Akteur ohne gültiges Ticket setzen oder wechseln — über GUCs, `SET ROLE`, temporäre/gleichnamige Objekte, `search_path`, Savepoints/Subtransaktionen, zwei Tickets in einer Transaktion, Wiederverwendung einer Kontextzeile (PID-/Transaktions-ID-Wiederverwendung, Verbindungs-Pooling), lange laufende Transaktionen nach Ticket-Ablauf?
2. **Ticket-Prüfung (`vv_set_context`):** Signatur-/Format-/Kodierungs-Tricks (Base64url-Varianten, Padding, Unicode, doppelte JSON-Schlüssel, Zahlen als Strings, große Zahlen), Schlüssel-Kennung (deaktiviert, abgelaufen, unbekannt), Gültigkeitsfenster und Uhrversatz, Systemakteur, unbekannter Mandant, Zeitseitenkanal beim Vergleich.
3. **Einmal-Tickets:** Deckt die Liste (Freigabe/Ablehnung, Beendigungsantrag, Import-Antrag/-Freigabe, Export, gesperrte Daten, Rollen vergeben/entziehen) alle verbindlichen Wege ab? Lässt sich der Verbrauch umgehen (Kernfunktionen `…__kern`, `vv_decide_approval` direkt, Nebenläufigkeit, Rollback-Tricks)? Fehlt eine verbindliche Aktion in der Liste?
4. **Direktrechte/Positivlisten:** Hat `vv_app` irgendein Tabellen-, Spalten-, Sequenz-, Schema-, TEMP- oder Funktionsrecht außerhalb der Positivliste (32 Funktionen)? Ist jede freigegebene Funktion ohne Ticket wirkungslos? Hat `vv_worker` genau die 11 Systemfunktionen und kann er je als Mensch auftreten?
5. **Ticket-Dienst:** Token-Prüfung (Algorithmus-Tausch, `none`, fremder Aussteller, Audience, ID-/Refresh-Token, fehlender/falscher `tenant_id`, Token-Alter), Ticket nie länger als Token/60 s, Rate-Limit, keine Tokens/Tickets im Log, Keyring-Behandlung (fail-closed), Erreichbarkeit nur intern (Compose-Netz), Container-Härtung.
6. **Fail-closed:** Gibt es irgendeinen Pfad, auf dem die Web-App ohne Ticket auf Daten zugreift oder auf den alten Weg zurückfällt (Fehlerbehandlung, Timeouts, falsche Antworten des Dienstes)?
7. **Schlüsselwechsel/Schlüsselschutz:** Übergang zwei Schlüssel, Ablauf/Deaktivierung, Löschung des Geheimnisses, Audit jedes Schritts ohne Geheimnis, Geheimnis nie in `ps`/Logs/Repo/CI, Rechte der Keyring-Datei, `emergency`-Pfad.
8. **Regression ohne Abschwächung (DoD 9):** Sind die bisherigen Gegenproben (Stage 0, M05, R1–R8, G-1–G-3, R2-Fixes) gleichwertig oder stärker geblieben? Die Umstellungen sind in `evidence/c1/verification.md` („Umstellung der bestehenden Gegenproben") begründet — bitte kritisch prüfen.
9. **Validatoren/Selbsttest:** Ist der neue Check C-1 umgehbar (z. B. GUC-Setzung ohne `set_config`-Literal, Schlüsselmaterial unter anderem Namen)? Prüfen die Gegenproben das Behauptete wirklich?
10. **Leistung/Betrieb:** RLS-Auswertung als InitPlan korrekt und für alle Policies? Housekeeping sicher (kann der Worker verbrauchte, noch gültige Kennungen löschen)? Idempotenz der Migration.
11. **Restrisiken:** Sind die im Dossier (Abschnitt 6) genannten Restrisiken vollständig und richtig eingeordnet (60-s-Fenster laufender Anfragen, Token-Alter 300 s, Refresh-Tokens im künftigen Login-Flow, Superuser)?
12. **Bau-Dossier (K29):** 9 Abschnitte, Diagramm valide, Evidenz-Links real.

## Rückgabe (Format)

- **Gesamturteil:** „bestanden" / „bestanden mit Auflagen" / „nicht bestanden".
- **Befundliste** nach **CRITICAL / HOCH / MITTEL / NIEDRIG**, je Befund: Fundort (Datei:Zeile), konkreter Reproduktionsweg (SQL/Request), erwartetes vs. tatsächliches Verhalten, Empfehlung.
- **Bestätigungen:** welche Prüfpunkte live bzw. statisch nachvollzogen.
- **Keine** Befunde aus unvollständigem Upload oder Harness-/Umgebungsartefakten (getrennt als „Umgebung" melden).

## Weiteres Vorgehen

Die Befunde beider Prüfer werden eingestuft, dem Betreiber vorgelegt und in **einer** konsolidierten Reparaturrunde behoben (Bau-KI), gegen echte PostgreSQL 16 nachgewiesen und erneut geprüft — bis zur Konvergenz. **Die Freigabe (Merge per Pull Request) ist ausschließlich eine Betreiber-Entscheidung.**
