# C-1 Kontext-Signatur — Leistungsmessung (Bau-Auftrag §4)

> Lauf: 25.09.2026, lokale PostgreSQL 16.13 (Bau-Umgebung), synthetische Massendaten, Skript [scripts/c1_perf.py](../../scripts/c1_perf.py). Nicht gate-blockierend; die Auswertung als InitPlan ist gate-blockierend in [c1_db_asserts.py](../../scripts/c1_db_asserts.py).

| Messung (PostgreSQL 16, Mandant A: 23033 Personen, davon 20000 für die Messung angelegt — alle synthetisch) | Median |
|---|---|
| `vv_set_context` (Ticket prüfen + Kontext setzen, inkl. Roundtrip/Transaktion) | 0.37 ms |
| RLS `count(*)` über person — Policy als **InitPlan** (Ist) | 1.6 ms |
| RLS `count(*)` über person — Vergleich: Kontext **je Zeile** | 5.1 ms |
| Ende-zu-Ende `basis01_list_persons()` mit Ticket (23033 Zeilen) | 12.8 ms |

- Plan (Ist): `Aggregate  (cost=628.73..628.74 rows=1 width=8) / InitPlan 1 (returns $0) / ->  Result  (cost=0.00..0.26 rows=1 width=16) / ->  Seq Scan on person  (cost=0.00..601.61 rows=10744 width=0) / Filter: (tenant_id = $0)`
- Plan (je Zeile): `Aggregate  (cost=1792.87..1792.88 rows=1 width=8) / ->  Index Only Scan using person_tenant_uk on person  (cost=0.54..1739.19 rows=21475 width=0) / Index Cond: (tenant_id = vv_current_tenant())`
- Policy nach der Messung unverändert: `(tenant_id = ( SELECT vv_current_tenant() AS vv_current_tenant))`

**Einordnung:**

- Die Ticket-Prüfung kostet je Anfrage einmalig < 1 ms (HMAC + eine Kontextzeile, UNLOGGED).
- Die RLS-Prüfung wird durch `(SELECT vv_current_tenant())` **einmal je Abfrage** ausgewertet (InitPlan) statt je Zeile — rund 3× schneller als die Auswertung je Zeile; teuer pro Zeile wird die Prüfung damit nicht.
- Der Kontext selbst ist ein Primärschlüssel-Zugriff (Backend-PID) mit Abgleich der Transaktions-ID.

## Nachtrag Review R1 (25.09.2026) — Kontextfunktionen und M05-Liste

Anlass: Die rote CI (DoD5) zeigte, dass `m05_list_members()` bei 3 008 synthetischen Mitgliedern (Mandant A nach den Stage-0/M05-Gegenproben) mehrere Sekunden braucht. Messung lokal, PostgreSQL 16.13, gleiche Datenbasis:

| Variante | `m05_list_members()` |
|---|---|
| Kontext wie `master` (inlinebare GUC-Funktion, nur zum Vergleich, zurückgerollt) | 4,4 s |
| C-1 v1.0: `vv_current_tenant()` als `BEGIN ATOMIC`-SQL-Funktion (~160 000 Aufrufe, Neuplanung je verschachtelter Abfrage, ~60 µs) | 8,7 s |
| **C-1 nach R1: `plpgsql` (Plan-Cache je Sitzung) + reale Uhr** | **5,3 s** (3 Läufe: 5,43 / 5,29 / 5,29 s) |
| `basis01_list_persons()` (RLS-InitPlan, 3 033 Zeilen) | 4 ms |

Einordnung: C-1 kostet bei der M05-Liste jetzt rund +20 % statt +100 %. Die Grundlaufzeit (zeilenweise Berechtigung in `m05_member_rows`) stammt aus dem M05-Bestand und gehört nicht zu diesem Bauschritt (Nicht-Ziel). Sie ist als Register-Punkt vorgeschlagen (mengenbasierte Berechtigung), fällig vor Vereinen mit mehreren tausend Mitgliedern.
