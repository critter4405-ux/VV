# REVIEW-M05-Gemini (Runde 2, Gemini 3.1 Pro, statisch, Stand 2ff76e1)

> Vom Betreiber am 25.09.2026 im Chat als Text übergeben; unverändert übernommen (nur Markdown-Überschriften gesetzt). Einstufung: [einstufung.md](einstufung.md).

**Gesamturteil: bestanden**

## Befunde

### NIEDRIG — Fehlende Remote-Konfiguration für GitHub-Rulesets (Required Checks)

- Datei:Zeile: evidence/m05/verification.md (Sektion "Bewusst offen")
- Begründung: Die CI-Trigger-Abdeckung wird derzeit nur lokal per Selbsttest erzwungen, da noch kein Remote-Repository gesetzt ist.
- Nachweisweg: Die Dokumentation führt das GitHub-Ruleset explizit als "TODO bei Remote-Anlage" auf.
- Empfehlung: Nach der Anlage des Remote-Repositories sollten Branch-Protection-Rules automatisiert konfiguriert werden, um CI-Checks für Merges verbindlich zu machen.

### NIEDRIG — Manuelles Pinning von Image-Digests

- Datei:Zeile: evidence/m05/verification.md (Sektion "Bewusst offen")
- Begründung: Image-Digests werden aufgrund eines gesperrten Registry-Egress weiterhin manuell über das Skript `scripts/pin-images.sh` verwaltet.
- Nachweisweg: Der Sachverhalt ist als "Stage-0-Residuum" in den bewusst offenen Punkten dokumentiert.
- Empfehlung: Umstellung auf ein automatisiertes Dependency-Management-Tool, sobald die Netzwerkrichtlinien (Egress) der Umgebung dies sicher zulassen.

## Bestätigung der nachvollzogenen Prüfpunkte

- Mandantentrennung & Rechteprüfung (AK-07, AK-08, AK-10): Die deny-by-default-Sicherheitsarchitektur ist direkt an der Datenbank verankert. Fremde Mandanten, fremde Perioden und Cross-Tenant-Verknüpfungen werden wirksam blockiert. Die Feldsicht ist datenklassen- und scope-korrekt umgesetzt.
- Vier-Augen-Prinzip & Zustandsautomat (AK-02, AK-03, AK-09): Es sind ausschließlich erlaubte Statusübergänge möglich. Spoofing-Versuche (S0-2) und Fälschungen (S0-1) wurden identifiziert und behoben. Der SoD-Kern (Segregation of Duties) blockiert unzulässige Zuweisungen zuverlässig.
- Nachvollziehbarkeit (AK-02, R1): Statusverlauf, Audit-Protokoll und Outbox-Events werden in derselben Transaktion sicher geschrieben. Audit-Spoofing (R1) wurde durch spezifische Gegenproben getestet und erfolgreich abgewiesen.
- Datenschutz & Anonymisierung (AK-12): Die Aufbewahrungsfrist von sieben Jahren ist abgebildet. Die anschließende Anonymisierung entfernt den Personenbezug (Person, Nummer, Gründe), während die Audit-Hash-Kette intakt bleibt.
- Behebung früherer Findings (G-1, G-2, G-3): Die im Vorfeld bemängelten Architektur- und Logikfehler bezüglich des Imports (G-1), der Transaktions-Savepoints (G-2) und des Re-Request-Loops (G-3) wurden in der Reparaturrunde 1 verifiziert und mit dem Status "grün" geschlossen.
