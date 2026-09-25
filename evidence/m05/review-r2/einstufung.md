# M05 Review Runde 2 — Einstufung (Bau-KI, vor Reparatur)

> Stand 24.09.2026 · Prüfstand `2ff76e1` · Betreiber-Entscheidungen 24.09.2026: C-1 = Restrisiko + Stage-1; Reparatur erst nach Gemini-Bericht (eine konsolidierte Runde).

## Codex (GPT-6 Sol) — [REVIEW-M05-Codex-R2.md](REVIEW-M05-Codex-R2.md)

| # | Befund | Prüfung | Einstufung | Maßnahme |
|---|---|---|---|---|
| C-1 | `vv_app` setzt Tenant/Actor-GUC frei → mit App-Credentials Mandant B lesen, Antragsteller+Freigeber in einer Verbindung | am Code bestätigt | Design-Grenze (ADR-01/04: DB schützt gegen App-Logikfehler, nicht gegen kompromittierte App-Credentials); über HTTP nicht ausnutzbar | **Restrisiko dokumentiert (Betreiber)**; Stage-1-Pflicht vor S3: Kontext-Signatur (Auth-Dienst + HMAC-Prüfung in der DB) |
| H-1a | `vv_attestation_ok('', 'gpt-5')` = true (leerer/unbekannter Builder) | live bestätigt | echt | nur bekannte Modellfamilien; unbekannt/leer → deny |
| H-1b | Reviewer-Kennung = Freitext des Freigebers | bestätigt | Design/Stage-1 | Artefakt-Bindung mit Prüf-Agent (BASIS-09) |
| H-2 | `vv_outbox_claim` akzeptiert beliebige Topic-Liste | live bestätigt | echt (Schwere MITTEL) | DB-seitiges Consumer-Register |
| M-1 | Legal Hold ohne Outbox-Event | bestätigt | echt | Event `m05.retention.hold` + Gegenprobe |
| M-2 | Tagesjob Anonymisierungs-Antrag ohne SKIP LOCKED | bestätigt | echt | SKIP LOCKED + idempotent + parallele Gegenprobe |
| N-1 | `approval_id`-FKs nicht mandantendicht | live bestätigt | echt | `UNIQUE(tenant_id,id)` + zusammengesetzte FKs |
| Umg. | R6-Selbsttest abhängig von `origin/HEAD` | bestätigt | echt (NIEDRIG) | Probe auf feste Hauptbranches |

Live-Lauf Codex: Docker nicht verfügbar (Umgebung). Unabhängiger Live-Nachweis: GitHub-CI `vv-ci` auf `2ff76e1` 9/9 grün.

## Gemini 3.1 Pro — Urteil „bestanden"

Bericht vom Betreiber im Chat übergeben (25.09.2026, als Text; Kernaussagen hier festgehalten).

| # | Befund | Einstufung |
|---|---|---|
| NIEDRIG | GitHub-Ruleset/Required Checks fehlen (Remote) | bekannt (R6/P52) — Remote inzwischen angelegt, Repo öffentlich; Ruleset = Betreiber-Aktion |
| NIEDRIG | Image-Digest-Pinning nur per Skript | bekannt (P47-Residuum, Registry-Egress) — Stage-1 |

Bestätigt: Mandantentrennung, Vier-Augen/Zustandsautomat, Audit/Outbox (R1), Datenschutz, G-1/G-2/G-3 gelöst.
**Bewertung der Prüftiefe:** statisch und überwiegend dokumentationsgestützt; keine der Codex-Befunde (C-1, H-1, H-2, M-1, M-2, N-1) gefunden, keine Vollständigkeitsbestätigung der 12 Teile im Bericht. Keine Code-Maßnahme aus Gemini.

## Ergebnis Reparaturrunde 2 (nach beiden Berichten, eine Runde)

Behoben: H-1a, H-2, M-1, M-2, N-1, R6-Probe — je Fix gate-blockierende Gegenprobe (8 neu), gegen echte PostgreSQL 16:
**grün auf dem reparierten Stand, rot gegen den alten Migrationsstand** (Negativ-Nachweis: alle 8 R2-Proben FAIL, M-2 reproduziert exakt `duplicate key … mar_one_open`).
Nicht behoben (Betreiber-Entscheidung): C-1 = dokumentierte Design-Grenze, Stage-1-Pflicht vor S3. H-1b = Stage-1 (BASIS-09).
