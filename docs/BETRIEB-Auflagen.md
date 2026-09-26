# Betriebsauflagen — Checkliste vor und bei jedem Deployment

> **Zweck:** Auflagen aus den Bauschritten sammeln, die **nicht im Code** erledigt sind, sondern beim Betrieb eingehalten werden müssen, damit bis zum Deployment nichts verloren geht. **Stand:** 26.09.2026 (nach C-1-Freigabe, Register P62). **Pflege:** Jeder Bauschritt ergänzt seine Auflagen hier. Erledigte Punkte bleiben mit Datum stehen.
> **Verbindlich ab:** erstem Deployment mit echten Daten (**S1**, K34). Bis dahin gelten nur synthetische Daten (ADR-10/K31).

## A. Vor dem ersten Deployment (einmalig)

| # | Auflage | Herkunft | Wie prüfen | Erledigt |
|---|---|---|---|---|
| A1 | **Zeitsynchronisation** (NTP/chrony) auf DB-Host und Ticket-Dienst-Host aktiv, Versatz < 1 s | C-1, Dossier VV-SEC-01 §6 (Gemini G3) | `chronyc tracking` bzw. `timedatectl` auf beiden Hosts. Hintergrund: Geht die DB mehr als 5 s nach, werden **alle** Tickets verweigert (fail-closed). | ☐ |
| A2 | **Ticket-Schlüssel anlegen** mit `scripts/rotate_ticket_key.sh init` (nie von Hand). Keyring als Docker-Secret, Datei `0600`, Eigentümer = Container-Nutzer (`KEYRING_UID=1000`), verschlüsselte Kopie per `sops`/`age` (`SOPS_AGE_RECIPIENTS`) | C-1, Bau-Auftrag §2.6 | `scripts/rotate_ticket_key.sh status`, `ls -l` auf die Keyring-Datei. Der Schlüssel liegt **nie** im Repo, in CI-Variablen oder in Logs. | ☐ |
| A3 | **Ausfall-Alarm Ticket-Dienst:** Healthcheck `/health` anbinden (Ausfall = Web-App meldet 503, fail-closed) | C-1, P58-7, ADR-11 | Dienst testweise stoppen → Alarm kommt an. Bis das ADR-11-Monitoring steht: Healthcheck + Log. | ☐ |
| A4 | **Überwachung „Ticket verweigert“**: gehäufte Gründe `Gültigkeitsfenster`/`abgelaufen` melden (Hinweis auf Uhrversatz), `Signatur ungültig` (Hinweis auf Angriff oder falschen Schlüssel) | C-1, Dossier §6 | Log-Auswertung / Alarmregel im Monitoring | ☐ |
| A5 | **Login-Flow:** Die Web-App hält **keine Refresh-Tokens** serverseitig (sonst könnte eine übernommene App Tickets ohne laufende Anfrage erzeugen) — oder vorher Option C (Passkey-Freigaben) | C-1, Dossier §6, P58 | Beim Bau des Login-Flows im Review prüfen | ☐ |
| A6 | **Zugänge Superuser/Bootstrap** (`vv_bootstrap`) nur für den Betreiber, starke Passwörter, nicht in App-Containern; `vv_app`/`vv_worker` mit eigenen Passwörtern | ADR-11, C-1 (Bootstrap-Kontext nur Superuser) | `docker compose config`: Web/Worker sehen nur ihre eigene DB-URL | ☐ |
| A7 | **Container-Images auf Digest pinnen** mit `scripts/pin-images.sh` (in einer Umgebung mit Registry-Zugang) | P47 | `docker-compose.yml` enthält `@sha256:` statt nur Tags | ☐ |
| A8 | **Menschliche Sicherheitsprüfung** vor dem ersten echten Datenimport, besonders DB-Rechte/RLS/Ticket-Prüfung (Daten Minderjähriger) | P60 (Codex für Sicherheitsprüfungen gesperrt) | Prüfbericht liegt vor, Befunde eingestuft | ☐ |

## B. Laufender Betrieb

| # | Auflage | Rhythmus | Wie |
|---|---|---|---|
| B1 | **Schlüsselwechsel Ticket-Dienst** | **alle 90 Tage** (`status` warnt) | `rotate_ticket_key.sh rotate` → Übergangszeit → `retire <alte kid>`; jeder Schritt landet im Audit jedes Mandanten |
| B2 | **Schlüsselwechsel sofort** bei Verdacht (Leck, verlorener Rechner, ausgeschiedene Person mit Zugang) | anlassbezogen | `rotate_ticket_key.sh emergency` (neuer Schlüssel, alter sofort deaktiviert) |
| B3 | **Nach Restore aus einem alten Backup:** Schlüsselwechsel, denn das Backup enthält die damals aktiven Schlüssel | bei jedem Restore | `emergency` direkt nach dem Restore |
| B4 | **Backups verschlüsselt** (Tabelle `ticket_key` enthält Geheimnisse) | laufend | ADR-11 (PITR + Offsite-WORM, verschlüsselt) |
| B5 | **Zeitsynchronisation** weiter überwachen | laufend | siehe A1/A4 |
| B6 | **Ruleset `master-schutz`**: Pflicht-Checks für neue CI-Jobs ergänzen | bei jedem neuen CI-Job | GitHub → Settings → Rules → Rulesets (erledigt für Ticket-Dienst, 26.09.2026) |

## C. Hinweise für Betrieb/Diagnose

- **Worker-Heartbeat** liegt seit dem Aufräum-PR unter `/run/vv-worker/alive` (vorher `/tmp/vv-worker-alive`). Er lässt sich über `VV_HEARTBEAT_FILE` umstellen, der Compose-Healthcheck ist angepasst.
- **Ticket-Dienst** hat kein Port-Mapping nach außen (nur internes Netz `ticketnet`). Nichts davon freigeben.
- **Web-App 503 „vorübergehend nicht verfügbar“** heißt: Der Ticket-Dienst ist weg oder hat keinen gültigen Schlüssel. Das ist gewollt (kein Rückfall). Zuerst `/health` des Dienstes und die Keyring-Datei prüfen.

Bezug: Register P58–P62, K34, K36 · Dossier [VV-SEC-01](bausteine/VV-SEC-01.md) · [ADR-11](adr/ADR-11.md) · `scripts/rotate_ticket_key.sh`
