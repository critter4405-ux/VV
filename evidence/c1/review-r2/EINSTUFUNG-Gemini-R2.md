# C-1 Review Runde 2 — Einstufung Gemini 3.1 Pro (Bestätigungs-Review)

> Prüfstand `8d6d16e` · Bericht als Chat-Text vom Betreiber übergeben (26.09.2026), Zusammenfassung unten · Einstufung durch die Bau-KI am Code.
> **Vollständigkeit:** Gemini bestätigt alle 11 Teile bis zur Endmarke. In Runde 1 waren Teil 3 und 4 abgeschnitten bzw. fehlten, das Paket wurde deshalb in kleinere Teile aufgeteilt.

## Urteil Gemini: **bestanden**, keine neuen Befunde

Kernfrage verneint: kein Kontext nach Ablauf, keine Umgehung der Einmal-Tickets, kein Datenzugriff ohne Ticket. Codex-Befunde H-01, M-01, N-01, N-02 und CI laut Gemini „geschlossen“, N-03 „Einstufung akzeptiert“. Eigene R1-Befunde: G3 „Einstufung akzeptiert“ (keine Toleranz auf `exp`, `iat` +5 s), die übrigen geschlossen bzw. akzeptiert.

## Einstufung durch die Bau-KI

| Punkt | Einstufung |
|---|---|
| Gesamturteil „bestanden“, keine neuen Befunde | **übernommen**, als statische Bestätigung. Die Aussagen zu `clock_timestamp`, End-Prüfung, 9 Einmal-Befehlen, doppelten Schlüsseln, Antragsteller-Guard, Rechten und Worker-Trennung stimmen mit dem Code überein. |
| Einstufungen G3 (keine Toleranz auf `exp`) und N-03 (Validator = Frühwarnung) | **bestätigt**, damit konvergiert Gemini mit der Betreiber-Entscheidung und der Einstufung der Bau-KI. |
| **Einschränkung Prüftiefe** | Gemini ordnet seine **eigenen** R1-Befunde falsch zu (R1: G1 = Zeitseitenkanal beim Signaturvergleich, G2 = `jti`-Wiederverwendung, H1 = Ticket-Dienst als Single Point of Failure, H2 = ungültiges JSON; im R2-Bericht stehen stattdessen „GUC Exposure“, „Keyring Rotation“, „Ticket-Re-Use“, „Worker-Kontext“). Kleine Ungenauigkeiten: Dateiname `0013_c1_kontext_signatur.sql` (richtig `0013_kontext_signatur.sql`), „Tabellensperren“ (tatsächlich Primärschlüssel-Konflikt), `search_path` der Kontextfunktionen ist `pg_catalog, pg_temp`. Die inhaltlichen Aussagen treffen trotzdem zu. Der Bericht zählt aber als **statische Bestätigung mit begrenzter Tiefe** und ersetzt keine Live-Prüfung. |
| Aussage „CI für 8d6d16e grün“ | zutreffend (von der Bau-KI über die GitHub-API geprüft: vv-ci 11/11 Jobs und CodeQL erfolgreich). Gemini selbst konnte das nicht prüfen. |

**Stand der Konvergenz:** Gemini R2 ist konvergiert. **Codex R2 steht noch aus.** Der Codex-Auftrag wird von der Cybersicherheits-Prüfung des Anbieters blockiert. Der Betreiber beantragt den erweiterten Zugang (Entscheidung 26.09.2026). Der Pull Request folgt erst nach Codex R2.
