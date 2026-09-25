# M05 Review Runde 3 (Bestätigung) — Einstufung

> Stand 25.09.2026 · Prüfstand `d3f3027` · Prüf-KI **Codex GPT-6 Sol** (kalibriert, P53) · Bericht: [REVIEW-M05-Codex-R3.md](REVIEW-M05-Codex-R3.md)

**Urteil: bestanden** — keine neuen Befunde (CRITICAL/HOCH/MITTEL/NIEDRIG: keine).

| R2-Befund | Status laut Prüfer | eigener Abgleich |
|---|---|---|
| H-1 Attestation | behoben (live: false/false/true/false; Antrag mit leerem/`xyz-bot`-Builder bleibt pending) | deckt sich mit `ci_db_asserts.sh` R2/H-1 |
| H-2 Topic-Register | behoben (live: 0 Zeilen, attempts=0; `outbox_consumer` für vv_worker nicht schreibbar) | deckt sich mit R2/H-2 |
| M-1 Legal Hold Event | behoben (live: je 1 Audit + 1 Event, auch über Tagesjob-Umweg) | deckt sich mit R2/M-1 |
| M-2 Parallelität | behoben (live: zwei überlappende Transaktionen, beide COMMIT, genau 1 Antrag) | deckt sich mit R2/M-2 |
| N-1 FKs | behoben (live: `mib_approval_fk` / `mar_approval_fk`) | deckt sich mit R2/N-1 |

**Live-Lauf (erstmals durch den Prüfer selbst):** PostgreSQL 16.15 in Docker/WSL; Harness roh PASS 13 / FAIL 3. Die 3 FAILs = **Umgebung** (Debian-Security-Paketindex im `python:3.12`-Image lieferte HTTP 404 → psql/psycopg/jsonschema fehlten im Python-Container); unabhängige Nachläufe: Validatoren LIVE grün (RLS/Rollen 20/20), M05-DB **137/137**, Stage-0-SQL-Proben OK, Web/Worker je 18/18, Idempotenz 0006–0011 + RLS ohne Kontext grün.

**Einordnung:**
- Konvergenz erreicht: Runde 2 „nicht bestanden" → Reparaturrunde 2 → Runde 3 „bestanden", ohne neue Befunde.
- C-1 (Vertrauensgrenze `vv_app`) und H-1b (Reviewer-Freitext) bleiben dokumentierte Design-Grenzen (P54); über den HTTP-Pfad mit verifiziertem Token kein Angriff nachgewiesen (statische Pfadprüfung).
- **Harness-Robustheit (NIEDRIG, Werkzeug, kein Produktbefund):** Python-Setup hängt an `apt-get` im `python:3.12`-Image → Folgepunkt: psql/psycopg ohne Debian-Paketindex bereitstellen (z. B. `postgres:16`-Client + `psycopg[binary]` per pip). Kein Einfluss auf das Urteil.
