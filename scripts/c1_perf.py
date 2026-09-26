#!/usr/bin/env python3
"""VV — C-1 Leistungsmessung (Bau-Auftrag §4: „RLS-Leistung ist zu messen"). Nicht gate-blockierend, Evidenz.

Misst gegen ECHTE PostgreSQL 16 (synthetische Massendaten, Mandant A):
  1. Kosten von vv_set_context (HMAC-Prüfung + Kontextzeile) je Aufruf.
  2. RLS-Filter mit geprüftem Kontext: Policy als InitPlan ((SELECT vv_current_tenant()), Ist-Zustand) gegenüber
     einer Auswertung je Zeile (Vergleich, nur in einer zurückgerollten Transaktion).
  3. Ende-zu-Ende: basis01_list_persons() mit Ticket.
Ausgabe: Markdown auf stdout.   VV_PGHOST=… PW=… VV_TICKET_KEYRING=… python3 scripts/c1_perf.py [N]
"""
from __future__ import annotations
import os, statistics, sys, time, uuid
from pathlib import Path
import psycopg
sys.path.insert(0, str(Path(__file__).resolve().parent))
import vv_ticket  # noqa: E402

HOST = os.environ.get("VV_PGHOST", "localhost"); PW = os.environ.get("PW", "change_me_dev_only")
AA = "00000000-0000-0000-0000-0000000000aa"
N = int(sys.argv[1]) if len(sys.argv) > 1 else 20000
c = lambda u: psycopg.connect(host=HOST, dbname="vv", user=u, password=PW, autocommit=True)
BOOT, APP = c("vv_bootstrap"), c("vv_app")

def ms(f, reps):
    t = []
    for _ in range(reps):
        a = time.perf_counter(); f(); t.append((time.perf_counter() - a) * 1000)
    return statistics.median(t), min(t)

tag = "Perf" + uuid.uuid4().hex[:5]
with BOOT.transaction():
    cur = BOOT.cursor()
    cur.execute("SELECT vv_bootstrap_context(%s,'system:perf')", (AA,))
    cur.execute("INSERT INTO person (tenant_id,last_name,first_name,birth_date) "
                "SELECT %s, %s, 'Synth', date '1990-01-01' + (g %% 9000) FROM generate_series(1,%s) g", (AA, tag, N))
cnt = BOOT.execute("SELECT count(*) FROM person WHERE tenant_id=%s", (AA,)).fetchone()[0]

def set_ctx():
    with APP.transaction():
        APP.execute("SELECT vv_set_context(%s)", (vv_ticket.mint(AA, "sub-admin-aa"),))
m_ctx, _ = ms(set_ctx, 200)

res = {}
for mode in (False, True):
    ts, n, plan = [], 0, ""
    for _ in range(7):
        with BOOT.transaction():
            cur = BOOT.cursor()
            if mode:
                cur.execute("ALTER POLICY person_tenant_isolation ON person USING (tenant_id = vv_current_tenant()) "
                            "WITH CHECK (tenant_id = vv_current_tenant())")
            cur.execute("SELECT vv_bootstrap_context(%s,'system:perf')", (AA,))
            cur.execute("SET LOCAL ROLE vv_definer")
            a = time.perf_counter(); cur.execute("SELECT count(*) FROM person"); n = cur.fetchone()[0]
            ts.append((time.perf_counter() - a) * 1000)
            cur.execute("EXPLAIN SELECT count(*) FROM person"); plan = " / ".join(r[0].strip() for r in cur.fetchall())
            raise psycopg.Rollback()          # Messung verwerfen (ALTER POLICY darf nicht bleiben)
    res[mode] = (statistics.median(ts), n, plan)

def list_persons():
    with APP.transaction():
        APP.execute("SELECT vv_set_context(%s)", (vv_ticket.mint(AA, "sub-admin-aa"),))
        APP.execute("SELECT count(*) FROM basis01_list_persons()").fetchone()
m_list, _ = ms(list_persons, 7)
still = BOOT.execute("SELECT qual FROM pg_policies WHERE tablename='person'").fetchone()[0]
with BOOT.transaction():
    cur = BOOT.cursor(); cur.execute("SELECT vv_bootstrap_context(%s,'system:perf')", (AA,))
    cur.execute("DELETE FROM person WHERE tenant_id=%s AND last_name=%s", (AA, tag))

print(f"""| Messung (PostgreSQL {BOOT.info.server_version // 10000}, Mandant A: {cnt} Personen, davon {N} für die Messung angelegt — alle synthetisch) | Median |
|---|---|
| `vv_set_context` (Ticket prüfen + Kontext setzen, inkl. Roundtrip/Transaktion) | {m_ctx:.2f} ms |
| RLS `count(*)` über person — Policy als **InitPlan** (Ist) | {res[False][0]:.1f} ms |
| RLS `count(*)` über person — Vergleich: Kontext **je Zeile** | {res[True][0]:.1f} ms |
| Ende-zu-Ende `basis01_list_persons()` mit Ticket ({res[False][1]} Zeilen) | {m_list:.1f} ms |

- Plan (Ist): `{res[False][2]}`
- Plan (je Zeile): `{res[True][2]}`
- Policy nach der Messung unverändert: `{still}`""")
