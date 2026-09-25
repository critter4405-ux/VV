# C-1 Review Runde 1 — Bericht Gemini 3.1 Pro (wörtlich, vom Betreiber übergeben am 25.09.2026)

> Prüfstand `5e139c3`. Einstufung: [EINSTUFUNG-Gemini-R1.md](EINSTUFUNG-Gemini-R1.md).

Die Umstellung auf die C-1-Architektur (Mandanten-Kontext per signiertem Kurzzeit-Ticket) ist ein massiver Sicherheitsgewinn und architektonisch hervorragend durchdacht. Der Wechsel von frei setzbaren GUCs (`set_config`) zu kryptografisch verifizierten Tickets eliminiert die Gefahr des Session-Spoofings durch fehlerhaften App-Code nahezu vollständig. Die konsequente Durchsetzung über Integrationstests, statische Validatoren und den Wegfall direkter Tabellenrechte in `vv_app` zeigt einen extrem hohen Reifegrad.

Dennoch gibt es bei der genauen Betrachtung der kryptografischen Implementierung in der Datenbank und der verteilten Systemarchitektur noch drei kritische Sicherheits- und Stabilitätsrisiken, die vor einem Merge behoben werden müssen.

## Kritische Befunde (Blocker)

**1. Kryptografische Timing-Attacke bei der Signaturprüfung (PostgreSQL)**
In der Datenbank-Migration (`vv_set_context`) wird die Signatur vermutlich über einen Standard-Operator (wie `!=` oder `=`) validiert. PostgreSQL-String-Vergleiche brechen beim ersten abweichenden Byte ab (Short-Circuit). Ein Angreifer im Netzwerk könnte durch exakte Messung der Antwortzeiten (Timing-Attacke) Zeichen für Zeichen der HMAC-Signatur erraten.

- Lösung: Nutze einen Constant-Time-Compare. Da PostgreSQL nativ keinen anbietet, ist der etablierte Workaround, beide Seiten vor dem Vergleich nochmals zu hashen: `IF sha256(computed_signature) != sha256(provided_signature) THEN ...`

**2. Fehlender Replay-Schutz (JTI wird ignoriert)** Das Ticket-System generiert zwar vorbildlich eine JWT ID (`jti`), diese wird in der Funktion `vv_set_context` jedoch nicht validiert oder gespeichert.

- Risiko: Ein legitimes Ticket ist 60 Sekunden gültig. Wird es innerhalb dieses Fensters abgefangen (z. B. durch Logging, Proxy-Leaks oder interne Angreifer), kann es im gesamten Gültigkeitszeitraum beliebig oft für Replay-Attacken wiederverwendet werden.
- Lösung: Entweder das Risiko des 60-Sekunden-Fensters wird im Threat-Model explizit als akzeptabel dokumentiert, oder die `jti` muss in einer unlogged Table (mit automatischem Cleanup abgelaufener Einträge) zur Verifizierung hinterlegt werden.

**3. Keine Toleranz für Clock Skew (NTP-Zeitversatz)**
Die Prüfung der Expiration (60 Sekunden) geht davon aus, dass die Systemuhren des Ticket-Dienstes und der PostgreSQL-Datenbank auf die Millisekunde synchron sind.

- Risiko: Bereits eine minimale Abweichung (Clock Drift) der Serveruhren führt dazu, dass Tickets in der Sekunde ihrer Ausstellung von der Datenbank als abgelaufen abgelehnt werden.
- Lösung: Bei der Prüfung des `exp`-Claims sollte ein Leeway (Toleranzfenster) von mindestens 3 bis 5 Sekunden eingebaut werden: `IF (body_json->>'exp')::bigint < (extract(epoch from now()) - 5) THEN ...`

## Architektur- und Performance-Hinweise

- Abhängigkeit zur Laufzeit (Availability): Die Web-App blockiert nun bei jedem neuen Kontext-Aufbau synchron, falls das Ticket nicht im Cache liegt, um den Ticket-Dienst anzufragen. Das Caching-Verhältnis (45s TTL bei 60s Lebensdauer) ist gut gewählt, macht den Ticket-Dienst aber dennoch zum Single-Point-of-Failure für jede Datenbankabfrage der App. Ein Connection-Timeout beim Ticket-Dienst legt die gesamte Web-App lahm.
- Fehlerbehandlung bei ungültigem JSON: Wenn die Base64url-Decodierung des Payloads in `vv_set_context` keinen validen JSON-String ergibt, wirft PostgreSQL einen Standard-JSON-Fehler. Dies ist sicherheitstechnisch unkritisch, führt aber zu unschönen Logs. Ein robuster `EXCEPTION`-Block, der alle Fehler pauschal als "Ticket ungültig" maskiert, ist hier Best Practice.

## Was exzellent gelöst ist

- Test-Isolierung & Bootstrap-Kontext: Die Test-Setups (`mitglieder.api.test.ts`, `m05.integration.test.ts`) nutzen nun absolut reale Bedingungen. Das Erstellen der synthetischen Nutzer über den separaten `vv_bootstrap_context` beweist eindrucksvoll, dass `vv_app` tatsächlich keine eigenen Schreibrechte mehr auf Basistabellen hat.
- Konsequente Validator-Prüfungen: Dass der CI-Pipeline-Validator (`selftest.py`) alte `set_config`-Aufrufe oder harte HMAC-Schlüssel im Quellcode statisch erkennt und den Build rot färbt, verhindert zukünftige Regressionen durch unwissende Entwickler.
- Worker-Kontext Privilegierung: Dem Worker-Prozess keinen kryptografischen Overhead aufzuzwingen, sondern ihn auf Basis der DB-Rolle (`vv_worker_context`) vertrauensvoll den Mandanten wechseln zu lassen, ist absolut richtig und schont die Performance.

Behebe die Timing-Attacke in der PostgreSQL-Signaturprüfung und füge den Clock-Skew-Leeway hinzu. Der Replay-Schutz (`jti`) kann als Ticket-Erweiterung für ein späteres Release aufgeschoben werden, sofern das 60-Sekunden-Restrisiko dokumentiert wird.
