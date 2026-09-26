#!/usr/bin/env python3
"""VV — C-1 „Kontext-Signatur" (Bau-Auftrag v1.0, Grill P58): gate-blockierende Gegenproben gegen ECHTE
PostgreSQL 16. Deckt die DoD-Punkte 1–7 auf DB-Ebene ab (8 = Web/e2e, 9–12 = übrige Läufe).

Voraussetzung: migrierte DB mit Seeds, Rollen-Passwörter gesetzt, Keyring (scripts/rotate_ticket_key.sh init),
VV_TICKET_KEYRING zeigt auf den Keyring. Führt am Ende einen ECHTEN Schlüsselwechsel mit dem Betreiber-
Skript durch (DoD 7) — der Keyring zeigt danach auf den neuen Schlüssel.

    VV_PGHOST=localhost PW=change_me_dev_only VV_TICKET_KEYRING=/tmp/ring.json python3 scripts/c1_db_asserts.py

Ausschließlich SYNTHETISCHE Daten (K31). Exit 0 = alle Erwartungen erfüllt.
"""
from __future__ import annotations

import base64
import json
import os
import subprocess
import sys
import threading
import time
import uuid
from pathlib import Path

import psycopg

sys.path.insert(0, str(Path(__file__).resolve().parent))
import vv_ticket  # noqa: E402

HOST = os.environ.get("VV_PGHOST", "localhost")
PW = os.environ.get("PW", "change_me_dev_only")
REPO = Path(__file__).resolve().parent.parent
RING = os.environ.get("VV_TICKET_KEYRING") or sys.exit("VV_TICKET_KEYRING fehlt")
AA = "00000000-0000-0000-0000-0000000000aa"
BB = "00000000-0000-0000-0000-0000000000bb"
SCHRIFT, VORSTAND, ADMIN, TRAINER, ADMIN_B = "sub-schrift-aa", "sub-vorstand-aa", "sub-admin-aa", "sub-trainer-aa", "sub-admin-bb"
P_B = "b0000000-0000-0000-0000-000000000001"          # Person in Mandant B (Seed)
RUN = uuid.uuid4().hex[:6]
RESULTS: list[tuple[str, bool]] = []

# Positivlisten (Bau-Auftrag §2.2/§2.5): exakt diese Funktionen sind ausführbar — sonst nichts.
APP_ALLOW = {
    "vv_set_context(text)", "vv_current_tenant()", "vv_actor()", "vv_audit_log(text,text,jsonb)",
    "vv_policy_any(text,text,text)", "vv_authorize(text,text,text,uuid[],uuid)",
    "rbac_assign_role(uuid,text,uuid,timestamp with time zone,timestamp with time zone)", "rbac_revoke_role(uuid)",
    "rbac_create_scope_node(uuid,text,text)", "basis01_list_persons()", "basis02_list_role_assignments()",
    "m05_type_create(text,text,text,integer,text,integer,uuid)", "m05_type_new_version(uuid,date,integer,text,integer,uuid)",
    "m05_settings_update(integer,integer,integer,integer)", "m05_apply(uuid,text,uuid,date)",
    "m05_admit(uuid,date,integer)", "m05_reject(uuid,integer)", "m05_suspend(uuid,date,integer)",
    "m05_resume(uuid,date,integer)", "m05_change_type(uuid,uuid,date,integer)", "m05_withdraw_notice(uuid,integer)",
    "m05_request_termination(uuid,text,date,text,text,text,date,integer)", "m05_pending_approvals()",
    "m05_decide(uuid,text)", "m05_decide_proposal(uuid,text)", "m05_import_request(text,text,integer)",
    "m05_import_decide(text,text)", "m05_list_members(boolean,text)", "m05_export_members(text,boolean)",
    "m05_get_member(uuid)", "m05_notice_date(date,integer,text)", "m05_today()",
}
WORKER_ALLOW = {
    "vv_worker_context(uuid)", "vv_worker_tenants()", "vv_ticket_housekeeping()",
    "vv_outbox_claim(integer,text[])", "vv_outbox_done(uuid,uuid)", "vv_outbox_fail(uuid,uuid,text,integer)",
    "vv_outbox_renew(uuid,uuid,integer)", "vv_consume_approval(text,text)",
    "m05_execute(uuid)", "m05_job_daily()", "m05_import_apply(text,jsonb)",
}


def conn(user: str) -> psycopg.Connection:
    return psycopg.connect(host=HOST, dbname="vv", user=user, password=PW, autocommit=True)


APP, WK, BOOT = conn("vv_app"), conn("vv_worker"), conn("vv_bootstrap")


def check(name: str, ok: bool, detail: str = "") -> None:
    RESULTS.append((name, bool(ok)))
    print(f"  [{'OK ' if ok else 'FAIL'}] {name}" + (f"  — {detail}" if detail and not ok else ""))


def tx(c, stmts: list[tuple[str, tuple]]):
    """Mehrere Statements in EINER Transaktion; Ergebnis des letzten Statements."""
    with c.transaction():
        cur = c.cursor()
        out = None
        for sql, p in stmts:
            cur.execute(sql, p)
            out = cur.fetchall() if cur.description else None
        return out


def err(fn) -> str:
    try:
        fn()
    except psycopg.Error as e:  # noqa: PERF203
        return str(e).split("\n")[0]
    return ""


def tk(tenant=AA, actor=SCHRIFT, **kw) -> str:
    return vv_ticket.mint(tenant, actor, **kw)


def with_ticket(ticket: str, sql: str, p: tuple = ()):
    return tx(APP, [("SELECT vv_set_context(%s)", (ticket,)), (sql, p)])


