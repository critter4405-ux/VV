# C-1 Review Runde 2 — Abschluss und Konvergenz

> Stand 26.09.2026 · Prüfstand `8d6d16e` (Reparatur R1) · Register **P59/P60** (v0.47).

## Ergebnis

| Prüfer | Runde 1 (`5e139c3`) | Runde 2 (`8d6d16e`) |
|---|---|---|
| **Codex GPT-6 Sol** (live, WSL/Docker) | „nicht bestanden“: H-01, M-01, N-01–N-03, CI rot — [Bericht](../review-r1/REVIEW-C1-Codex-R1.md), [Einstufung](../review-r1/EINSTUFUNG-Codex-R1.md) | **entfallen** (siehe unten) |
| **Gemini 3.1 Pro** (statisch) | G1–G3, H1–H2 — [Bericht](../review-r1/REVIEW-C1-Gemini-R1.md), [Einstufung](../review-r1/EINSTUFUNG-Gemini-R1.md) | **„bestanden“, keine neuen Befunde** — [Bericht](REVIEW-C1-Gemini-R2.md), [Einstufung](EINSTUFUNG-Gemini-R2.md) |
| **GitHub-CI** (unabhängige Ausführung) | rot (Testannahme, Ursache gefunden) | **grün**: vv-ci 11/11 Jobs, CodeQL — inkl. aller „R1/…“-Gegenproben |

## Abweichung von der Vier-Augen-Kette (Betreiber-Entscheidung 26.09.2026)

Runde 2 läuft **ohne zweiten Live-Prüfer**:

- **Codex** sperrt den Prüfauftrag über den Cybersicherheits-Filter des Anbieters, auch in einer auf Verifikation reduzierten Fassung. Der erweiterte Zugang („Daybreak“) steht nur Business-Kunden offen.
- **Gemini CLI** nimmt private Google-Konten nicht mehr an. Ein API-Schlüssel wäre nur mit dem Flash-Modell kostenlos (schwächerer Prüfer, Datennutzung durch Google), sonst kostenpflichtig.
- Die Bau-KI hat den Auftrag bewusst **nicht weiter umformuliert, um den Filter zu umgehen**.
- Nachtrag 26.09.2026: Auf Wunsch des Betreibers erhielt Codex noch eine **andere Aufgabe ohne Angriffsversuche**: Testlauf und Code-Review der Korrekturen, die R1-Angriffe nur als vorhandene Tests „R1/…“ bewerten. Auch diese Fassung wurde gesperrt. Damit ist Codex für Sicherheitsprüfungen dieses Projekts derzeit nicht nutzbar (Register P60).

**Kompensation:** Codex hat in Runde 1 live und adversarial geprüft. Seine Reproduktionen (H-01 als Mehrfachnachricht und `DO`-Block, M-01, N-01) laufen als Gegenproben „R1/…“ in `scripts/c1_db_asserts.py`: grün in der unabhängigen GitHub-CI, rot am alten Stand ([Negativnachweis](../review-r1/negativnachweis-r1-alter-stand.txt)). Gemini bestätigt Runde 2 statisch.

**Offen für künftige Bauschritte (Register P60):** Werkzeugkette für Live-Prüfungen neu festlegen. Gemini-Uploads ≤ ~90 KB je Nachricht.

## Stand zur Freigabe

Review **konvergiert**. Nächster Schritt: Pull Request `feat/c1-kontext-signatur` → `master`. **Merge = Betreiber-Entscheidung**; die Bau-KI öffnet kein Gate.