def boot(sql: str, p: tuple = ()):
    return tx(BOOT, [(sql, p)])


def raw_ticket(payload: dict, kid: str | None = None, key: bytes | None = None) -> str:
    rk, rkey = vv_ticket.load_keyring(RING)
    return vv_ticket.sign(json.dumps(payload, separators=(",", ":")).encode(), kid or rk, key or rkey)


def main() -> int:
    print(f"== C-1 Kontext-Signatur: DB-Gegenproben (Lauf {RUN}) ==")
    now = int(time.time())

    # ------------------------------------------------------------ DoD 1: Codex-Reproduktion P54 schlägt fehl
    e = err(lambda: tx(APP, [("SELECT set_config('app.tenant_id', %s, true)", (BB,)),
                             ("SELECT id, last_name FROM person WHERE id = %s", (P_B,))]))
    check("DoD1: P54-Repro 1 — set_config(tenant B) + SELECT person als vv_app verweigert", "permission denied" in e, e)
    r = tx(APP, [("SELECT set_config('app.tenant_id', %s, true)", (BB,)),
                 ("SELECT set_config('app.actor', %s, true)", (ADMIN_B,)),
                 ("SELECT vv_current_tenant()::text || '/' || coalesce(vv_actor(), '-')", ())])
    check("DoD1: frei gesetzte GUCs wirken nicht (vv_current_tenant/vv_actor bleiben leer)", r == [(None,)] or r[0][0] is None, str(r))
    e = err(lambda: tx(APP, [("SELECT set_config('app.tenant_id', %s, true)", (BB,)),
                             ("SELECT set_config('app.actor', %s, true)", (ADMIN_B,)),
                             ("SELECT count(*) FROM basis01_list_persons()", ())]))
    check("DoD1: gefälschter Kontext öffnet auch über Funktionen nichts (0 Zeilen / deny)", "deny-by-default" in e, e)
    batch = f"C1R{RUN}"
    e1 = err(lambda: tx(APP, [("SELECT set_config('app.tenant_id', %s, true)", (AA,)),
                              ("SELECT set_config('app.actor', %s, true)", (SCHRIFT,)),
                              ("SELECT m05_import_request(%s, repeat('a', 64), 1)", (batch,))]))
    check("DoD1: P54-Repro 2a — Antrag nur per set_config(actor) verweigert", "deny-by-default" in e1, e1)
    # Echter Antrag (mit Ticket), danach im SELBEN Transaktionsverlauf Wechsel zum Freigeber per set_config:
    e2 = err(lambda: tx(APP, [("SELECT vv_set_context(%s)", (tk(AA, SCHRIFT),)),
                              ("SELECT m05_import_request(%s, repeat('a', 64), 1)", (batch,)),
                              ("SELECT set_config('app.actor', %s, true)", (VORSTAND,)),
                              ("SELECT m05_import_decide(%s, 'approved')", (batch,))]))
    check("DoD1: P54-Repro 2b — Antragsteller + Freigeber in EINER Verbindung per set_config verweigert",
          e2 != "" and ("verbraucht" in e2 or "selbst" in e2 or "deny" in e2), e2)
    e3 = err(lambda: tx(APP, [("SELECT vv_set_context(%s)", (tk(AA, SCHRIFT),)),
                              ("SELECT vv_set_context(%s)", (tk(AA, VORSTAND),))]))
    check("DoD1: Identitätswechsel innerhalb einer Transaktion per zweitem Ticket verweigert", "bereits gesetzt" in e3, e3)
    st = boot("SELECT count(*) FROM approval WHERE subject_ref = %s AND status = 'approved'", (batch,))[0][0]
    check("DoD1: keine Freigabe entstanden (Rollback)", st == 0, str(st))

    # ------------------------------------------------------------ DoD 2: ohne Ticket kein Zugriff, keine Direkt-Grants
    tabs = boot("""
        SELECT n.nspname || '.' || c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname NOT IN ('pg_catalog', 'information_schema') AND n.nspname NOT LIKE 'pg_toast%%'
           AND c.relkind IN ('r', 'p', 'v', 'm', 'S', 'f')
           AND (has_table_privilege('vv_app', c.oid, 'SELECT') OR has_table_privilege('vv_app', c.oid, 'INSERT')
             OR has_table_privilege('vv_app', c.oid, 'UPDATE') OR has_table_privilege('vv_app', c.oid, 'DELETE')
             OR has_table_privilege('vv_app', c.oid, 'TRUNCATE') OR has_table_privilege('vv_app', c.oid, 'REFERENCES')
             OR has_table_privilege('vv_app', c.oid, 'TRIGGER')
             OR (c.relkind <> 'S' AND (has_any_column_privilege('vv_app', c.oid, 'SELECT')
                 OR has_any_column_privilege('vv_app', c.oid, 'INSERT') OR has_any_column_privilege('vv_app', c.oid, 'UPDATE')))
             OR (c.relkind = 'S' AND has_sequence_privilege('vv_app', c.oid, 'USAGE')))""")
    check("DoD2: vv_app hat KEIN direktes Tabellen-/Spalten-/Sequenzrecht (alle Schemata)", tabs == [], str(tabs))
    wtabs = boot("""
        SELECT n.nspname || '.' || c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p', 'v', 'm', 'S')
           AND (c.relkind = 'S' OR has_any_column_privilege('vv_worker', c.oid, 'SELECT')
                OR has_table_privilege('vv_worker', c.oid, 'INSERT') OR has_table_privilege('vv_worker', c.oid, 'UPDATE')
                OR has_table_privilege('vv_worker', c.oid, 'DELETE'))
           AND (c.relkind <> 'S' OR has_sequence_privilege('vv_worker', c.oid, 'USAGE'))""")
    check("DoD2/6: vv_worker hat kein direktes Recht auf Fachtabellen (nur eigenes pgboss-Schema)", wtabs == [], str(wtabs))
    sch = boot("""SELECT string_agg(nspname, ',') FROM pg_namespace
                  WHERE has_schema_privilege('vv_app', oid, 'CREATE') AND nspname NOT LIKE 'pg_temp%%'
                    AND nspname NOT LIKE 'pg_toast_temp%%'""")[0][0]
    tmp = boot("SELECT has_database_privilege('vv_app', current_database(), 'TEMP')::text || '/' || "
               "has_database_privilege('vv_app', current_database(), 'CREATE')::text")[0][0]
    check("DoD2: vv_app kann keine gleichnamigen Objekte anlegen (kein CREATE in Schemata, kein TEMP/CREATE auf DB)",
          sch is None and tmp == "false/false", f"schemas={sch} temp/create={tmp}")
    e = err(lambda: tx(APP, [("CREATE TEMP TABLE vv_ctx (pid int)", ())]))
    check("DoD2: Schatten-Tabelle pg_temp.vv_ctx nicht anlegbar", "permission denied" in e, e)
    fn_app = {r[0] for r in boot("""
        SELECT p.oid::regprocedure::text FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
           AND has_function_privilege('vv_app', p.oid, 'EXECUTE')
           AND (n.nspname = 'public' OR has_schema_privilege('vv_app', n.oid, 'USAGE'))
           AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e')""")}
    check("DoD2: vv_app darf exakt die Positivliste ausführen (keine weiteren Funktionen)", fn_app == APP_ALLOW,
          f"zu viel={sorted(fn_app - APP_ALLOW)} fehlt={sorted(APP_ALLOW - fn_app)}")
    for name, sql in (("Mitgliederliste", "SELECT count(*) FROM m05_list_members()"),
                      ("Personenliste", "SELECT count(*) FROM basis01_list_persons()"),
                      ("Rollenliste", "SELECT count(*) FROM basis02_list_role_assignments()"),
                      ("Offene Freigaben", "SELECT count(*) FROM m05_pending_approvals()"),
                      ("Export", "SELECT count(*) FROM m05_export_members('Prüfung ohne Ticket 2026')"),
                      ("Audit-Eintrag", "SELECT vv_audit_log('app.c1.probe', NULL, '{}')"),
                      ("Mitgliedsart anlegen", f"SELECT m05_type_create('c1_{RUN}','x','aktiv',0,'sofort',NULL,NULL)")):
        e = err(lambda sql=sql: tx(APP, [(sql, ())]))
        check(f"DoD2: ohne Ticket kein Zugriff — {name}", "deny" in e.lower() or "kein" in e.lower(), e)
    e = err(lambda: tx(APP, [("SELECT count(*) FROM vv_ctx", ())]))
    e2 = err(lambda: tx(APP, [("SELECT count(*) FROM ticket_key", ())]))
    e3 = err(lambda: tx(BOOT, [("SET LOCAL ROLE vv_definer", ()), ("SELECT count(*) FROM ticket_key", ())]))
    check("DoD2: Kontext-/Schlüsseltabelle weder für vv_app noch für die Fachfunktions-Rolle lesbar",
          all("permission denied" in x for x in (e, e2, e3)), f"{e} | {e2} | {e3}")
    guc = boot("""SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace AND n.nspname = 'public'
                  WHERE p.prosrc ~ 'current_setting\\(''app\\.' OR p.prosrc ~ 'set_config\\(''app\\.'""")[0][0]
    check("DoD2: keine DB-Funktion liest/setzt mehr eine GUC app.* (Kontext nur geprüft)", guc == 0, str(guc))

    # RLS-Leistung (Bau-Auftrag §4): Kontext wird EINMAL je Abfrage ausgewertet (InitPlan), nicht je Zeile.
    pol = boot("""SELECT count(*) FILTER (WHERE qual = '(tenant_id = ( SELECT vv_current_tenant() AS vv_current_tenant))'),
                         count(*) FROM pg_policies WHERE schemaname = 'public'""")[0]
    plan = tx(BOOT, [("SELECT vv_bootstrap_context(%s, 'system:test')", (AA,)), ("SET LOCAL ROLE vv_definer", ()),
                     ("EXPLAIN SELECT count(*) FROM person", ())])
    check("RLS-Leistung: alle Mandanten-Policies werten den Kontext als InitPlan aus (einmal je Abfrage)",
          pol[0] == pol[1] and pol[1] >= 19 and any("InitPlan" in r[0] for r in plan), f"{pol} {plan}")

    # ------------------------------------------------------------ DoD 3: Fälschung, Ablauf, Manipulation
    good = tk(AA, SCHRIFT)
    v, kid, body, sig = good.split(".")
    flip = sig[:-2] + ("A" if sig[-2] != "A" else "B") + sig[-1]
    payload = json.loads(base64.urlsafe_b64decode(body + "=" * (-len(body) % 4)))
    forged_body = vv_ticket.b64url(json.dumps({**payload, "t": BB}, separators=(",", ":")).encode())
    cases = {
        "falsche Signatur": f"{v}.{kid}.{body}.{flip}",
        "unbekannte Schlüssel-Kennung": f"{v}.zz{RUN}.{body}.{sig}",
        "manipulierte Nutzlast (Mandant B, alte Signatur)": f"{v}.{kid}.{forged_body}.{sig}",
        "abgelaufenes exp": tk(AA, SCHRIFT, iat=now - 120, exp=now - 60),
        "Gültigkeit > 60 s": tk(AA, SCHRIFT, iat=now, exp=now + 61),
        "iat in der Zukunft": tk(AA, SCHRIFT, iat=now + 30, exp=now + 60),
        "Systemakteur im Ticket": tk(AA, "system:worker"),
        "unbekannter Mandant": tk("00000000-0000-0000-0000-00000000dead", SCHRIFT),
        "zusätzliches Feld": raw_ticket({**payload, "jti": str(uuid.uuid4()), "role": "vorstand"}),
        "fehlendes jti": raw_ticket({k: payload[k] for k in ("t", "s", "iat", "exp")}),
        "fremder Schlüssel (richtige Kennung)": vv_ticket.sign(json.dumps(payload, separators=(",", ":")).encode(), kid, os.urandom(32)),
        "Versionspräfix v2": "v2." + good[3:],
        "leeres Ticket": "",
        "Überlänge": "v1." + kid + "." + "A" * 1100 + "." + sig,
    }
    for name, t in cases.items():
        e = err(lambda t=t: with_ticket(t, "SELECT 1"))
        check(f"DoD3: verweigert — {name}", "Ticket verweigert" in e, e)
    ok = with_ticket(good, "SELECT vv_current_tenant()::text, vv_actor()")
    check("DoD3: gültiges Ticket setzt genau Mandant + Akteur aus der Nutzlast", ok == [(AA, SCHRIFT)], str(ok))
    # Ablauf während einer laufenden Transaktion: Kontext endet mit exp (statement_timestamp).
    short = tk(AA, SCHRIFT, iat=now - 58, exp=now + 2)
    with APP.transaction():
        cur = APP.cursor()
        cur.execute("SELECT vv_set_context(%s)", (short,))
        cur.execute("SELECT vv_current_tenant()::text"); before = cur.fetchone()[0]
        time.sleep(3)
        cur.execute("SELECT vv_current_tenant()::text"); after = cur.fetchone()[0]
    check("DoD3: abgelaufenes Ticket verliert den Kontext auch mitten in einer Transaktion", before == AA and after is None,
          f"{before} -> {after}")

    # ------------------------------------------------------------ DoD 4: Mandantentrennung
    rows_a = with_ticket(tk(AA, ADMIN), "SELECT id::text FROM basis01_list_persons()")
    rows_b = with_ticket(tk(BB, ADMIN_B), "SELECT id::text FROM basis01_list_persons()")
    check("DoD4: Ticket für A zeigt nur A, Ticket für B nur B", P_B not in {r[0] for r in rows_a}
          and {r[0] for r in rows_b} == {P_B, *{r[0] for r in rows_b}} and P_B in {r[0] for r in rows_b}
          and not ({r[0] for r in rows_a} & {r[0] for r in rows_b}), f"A={len(rows_a)} B={len(rows_b)}")
    e = err(lambda: with_ticket(tk(AA, ADMIN_B), "SELECT count(*) FROM basis01_list_persons()"))
    check("DoD4: Nutzer aus B mit Ticket für Mandant A hat dort keine Rechte", "deny-by-default" in e, e)
    mb = with_ticket(tk(AA, ADMIN), "SELECT count(*) FROM m05_list_members() WHERE person_id = %s", (P_B,))
    check("DoD4: M05-Lesesicht mit A-Ticket enthält keine B-Personen", mb == [(0,)], str(mb))

    # ------------------------------------------------------------ DoD 5: Einmal-Tickets
    # Mehrfach-Lesen über eine schnelle Lesesicht; jede Einmal-Probe bekommt ein FRISCHES Ticket
    # (Review R1: auf dem CI-Runner lief ein geteiltes Ticket vor dem Export ab -> „abgelaufen“ statt „verbraucht“).
    t0 = tk(AA, VORSTAND)
    reads = [with_ticket(t0, "SELECT count(*) FROM basis01_list_persons()")[0][0] for _ in range(3)]
    check("DoD5: Lesen innerhalb von 60 s mehrfach möglich (3 Transaktionen, selbes Ticket)", len(set(reads)) == 1)
    purpose = "Kassaprüfung C-1 Gegenprobe"
    t1 = tk(AA, VORSTAND)
    with_ticket(t1, "SELECT count(*) FROM m05_export_members(%s)", (purpose,))
    e = err(lambda: with_ticket(t1, "SELECT count(*) FROM m05_export_members(%s)", (purpose,)))
    check("DoD5: zweite verbindliche Aktion mit demselben Ticket verweigert (Export)",
          "verbraucht" in e, e)
    e = err(lambda: with_ticket(t1, "SELECT 1"))
    check("DoD5: verbrauchtes Einmal-Ticket öffnet keinen Kontext mehr", "bereits verbraucht" in e, e)
    t2 = tk(AA, VORSTAND)
    e = err(lambda: tx(APP, [("SELECT vv_set_context(%s)", (t2,)),
                             ("SELECT count(*) FROM m05_export_members(%s)", (purpose,)),
                             ("SELECT count(*) FROM m05_export_members(%s)", (purpose,))]))
    check("DoD5: zwei verbindliche Aktionen in EINER Transaktion mit einem Ticket verweigert", "verbraucht" in e, e)
    ok2 = with_ticket(t2, "SELECT count(*) FROM m05_export_members(%s)", (purpose,))
    check("DoD5: …Rollback gibt das Ticket wieder frei (nur erfolgreiche Aktionen verbrauchen)", ok2 is not None)
    t3 = tk(AA, VORSTAND)
    barrier = threading.Barrier(2)
    outcome: list[str] = []

    def binder():
        c = conn("vv_app")
        try:
            with c.transaction():
                cur = c.cursor()
                cur.execute("SELECT vv_set_context(%s)", (t3,))
                barrier.wait(5)
                cur.execute("SELECT count(*) FROM m05_export_members(%s)", (purpose,))
                time.sleep(0.5)
            outcome.append("ok")
        except psycopg.Error as ex:  # noqa: PERF203
            outcome.append("verbraucht" if "verbraucht" in str(ex) else str(ex).split("\n")[0])
        finally:
            c.close()
    ths = [threading.Thread(target=binder) for _ in range(2)]
    for th in ths:
        th.start()
    for th in ths:
        th.join()
    check("DoD5: parallel — von zwei gleichzeitigen verbindlichen Aktionen mit einem Ticket gewinnt genau eine",
          sorted(outcome) == ["ok", "verbraucht"], str(outcome))
    # Dynamisch zusätzlich: eine echte Freigabe (m05_decide) verbraucht das Ticket; zweite Entscheidung verweigert.
    typ = with_ticket(tk(AA, ADMIN), "SELECT m05_type_create(%s,'C1','unterstuetzend',0,'sofort',NULL,NULL)::text",
                      (f"c1_{RUN}",))[0][0]
    pers = boot("SELECT p.id::text FROM person p WHERE p.tenant_id = %s AND NOT EXISTS "
                "(SELECT 1 FROM member m WHERE m.person_id = p.id) ORDER BY p.id LIMIT 1", (AA,))
    per = None
    if pers:
        per = with_ticket(tk(AA, SCHRIFT), "SELECT m05_apply(%s,%s,%s,m05_today()-10)::text", (pers[0][0], f"C{RUN}", typ))
        with_ticket(tk(AA, SCHRIFT), "SELECT m05_admit(%s, m05_today()-10, 1)", (per[0][0],))
    if per:
        pid = per[0][0]
        ver = boot("SELECT version FROM membership_period WHERE id = %s", (pid,))[0][0]
        appr = with_ticket(tk(AA, SCHRIFT), "SELECT m05_request_termination(%s,'ausgetreten',m05_today(),NULL,NULL,NULL,NULL,%s)::text",
                           (pid, ver))[0][0]
        td = tk(AA, VORSTAND)
        with_ticket(td, "SELECT m05_decide(%s,'rejected')", (appr,))
        e = err(lambda: with_ticket(td, "SELECT m05_decide(%s,'approved')", (appr,)))
        check("DoD5: Freigabe/Ablehnung verbraucht das Ticket (zweite Entscheidung verweigert)", "verbraucht" in e, e)
        who = boot("SELECT status FROM approval WHERE id = %s", (appr,))[0][0]
        check("DoD5: …Entscheidung bleibt die erste (abgelehnt)", who == "rejected", who)
        # Review R1 (Codex M-01): Aging-up-Entscheidung ist einmalig — ein Ticket entscheidet genau EINEN Vorschlag.
        props = [boot("INSERT INTO membership_proposal (tenant_id, period_id, kind, from_type_id, to_type_id, due_date) "
                      "VALUES (%s,%s,'aging_up',%s,%s,m05_today()+%s) RETURNING id::text", (AA, pid, typ, typ, d))[0][0]
                 for d in (400, 401)]
        tp = tk(AA, ADMIN)
        e = err(lambda: tx(APP, [("SELECT vv_set_context(%s)", (tp,)),
                                 ("SELECT m05_decide_proposal(%s,'abgelehnt')", (props[0],)),
                                 ("SELECT m05_decide_proposal(%s,'abgelehnt')", (props[1],))]))
        check("R1/M-01: zwei Aging-up-Entscheidungen mit EINEM Ticket verweigert", "verbraucht" in e, e)
        r1: list = []
        e0 = err(lambda: r1.extend(with_ticket(tp, "SELECT m05_decide_proposal(%s,'abgelehnt')->>'ok'", (props[0],))))
        e = err(lambda: with_ticket(tp, "SELECT m05_decide_proposal(%s,'abgelehnt')", (props[1],)))
        st = boot("SELECT string_agg(status, ',' ORDER BY due_date) FROM membership_proposal WHERE id = ANY(%s::uuid[])",
                  (props,))[0][0]
        check("R1/M-01: …erste Entscheidung wirkt, zweite mit demselben Ticket verweigert",
              r1 == [("true",)] and "verbraucht" in e and st == "abgelehnt,offen", f"{r1} {e0} {e} {st}")
    else:
        check("DoD5: Testperiode für Freigabe-Probe vorhanden", False, "keine aktive Periode im Seed")
    wrap = boot("""SELECT string_agg(p.proname, ',' ORDER BY p.proname) FROM pg_proc p JOIN pg_namespace n
                     ON n.oid = p.pronamespace AND n.nspname = 'public'
                  WHERE p.proname IN ('m05_decide','m05_decide_proposal','m05_import_decide','m05_request_termination',
                                      'm05_import_request','m05_export_members','m05_list_members','rbac_assign_role',
                                      'rbac_revoke_role')
                    AND p.prosrc ~ 'vv_ticket_once' AND p.prosrc ~ '__kern'""")[0][0]
    check("DoD5: alle 9 verbindlichen Befehle verbrauchen das Ticket vor dem fachlichen Kern", wrap and len(wrap.split(",")) == 9,
          str(wrap))
    kern_app = boot("""SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace AND n.nspname = 'public'
                       WHERE p.proname LIKE '%%\\_\\_kern' AND (has_function_privilege('vv_app', p.oid, 'EXECUTE')
                             OR has_function_privilege('vv_worker', p.oid, 'EXECUTE'))""")[0][0]
    check("DoD5: Kernfunktionen (ohne Einmal-Prüfung) sind für App/Worker nicht aufrufbar", kern_app == 0, str(kern_app))

    # ------------------------------------------------------------ DoD 6: Worker-Trennung
    fn_wk = {r[0] for r in boot("""
        SELECT p.oid::regprocedure::text FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname NOT IN ('pg_catalog', 'information_schema', 'pgboss')
           AND has_function_privilege('vv_worker', p.oid, 'EXECUTE')
           AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e')""")}
    check("DoD6: vv_worker darf exakt die feste Systemfunktions-Liste ausführen", fn_wk == WORKER_ALLOW,
          f"zu viel={sorted(fn_wk - WORKER_ALLOW)} fehlt={sorted(WORKER_ALLOW - fn_wk)}")
    check("DoD6: keine Überschneidung Nutzer-Funktionen ↔ Worker-Funktionen", not (fn_wk & (APP_ALLOW - {"vv_current_tenant()", "vv_actor()"})),
          str(fn_wk & APP_ALLOW))
    for label, sql in (("Nutzer-Ticket", f"SELECT vv_set_context('{tk(AA, VORSTAND)}')"),
                       ("Nutzer-Funktion Liste", "SELECT count(*) FROM m05_list_members()"),
                       ("Nutzer-Funktion Freigabe", "SELECT m05_decide(gen_random_uuid(),'approved')"),
                       ("Bootstrap-Kontext", f"SELECT vv_bootstrap_context('{AA}','{VORSTAND}')")):
        e = err(lambda sql=sql: tx(WK, [(sql, ())]))
        check(f"DoD6: Worker verweigert — {label}", "permission denied" in e or "Betreiber" in e, e)
    tx(WK, [("SELECT vv_worker_context(%s)", (AA,))])
    wa = boot("SELECT kind || '/' || actor FROM vv_ctx WHERE pid = %s", (WK.info.backend_pid,))
    check("DoD6: Worker-Akteur ist fest 'system:worker' (Systemkontext)", wa == [("system/system:worker",)], str(wa))
    e = err(lambda: tx(APP, [("SELECT vv_worker_context(%s)", (AA,))]))
    e2 = err(lambda: tx(APP, [("SELECT vv_bootstrap_context(%s, %s)", (AA, VORSTAND))]))
    check("DoD6: App kann weder System- noch Bootstrap-Kontext setzen (Mensch nur mit Ticket)",
          "permission denied" in e and "permission denied" in e2, f"{e} | {e2}")
    e = err(lambda: boot(f"INSERT INTO vv_ctx (pid, xid, kind, tenant, actor) VALUES (1, '1', 'system', '{AA}', '{VORSTAND}')"))
    check("DoD6: Systemkontext kann strukturell keinen menschlichen Akteur tragen (CHECK)", "vv_ctx_kind_ck" in e, e)

    # ------------------------------------------------------------ DoD 7: Schlüsselwechsel (echtes Betreiber-Skript)
    env = dict(os.environ, PGHOST=HOST, PGPASSWORD=PW, KEYRING_FILE=RING, PGUSER="vv_bootstrap", PGDATABASE="vv")
    old_kid, _ = vv_ticket.load_keyring(RING)
    old_t = tk(AA, SCHRIFT)                                  # mit ALTEM Schlüssel signiert
    time.sleep(1.1)                                          # Kennung = Sekundenstempel
    rc = subprocess.run(["bash", str(REPO / "scripts" / "rotate_ticket_key.sh"), "rotate", "--transition-min", "5"],
                        env=env, capture_output=True, text=True)
    new_kid, _ = vv_ticket.load_keyring(RING)
    new_t = tk(AA, SCHRIFT)
    check("DoD7: Wechsel per Betreiber-Skript (neue Kennung im Keyring)", rc.returncode == 0 and new_kid != old_kid,
          rc.stderr[-300:])
    a = err(lambda: with_ticket(old_t, "SELECT 1")); b = err(lambda: with_ticket(new_t, "SELECT 1"))
    check("DoD7: Übergangszeit — alter UND neuer Schlüssel gültig", a == "" and b == "", f"{a} | {b}")
    rc2 = subprocess.run(["bash", str(REPO / "scripts" / "rotate_ticket_key.sh"), "retire", new_kid], env=env,
                         capture_output=True, text=True)
    check("DoD7: aktiver Signaturschlüssel kann nicht versehentlich deaktiviert werden", rc2.returncode != 0)
    rc3 = subprocess.run(["bash", str(REPO / "scripts" / "rotate_ticket_key.sh"), "retire", old_kid], env=env,
                         capture_output=True, text=True)
    a2 = err(lambda: with_ticket(old_t, "SELECT 1"))
    b = err(lambda: with_ticket(tk(AA, SCHRIFT), "SELECT 1"))
    check("DoD7: nach Deaktivierung wird der alte Schlüssel verweigert, der neue gilt",
          rc3.returncode == 0 and "Schlüssel-Kennung" in a2 and b == "", f"{rc3.stderr[-200:]} | {a2} | {b}")
    gone = boot("SELECT (secret IS NULL)::text || '/' || status FROM ticket_key WHERE kid = %s", (old_kid,))[0][0]
    check("DoD7: Geheimnis des deaktivierten Schlüssels gelöscht", gone == "true/disabled", gone)
    ev = boot("""SELECT count(DISTINCT tenant_id)::text || '/' || string_agg(DISTINCT split_part(action, '.', 3), ',' ORDER BY split_part(action, '.', 3))
                   FROM audit_log WHERE action LIKE 'platform.ticket_key.%%' AND subject_ref IN (%s, %s)""",
              (f"ticket_key:{old_kid}", f"ticket_key:{new_kid}"))[0][0]
    ntenants = boot("SELECT count(*) FROM tenant")[0][0]
    check("DoD7: jeder Schritt im Audit jedes Mandanten (added/rotate/transition/disabled)",
          ev.split("/")[0] == str(ntenants) and {"added", "disabled", "rotate", "transition"} <= set(ev.split("/")[1].split(",")), ev)
    leak = boot("SELECT count(*) FROM audit_log WHERE action LIKE 'platform.ticket_key.%%' AND payload::text ~* 'secret|key\"\\s*:\\s*\"[A-Za-z0-9+/]{20,}'")[0][0]
    check("DoD7: Audit enthält nie das Geheimnis", leak == 0, str(leak))
    # Übergangsende (valid_until) greift auch ohne retire
    time.sleep(1.1)
    subprocess.run(["bash", str(REPO / "scripts" / "rotate_ticket_key.sh"), "rotate", "--transition-min", "5"], env=env,
                   capture_output=True, text=True)
    boot("UPDATE ticket_key SET valid_until = now() - interval '1 second' WHERE kid = %s", (new_kid,))
    a = err(lambda: with_ticket(new_t, "SELECT 1"))
    check("DoD7: nach Ende der Übergangszeit (valid_until) wird der alte Schlüssel verweigert", "Schlüssel-Kennung" in a, a)
    e = err(lambda: tx(APP, [("SELECT vv_ticket_key_add('x', '\\x00')", ())]))
    e2 = err(lambda: tx(BOOT, [("SET LOCAL ROLE vv_definer", ()), ("SELECT vv_ticket_key_disable('x')", ())]))
    check("DoD7: Schlüsselverwaltung nur für den Betreiber", "permission denied" in e and "permission denied" in e2, f"{e} | {e2}")

    # ------------------------------------------------------------ Aufräumen (Tagesjob) — nur abgelaufene Kennungen
    boot("INSERT INTO ticket_used (jti, exp_at, action) VALUES (gen_random_uuid(), now() - interval '1 hour', 'c1.probe')")
    hk = tx(WK, [("SELECT vv_ticket_housekeeping()", ())])[0][0]
    left = boot("SELECT count(*) FROM ticket_used WHERE exp_at < now() - interval '10 minutes'")[0][0]
    check("Housekeeping: abgelaufene Einmal-Kennungen werden entfernt (Worker-Systemfunktion)",
          hk["ticket_used_deleted"] >= 1 and left == 0, str(hk))

    # ------------------------------------------------------------ Review R1 (Codex/Gemini): Nachbesserungen
    # H-01: Ablauf gilt gegen die REALE Uhr — auch innerhalb EINER Protokollnachricht und in DO-Blöcken.
    def fresh_app_err(sql_text: str) -> str:
        c = conn("vv_app")
        try:
            c.execute(sql_text)
            return ""
        except psycopg.Error as ex:
            return str(ex).split("\n")[0]
        finally:
            c.close()
    ts = tk(AA, SCHRIFT, ttl=2)
    e = fresh_app_err(f"BEGIN; SELECT vv_set_context('{ts}'); SELECT pg_sleep(3); "
                      f"SELECT count(*) FROM basis01_list_persons(); COMMIT")
    check("R1/H-01: Mehrfachnachricht (eine Protokollnachricht) liest nach Ablauf nichts mehr", "deny-by-default" in e, e)
    ts = tk(AA, SCHRIFT, ttl=2)
    e = err(lambda: tx(APP, [(f"DO $$ DECLARE n int; BEGIN PERFORM vv_set_context('{ts}'); PERFORM pg_sleep(3); "
                              f"SELECT count(*) INTO n FROM basis01_list_persons(); END $$", ())]))
    check("R1/H-01: DO-Block (ein Statement) liest nach Ablauf nichts mehr", "deny-by-default" in e, e)
    ts, ref = tk(AA, SCHRIFT, ttl=2), f"C1EXP{RUN}"
    e = err(lambda: tx(APP, [(f"DO $$ BEGIN PERFORM vv_set_context('{ts}'); PERFORM pg_sleep(3); "
                              f"PERFORM m05_import_request('{ref}', repeat('a', 64), 1); END $$", ())]))
    n_ref = boot("SELECT count(*) FROM approval WHERE subject_ref LIKE %s", (f"%{ref}%",))[0][0]
    check("R1/H-01: verbindliche Aktion nach Ablauf im DO-Block verweigert, nichts angelegt",
          "deny-by-default" in e and n_ref == 0, f"{e} / angelegt={n_ref}")
    ts = tk(AA, SCHRIFT, ttl=30)
    ok_do = err(lambda: tx(APP, [(f"DO $$ DECLARE n int; BEGIN PERFORM vv_set_context('{ts}'); "
                                  f"SELECT count(*) INTO n FROM basis01_list_persons(); "
                                  f"IF n = 0 THEN RAISE EXCEPTION 'leer'; END IF; END $$", ())]))
    check("R1/H-01: Kontrolle — innerhalb der Frist funktioniert derselbe DO-Block", ok_do == "", ok_do)
    ts = tk(AA, VORSTAND, ttl=2)
    e = err(lambda: tx(APP, [(f"DO $$ DECLARE n int; BEGIN PERFORM vv_set_context('{ts}'); PERFORM pg_sleep(3); "
                              f"SELECT count(*) INTO n FROM m05_list_members(); END $$", ())]))
    check("R1/H-01: abgelaufener Kontext liefert bei Listen einen Fehler statt einer (gekürzten) Liste",
          "deny-by-default" in e, e)
    ends = boot("""SELECT count(*) FROM pg_proc WHERE proname IN ('m05_list_members','m05_export_members',
                    'm05_pending_approvals') AND prosrc ~ 'vv_ctx_require_valid'""")[0][0]
    check("R1/H-01: Listen mit zeilenweiser Berechtigung prüfen den Kontext am Ende erneut (3 Funktionen)", ends == 3, str(ends))
    stale = boot("""SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace AND n.nspname = 'public'
                     WHERE p.proname IN ('vv_current_tenant','vv_actor','vv_ctx_kind','vv_ticket_once','vv_set_context')
                       AND (p.prosrc ~ 'statement_timestamp|transaction_timestamp|now\\(\\)'
                            OR p.prosrc !~ 'clock_timestamp')""")[0][0]
    check("R1/H-01: Kontext-/Einmal-Prüfung nutzen ausschließlich die reale Uhr (clock_timestamp)", stale == 0, str(stale))

    # N-01: doppelte Schlüssel in der signierten Nutzlast verweigert (auch wenn der letzte Wert gültig wäre).
    rk, rkey = vv_ticket.load_keyring(RING)
    nw = int(time.time())
    dup = vv_ticket.sign(('{"t":"%s","t":"%s","s":"%s","iat":%d,"exp":%d,"jti":"%s"}'
                          % (BB, AA, ADMIN, nw, nw + 30, uuid.uuid4())).encode(), rk, rkey)
    e = err(lambda: with_ticket(dup, "SELECT 1"))
    check("R1/N-01: doppelter Schlüssel in der Nutzlast verweigert", "Nutzlast" in e, e)

    # Gemini G3 (revidiert): KEINE Toleranz auf exp; bestehende 5-s-Toleranz für iat (DB-Uhr geht nach) belegt.
    ok4 = err(lambda: with_ticket(tk(AA, SCHRIFT, iat=nw + 4, exp=nw + 34), "SELECT 1"))
    e6 = err(lambda: with_ticket(tk(AA, SCHRIFT, iat=nw + 6, exp=nw + 36), "SELECT 1"))
    check("R1/G3: Uhrversatz — iat bis +5 s angenommen (+4 s ok), darüber verweigert (+6 s)",
          ok4 == "" and "Gültigkeitsfenster" in e6, f"{ok4} | {e6}")
    e = err(lambda: with_ticket(tk(AA, SCHRIFT, iat=nw - 60, exp=nw), "SELECT 1"))
    check("R1/G3: exp ohne Toleranz — Ticket mit exp = jetzt verweigert", "abgelaufen" in e, e)

    # N-02: Antragsteller-Bindung auf dem ECHTEN Pfad App -> Definer-Funktion (Testfunktion, zurückgerollt).
    tsp = tk(AA, SCHRIFT)
    res: list[str] = []
    cur = BOOT.cursor()
    cur.execute("BEGIN")   # alles in EINER Transaktion, am Ende zurückgerollt (auch SET SESSION AUTHORIZATION)
    try:
        cur.execute("""CREATE FUNCTION public.c1_probe_approval(p_req text) RETURNS void LANGUAGE sql
                       SECURITY DEFINER SET search_path = public, pg_temp AS $f$
                       INSERT INTO approval (tenant_id, kind, effect_id, subject_ref, requested_by)
                       VALUES (vv_current_tenant(), 'deletion', 'person.delete', 'c1-r1-probe', p_req) $f$""")
        cur.execute("ALTER FUNCTION public.c1_probe_approval(text) OWNER TO vv_definer")
        cur.execute("GRANT EXECUTE ON FUNCTION public.c1_probe_approval(text) TO vv_app")
        cur.execute("SET SESSION AUTHORIZATION vv_app")
        cur.execute("SELECT session_user::text, vv_set_context(%s) IS NOT NULL", (tsp,))
        res.append(cur.fetchone()[0])
        cur.execute("SAVEPOINT s1")
        try:
            cur.execute("SELECT public.c1_probe_approval(%s)", (SCHRIFT,))
            res.append("eigener-ok")
        except psycopg.Error as ex:
            res.append("eigener-FEHLER:" + str(ex).split("\n")[0])
        cur.execute("ROLLBACK TO SAVEPOINT s1")
        try:
            cur.execute("SELECT public.c1_probe_approval(%s)", (VORSTAND,))
            res.append("fremd-ANGENOMMEN")
        except psycopg.Error as ex:
            res.append("fremd-verweigert" if "Spoofing" in str(ex) else "fremd:" + str(ex).split("\n")[0])
        cur.execute("ROLLBACK TO SAVEPOINT s1")
    finally:
        cur.execute("ROLLBACK")
    left_fn = boot("SELECT count(*) FROM pg_proc WHERE proname = 'c1_probe_approval'")[0][0]
    check("R1/N-02: App→Definer-Pfad — eigener Akteur als Antragsteller ok, fremder verweigert (Trigger-Guard)",
          res == ["vv_app", "eigener-ok", "fremd-verweigert"] and left_fn == 0, f"{res} rest={left_fn}")

    fails = [n for n, ok in RESULTS if not ok]
    print("-" * 70)
    print(f"C-1-Gegenproben: {len(RESULTS) - len(fails)}/{len(RESULTS)} erfüllt" + (f" — FEHLGESCHLAGEN: {fails}" if fails else ""))
    out = os.environ.get("VV_C1_REPORT")
    if out:
        Path(out).write_text(json.dumps({"run": RUN, "passed": not fails, "total": len(RESULTS),
                                         "results": [{"name": n, "ok": ok} for n, ok in RESULTS]},
                                        ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
