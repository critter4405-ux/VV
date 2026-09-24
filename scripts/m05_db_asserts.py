#!/usr/bin/env python3
"""VV — M05 „Mitglieder" + BASIS-02-Kern: adversariale Sicherheits-/Fach-Gegenproben gegen ECHTE
PostgreSQL 16 (gate-blockierend in CI via scripts/ci_db_asserts.sh).

Voraussetzung: migrierte DB mit Seeds (db/seed/*), Rollen-Passwörter gesetzt.
    VV_PGHOST=localhost PW=change_me_dev_only python3 scripts/m05_db_asserts.py

Wiederholbar auf derselben DB (legt eigene synthetische Personen mit Zufalls-IDs an).
Ausschließlich SYNTHETISCHE Daten (K31). Exit 0 = alle Erwartungen erfüllt.
"""
from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys
import uuid
from pathlib import Path

import psycopg

HOST = os.environ.get("VV_PGHOST", "localhost")
PW = os.environ.get("PW", "change_me_dev_only")
REPO = Path(__file__).resolve().parent.parent
AA = "00000000-0000-0000-0000-0000000000aa"
BB = "00000000-0000-0000-0000-0000000000bb"
# Synthetische Principals aus db/seed/0002_m05_synthetic.sql
ADMIN, OBMANN, VORSTAND, SCHRIFT = "sub-admin-aa", "sub-obmann-aa", "sub-vorstand-aa", "sub-schrift-aa"
PRUEF, TRAINER, KINDER, KASSIER = "sub-pruef-aa", "sub-trainer-aa", "sub-kinder-aa", "sub-kassier-aa"
ADMIN_B = "sub-admin-bb"
U18, KM = "5c000000-0000-0000-0000-0000000000a2", "5c000000-0000-0000-0000-0000000000a3"
P_KASSIER = "a0000000-0000-0000-0000-000000000015"
P_ADMIN = "a0000000-0000-0000-0000-000000000001"

RUN = uuid.uuid4().hex[:6]
RESULTS: list[tuple[str, bool, str]] = []


def conn(user: str) -> psycopg.Connection:
    return psycopg.connect(host=HOST, dbname="vv", user=user, password=PW, autocommit=True)


APP, WK, BOOT = conn("vv_app"), conn("vv_worker"), conn("vv_bootstrap")


def run(c, sql, params=(), tenant=AA, actor=None, extra=None):
    """Führt SQL in EINER Transaktion mit Tenant-/Actor-Kontext aus (wie withTenant)."""
    with c.transaction():
        cur = c.cursor()
        if tenant:
            cur.execute("SELECT set_config('app.tenant_id', %s, true)", (tenant,))
        if actor:
            cur.execute("SELECT set_config('app.actor', %s, true)", (actor,))
        for k, v in (extra or {}).items():
            cur.execute("SELECT set_config(%s, %s, true)", (k, v))
        cur.execute(sql, params)
        if not cur.description:
            return None
        # UUIDs als Text (Parameter-Vergleiche mit ->> sind text)
        return [tuple(str(v) if isinstance(v, uuid.UUID) else v for v in r) for r in cur.fetchall()]


def one(*a, **kw):
    rows = run(*a, **kw)
    return rows[0][0] if rows else None


def err(fn) -> str:
    """Erwartet einen Fehler; gibt die Meldung zurück ('' = kein Fehler -> Test schlägt fehl)."""
    try:
        fn()
    except psycopg.Error as e:  # noqa: PERF203
        return str(e).split("\n")[0]
    return ""


def check(name: str, ok: bool, detail: str = "") -> None:
    RESULTS.append((name, bool(ok), detail))
    print(f"  [{'OK ' if ok else 'FAIL'}] {name}" + (f"  — {detail}" if detail and not ok else ""))


def denied(msg: str) -> bool:
    m = msg.lower()
    return "deny-by-default" in m or "permission denied" in m or "keine berechtigung" in m


# ------------------------------------------------------------------ Hilfen (Bootstrap = Onboarding)
def new_person(last: str, birth: str | None, role: str | None = None, scope: str | None = None,
               subject: str | None = None, tenant: str = AA) -> str:
    pid = str(uuid.uuid4())
    run(BOOT, "INSERT INTO person (id, tenant_id, last_name, first_name, birth_date) VALUES (%s,%s,%s,%s,%s)",
        (pid, tenant, f"{last}{RUN}", "Synth", birth), tenant=tenant)
    if role:
        sc = scope or one(BOOT, "SELECT vv_scope_root()", tenant=tenant)
        run(BOOT, "INSERT INTO role_assignment (tenant_id, person_id, role_type, scope_node, scope_node_id, assigned_by)"
                  " VALUES (%s,%s,%s,%s,%s,'system:onboarding')", (tenant, pid, role, sc, sc), tenant=tenant)
    if subject:
        run(BOOT, "SELECT rbac_link_principal(%s,%s,%s)", (tenant, subject, pid), tenant=tenant)
    return pid


def version(period: str) -> int:
    return one(BOOT, "SELECT version FROM membership_period WHERE id=%s", (period,))


def status(period: str) -> str:
    return one(BOOT, "SELECT status FROM membership_period WHERE id=%s", (period,))


def backdate(period: str, **cols) -> None:
    """Bootstrap simuliert Zeitablauf (nur Test). Setzt Fachkontext, sonst blockt der DB-Automat."""
    sets = ", ".join(f"{k} = %s" for k in cols)
    run(BOOT, f"UPDATE membership_period SET {sets} WHERE id = %s", (*cols.values(), period),
        extra={"m05.ctx": "exec", "m05.actor": "system:test"})


def apply_admit(person: str, mno: str, type_id: str, actor=SCHRIFT) -> str:
    per = one(APP, "SELECT m05_apply(%s,%s,%s,m05_today() - 400)", (person, mno, type_id), actor=actor)
    one(APP, "SELECT m05_admit(%s, m05_today() - 400, %s)", (per, version(per)), actor=actor)
    return per


def execute(approval: str):
    return one(WK, "SELECT m05_execute(%s)", (approval,))


def main() -> int:
    print(f"== M05/BASIS-02 DB-Gegenproben (Lauf {RUN}) ==")
    today = one(BOOT, "SELECT m05_today()")

    # ---------------------------------------------------------------- Migrationen idempotent (DoD 2)
    env = dict(os.environ, PGPASSWORD=PW)
    rc = 0
    for f in sorted((REPO / "db" / "migrations").glob("000[6-9]*.sql")):
        rc |= subprocess.run(["psql", "-q", "-v", "ON_ERROR_STOP=1", "-h", HOST, "-U", "vv_bootstrap", "-d", "vv",
                              "-f", str(f)], env=env, capture_output=True).returncode
    check("Migrationen 0006–0009 idempotent (erneuter Lauf fehlerfrei)", rc == 0)

    # ---------------------------------------------------------------- Rollen/Grants (AK-08)
    r = one(BOOT, "SELECT rolsuper::text||rolbypassrls::text FROM pg_roles WHERE rolname='vv_definer'", tenant=None)
    check("vv_definer NOSUPERUSER + NOBYPASSRLS (RLS gilt in Definer-Funktionen)", r == "falsefalse")
    for t in ("member", "membership_period", "membership_status_history", "membership_type_assignment",
              "membership_proposal", "m05_approval_request", "m05_import_batch", "principal_link"):
        e = err(lambda t=t: run(APP, f"SELECT count(*) FROM {t}", actor=ADMIN))
        check(f"vv_app hat keinen Direktzugriff auf {t}", "permission denied" in e, e)
    e = err(lambda: run(APP, "INSERT INTO role_assignment (tenant_id, person_id, role_type, scope_node) "
                             "VALUES (%s,%s,'obmann','x')", (AA, P_ADMIN), actor=ADMIN))
    check("vv_app kann sich keine Rolle direkt eintragen (INSERT role_assignment denied)", "permission denied" in e, e)
    e = err(lambda: run(APP, "UPDATE role_assignment SET revoked_at = now()", actor=ADMIN))
    check("vv_app kann Rollen nicht direkt ändern (UPDATE denied)", "permission denied" in e, e)
    e = err(lambda: run(APP, "SELECT m05_execute(gen_random_uuid())", actor=VORSTAND))
    check("vv_app darf Freigaben nicht ausführen (m05_execute nur Worker)", "permission denied" in e, e)
    e = err(lambda: run(APP, "SELECT m05_job_daily()", actor=ADMIN))
    check("vv_app darf den Tagesjob nicht ausführen", "permission denied" in e, e)
    e = err(lambda: run(APP, "SELECT m05_member_rows(true,'read')", actor=ADMIN))
    check("interne Lesefunktion nicht direkt aufrufbar", "permission denied" in e, e)
    pub = one(BOOT, "SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace AND n.nspname='public' "
                    "WHERE (p.proname LIKE 'm05\\_%%' OR p.proname LIKE 'rbac\\_%%') "
                    "AND has_function_privilege('public', p.oid, 'EXECUTE')", tenant=None)
    check("keine M05/RBAC-Funktion für PUBLIC ausführbar", pub == 0, f"{pub} Funktionen")

    # ---------------------------------------------------------------- Mitgliedsarten (AK-04)
    t_akt = one(APP, "SELECT m05_type_create(%s,'Aktiv','aktiv',1,'jahresende',NULL,NULL)", (f"aktiv_{RUN}",), actor=ADMIN)
    t_unt = one(APP, "SELECT m05_type_create(%s,'Unterstützend','unterstuetzend',0,'sofort',NULL,NULL)",
                (f"unterst_{RUN}",), actor=ADMIN)
    t_jug = one(APP, "SELECT m05_type_create(%s,'Jugend','jugend',0,'monatsende',18,%s)", (f"jugend_{RUN}", t_akt),
                actor=ADMIN)
    check("Mandanten-Admin legt Vereins-Mitgliedsarten an (je mit System-Kategorie)", all([t_akt, t_unt, t_jug]))
    e = err(lambda: run(APP, "SELECT m05_type_create('x_y','X','aktiv')", actor=SCHRIFT))
    check("Schriftführer darf keine Mitgliedsart anlegen (deny)", denied(e), e)
    e = err(lambda: run(APP, "SELECT m05_type_create(%s,'J2','aktiv',0,'sofort',18,%s)", (f"bad_{RUN}", t_akt), actor=ADMIN))
    check("Aging-up-Regel nur bei Kategorie jugend", "nur für Kategorie jugend" in e, e)
    e = err(lambda: run(BOOT, "UPDATE membership_type_version SET notice_months=5 WHERE type_id=%s", (t_akt,)))
    check("Regel-Versionen sind unveränderbar (append-only)", "append-only" in e, e)
    e = err(lambda: run(APP, "SELECT m05_type_new_version(%s, m05_today() - 1, 2, 'sofort')", (t_akt,), actor=ADMIN))
    check("keine rückwirkende Regel-Version", "keine Rückwirkung" in e, e)
    v2 = one(APP, "SELECT m05_type_new_version(%s, m05_today() + 30, 3, 'quartalsende')", (t_unt,), actor=ADMIN)
    check("neue Regel-Version (ab Zukunft) = Version 2", v2 == 2)

    # ---------------------------------------------------------------- Kündigungsstichtag (AK-05)
    cases = [("2026-03-10", 1, "jahresende", "2026-12-31"), ("2026-11-20", 3, "quartalsende", "2027-03-31"),
             ("2026-01-31", 1, "monatsende", "2026-02-28"), ("2026-05-15", 2, "halbjahresende", "2026-12-31"),
             ("2026-05-15", 0, "sofort", "2026-05-15"), ("2026-06-30", 0, "halbjahresende", "2026-06-30")]
    ok = all(str(one(APP, "SELECT m05_notice_date(%s,%s,%s)", (d, m, c), actor=SCHRIFT)) == exp for d, m, c, exp in cases)
    check("Kündigungsstichtag korrekt (6 Fälle inkl. Monatsende/Quartal/Halbjahr)", ok)

    # ---------------------------------------------------------------- Antrag/Aufnahme (AK-01/02)
    p_kurt = new_person("Kicker", "2000-10-10", "spieler", KM)
    p_fritz = new_person("Fremdteam", "1999-11-11", "spieler", KM, subject=f"sub-fritz-{RUN}")
    p_jonas = new_person("Jugend", "2009-01-15", "spieler", U18)
    p_otto = new_person("Ohnedatum", None)
    audit0 = one(BOOT, "SELECT count(*) FROM audit_log WHERE tenant_id=%s", (AA,))
    per_kurt = one(APP, "SELECT m05_apply(%s,%s,%s,m05_today() - 400)", (p_kurt, f"M{RUN}01", t_akt), actor=SCHRIFT)
    check("Schriftführer stellt Antrag (Periode beantragt)", status(per_kurt) == "beantragt")
    e = err(lambda: run(APP, "SELECT m05_apply(%s,%s,%s,m05_today())", (p_fritz, f"M{RUN}99", t_akt), actor=TRAINER))
    check("Trainer darf keinen Antrag stellen (deny)", denied(e), e)
    e = err(lambda: run(APP, "SELECT m05_admit(%s, m05_today(), %s)", (per_kurt, version(per_kurt) + 5), actor=SCHRIFT))
    check("optimistische Nebenläufigkeit: veraltete Version abgelehnt", "veraltete Version" in e, e)
    one(APP, "SELECT m05_admit(%s, m05_today() - 400, %s)", (per_kurt, version(per_kurt)), actor=SCHRIFT)
    check("Aufnahme -> aktiv", status(per_kurt) == "aktiv")
    hist = one(BOOT, "SELECT string_agg(coalesce(from_status,'-')||'>'||to_status, ',' ORDER BY id) "
                     "FROM membership_status_history WHERE period_id=%s", (per_kurt,))
    check("Statusverlauf automatisch (append-only)", hist == "->beantragt,beantragt>aktiv", hist)
    audit1 = one(BOOT, "SELECT count(*) FROM audit_log WHERE tenant_id=%s", (AA,))
    check("jede Zustandsänderung erzeugt Audit-Einträge", audit1 >= audit0 + 2)
    ev = one(BOOT, "SELECT count(*) FROM outbox WHERE tenant_id=%s AND payload->>'period_id'=%s "
                   "AND topic IN ('m05.membership.applied','m05.membership.admitted')", (AA, per_kurt))
    check("Outbox-Events in derselben Transaktion (applied + admitted)", ev == 2, str(ev))
    leak = one(BOOT, "SELECT count(*) FROM outbox WHERE topic LIKE 'm05.%%' AND payload::text ILIKE %s", (f"%Kicker{RUN}%",))
    check("Outbox-Payload ohne Klartext-Personenbezug", leak == 0)
    e = err(lambda: run(APP, "SELECT m05_apply(%s,NULL,%s,m05_today())", (p_kurt, t_akt), actor=SCHRIFT))
    check("keine zweite offene Periode je Mitglied (AK-01)", "offene Mitgliedschaftsperiode" in e, e)
    e = err(lambda: run(APP, "SELECT m05_resume(%s, m05_today(), %s)", (per_kurt, version(per_kurt)), actor=SCHRIFT))
    check("unerlaubter Übergang (aktiv -> Wiederaufnahme) abgewiesen", "nicht möglich" in e, e)
    e = err(lambda: run(BOOT, "UPDATE membership_period SET status='beendet', end_kind='ausgetreten', "
                              "exit_effective_date=m05_today() WHERE id=%s", (per_kurt,)))
    check("DB-Automat: Beendigung ohne Freigabe-Kontext unmöglich (auch als Eigentümer)", "nicht erlaubt" in e, e)
    e = err(lambda: run(BOOT, "UPDATE membership_status_history SET to_status='x' WHERE period_id=%s", (per_kurt,)))
    check("Statusverlauf append-only (UPDATE)", "append-only" in e, e)
    e = err(lambda: run(BOOT, "DELETE FROM membership_period WHERE id=%s", (per_kurt,)))
    check("Periode nicht physisch löschbar", "append-only" in e, e)
    e = err(lambda: run(BOOT, "TRUNCATE membership_status_history"))
    check("Statusverlauf TRUNCATE gesperrt", "append-only" in e, e)

    per_fritz = apply_admit(p_fritz, f"M{RUN}02", t_akt)
    per_jonas = apply_admit(p_jonas, f"M{RUN}03", t_jug)
    per_otto = apply_admit(p_otto, f"M{RUN}04", t_jug)

    # ---------------------------------------------------------------- Ruhen/Wiederaufnahme
    one(APP, "SELECT m05_suspend(%s, m05_today(), %s)", (per_fritz, version(per_fritz)), actor=SCHRIFT)
    one(APP, "SELECT m05_resume(%s, m05_today(), %s)", (per_fritz, version(per_fritz)), actor=OBMANN)
    check("Ruhen + Wiederaufnahme (einfache Aktion)", status(per_fritz) == "aktiv")

    # ---------------------------------------------------------------- Beendigung: Vier-Augen (AK-03)
    e = err(lambda: run(APP, "SELECT m05_request_termination(%s,'ausgetreten',m05_today(),'umzug',NULL,NULL,NULL,%s)",
                        (per_kurt, version(per_kurt)), actor=TRAINER))
    check("Trainer darf keine Beendigung beantragen", denied(e), e)
    appr = one(APP, "SELECT m05_request_termination(%s,'ausgetreten',m05_today(),'umzug',NULL,NULL,NULL,%s)",
               (per_kurt, version(per_kurt)), actor=SCHRIFT)
    exp_eff = one(APP, "SELECT m05_notice_date(m05_today(), 1, 'jahresende')", actor=SCHRIFT)
    ctx = one(BOOT, "SELECT context FROM approval WHERE id=%s", (appr,))
    check("Antrag erzeugt NUR Freigabe-Objekt; Stichtag aus Regel (Frist 1 M., Jahresende)",
          status(per_kurt) == "aktiv" and ctx["effective_date"] == str(exp_eff), str(ctx))
    e = err(lambda: run(APP, "SELECT m05_request_termination(%s,'ausgetreten',m05_today(),NULL,NULL,NULL,NULL,%s)",
                        (per_kurt, version(per_kurt)), actor=OBMANN))
    check("kein zweiter paralleler Beendigungsantrag", "bereits ein Antrag offen" in e, e)
    e = err(lambda: run(APP, "SELECT m05_decide(%s,'approved')", (appr,), actor=SCHRIFT))
    check("Schriftführer (ohne Freigaberecht) kann nicht freigeben", denied(e), e)
    e = err(lambda: execute(appr))
    check("Ausführung ohne Freigabe verweigert", "noch nicht erteilt" in e, e)
    run(APP, "SELECT m05_decide(%s,'approved')", (appr,), actor=OBMANN)
    by = one(BOOT, "SELECT approved_by FROM approval WHERE id=%s", (appr,))
    check("Freigeber = app.actor (DB-seitig)", by == OBMANN, by)
    q = one(BOOT, "SELECT count(*) FROM outbox WHERE topic='m05.execute' AND payload->>'approval_id'=%s", (appr,))
    check("Freigabe erzeugt Ausführungs-Event für den Worker", q == 1)
    res = execute(appr)
    check("Worker führt eingelöste Freigabe aus -> gekündigt (Stichtag in Zukunft)",
          res["outcome"] == "executed" and status(per_kurt) == "gekuendigt", str(res))
    res2 = execute(appr)
    check("Replay der Ausführung = No-Op (idempotent)", res2.get("noop") is True, str(res2))
    c2 = one(WK, "SELECT vv_consume_approval('m05.membership.terminate', %s)", (per_kurt,))
    check("Freigabe ist verbraucht (zweiter Consume leer)", c2 is None)
    ah = one(BOOT, "SELECT approval_id FROM membership_status_history WHERE period_id=%s AND to_status='gekuendigt'", (per_kurt,))
    check("Verlaufseintrag referenziert die Freigabe", str(ah) == str(appr))

    # Selbst-Freigabe (Obmann beantragt, Obmann gibt frei)
    appr_f = one(APP, "SELECT m05_request_termination(%s,'ausgetreten',m05_today(),NULL,NULL,NULL,NULL,%s)",
                 (per_fritz, version(per_fritz)), actor=OBMANN)
    e = err(lambda: run(APP, "SELECT m05_decide(%s,'approved')", (appr_f,), actor=OBMANN))
    check("Selbst-Freigabe (Antragsteller = Freigeber) abgewiesen", "nicht selbst freigeben" in e, e)
    # Parameter-Tausch nach Antrag (Manipulation am Freigabe-Objekt)
    run(APP, "SELECT m05_decide(%s,'approved')", (appr_f,), actor=VORSTAND)
    run(BOOT, "UPDATE approval SET context = jsonb_set(context,'{effective_date}','\"2000-01-01\"') WHERE id=%s", (appr_f,))
    e = err(lambda: execute(appr_f))
    check("Parameter-Tausch nach Freigabe erkannt (Hash-Bindung) -> verweigert", "Manipulation" in e, e)
    check("…und die Freigabe wurde dabei NICHT verbraucht (Rollback)",
          one(BOOT, "SELECT consumed_at IS NULL FROM approval WHERE id=%s", (appr_f,)) is True)
    run(BOOT, "UPDATE approval SET context = (SELECT payload FROM m05_approval_request WHERE approval_id=%s) WHERE id=%s",
        (appr_f, appr_f))

    # Gefälschte Freigabe direkt eingefügt (S0-1/S0-2) + nicht über m05_request_* entstanden
    forged = one(APP, "INSERT INTO approval (tenant_id,kind,effect_id,subject_ref,requested_by,status,approved_by,decided_at) "
                      "VALUES (%s,'legal','m05.membership.terminate',%s,%s,'approved','sub-vorstand-aa',now()) RETURNING id",
                 (AA, per_jonas, SCHRIFT), actor=SCHRIFT)
    st = one(BOOT, "SELECT status||'/'||coalesce(approved_by,'-') FROM approval WHERE id=%s", (forged,))
    check("S0-1: direkt eingefügte Freigabe startet immer als pending (kein Fälschen von 'approved')", st == "pending/-", st)
    e = err(lambda: run(APP, "INSERT INTO approval (tenant_id,kind,effect_id,subject_ref,requested_by) "
                             "VALUES (%s,'legal','m05.membership.terminate',%s,'jemand-anderes')", (AA, per_jonas), actor=SCHRIFT))
    check("S0-2: Antragsteller-Spoofing (requested_by ≠ app.actor) abgewiesen", "Spoofing" in e, e)
    run(APP, "SELECT vv_decide_approval(%s,'approved')", (forged,), actor=VORSTAND)  # Stage-0-Grant direkt
    e = err(lambda: execute(forged))
    check("Freigabe ohne gebundenen M05-Antrag ist nicht ausführbar", "kein geprüfter M05-Antrag" in e, e)

    # Freigeber verliert seine Rolle vor der Ausführung
    per_x = apply_admit(new_person("Rollenverlust", "1990-01-01"), f"M{RUN}05", t_unt)
    appr_x = one(APP, "SELECT m05_request_termination(%s,'verstorben',NULL,NULL,NULL,NULL,m05_today(),%s)",
                 (per_x, version(per_x)), actor=SCHRIFT)
    tmp_vs = f"sub-tmpvs-{RUN}"
    p_tmpvs = new_person("TempVorstand", "1970-01-01", "vorstand", subject=tmp_vs)
    run(APP, "SELECT m05_decide(%s,'approved')", (appr_x,), actor=tmp_vs)
    run(BOOT, "UPDATE role_assignment SET revoked_at=now() WHERE person_id=%s", (p_tmpvs,))
    e = err(lambda: execute(appr_x))
    check("Freigeber ohne (weiterhin gültiges) Freigaberecht -> Ausführung verweigert", "nicht berechtigt" in e, e)

    # Veralteter Antrag (Periode seit Antrag geändert)
    per_s = apply_admit(new_person("Stale", "1991-01-01"), f"M{RUN}06", t_akt)
    appr_s = one(APP, "SELECT m05_request_termination(%s,'ausgetreten',m05_today(),NULL,NULL,NULL,NULL,%s)",
                 (per_s, version(per_s)), actor=SCHRIFT)
    one(APP, "SELECT m05_change_type(%s,%s,m05_today(),%s)", (per_s, t_unt, version(per_s)), actor=SCHRIFT)
    run(APP, "SELECT m05_decide(%s,'approved')", (appr_s,), actor=VORSTAND)
    res = execute(appr_s)
    check("Antrag nach Änderung der Periode = 'stale' (keine Ausführung)", res["outcome"] == "stale" and status(per_s) == "aktiv",
          str(res))
    # Abgelaufene Freigabe
    appr_e = one(APP, "SELECT m05_request_termination(%s,'ausgetreten',m05_today(),NULL,NULL,NULL,NULL,%s)",
                 (per_s, version(per_s)), actor=SCHRIFT)
    run(APP, "SELECT m05_decide(%s,'approved')", (appr_e,), actor=VORSTAND)
    run(BOOT, "UPDATE approval SET expires_at = now() - interval '1 minute' WHERE id=%s", (appr_e,))
    res = execute(appr_e)
    check("abgelaufene Freigabe -> 'expired', keine Wirkung", res["outcome"] == "expired" and status(per_s) == "aktiv", str(res))
    # Ablehnung
    appr_r = one(APP, "SELECT m05_request_termination(%s,'ausgetreten',m05_today(),NULL,NULL,NULL,NULL,%s)",
                 (per_s, version(per_s)), actor=SCHRIFT)
    run(APP, "SELECT m05_decide(%s,'rejected')", (appr_r,), actor=VORSTAND)
    e = err(lambda: execute(appr_r))
    check("abgelehnte Freigabe nicht ausführbar", e != "" or status(per_s) == "aktiv")

    # ---------------------------------------------------------------- Ausschluss (Se) + Feldsicht (AK-07)
    per_f2 = apply_admit(new_person("Ausschluss", "1988-02-02", "spieler", KM), f"M{RUN}07", t_akt)
    e = err(lambda: run(APP, "SELECT m05_request_termination(%s,'ausgeschlossen',NULL,NULL,'satzungsverstoss','VS-2026/07',"
                             "m05_today(),%s)", (per_f2, version(per_f2)), actor=SCHRIFT))
    check("Schriftführer (ohne Se) kann keinen Ausschluss beantragen", denied(e), e)
    e = err(lambda: run(APP, "SELECT m05_request_termination(%s,'ausgeschlossen',NULL,NULL,NULL,'VS-2026/07',m05_today(),%s)",
                        (per_f2, version(per_f2)), actor=OBMANN))
    check("Ausschluss ohne Grundkategorie abgewiesen (kein Freitext)", "Grundkategorie" in e, e)
    appr_a = one(APP, "SELECT m05_request_termination(%s,'ausgeschlossen',NULL,NULL,'satzungsverstoss','VS-2026/07',"
                      "m05_today(),%s)", (per_f2, version(per_f2)), actor=OBMANN)
    pend_sf = run(APP, "SELECT approval_id FROM m05_pending_approvals()", actor=SCHRIFT)
    pend_vs = run(APP, "SELECT payload FROM m05_pending_approvals() WHERE approval_id=%s", (appr_a,), actor=VORSTAND)
    check("offene Freigaben nur für Freigabeberechtigte; Se-Details für Vorstand sichtbar",
          pend_sf == [] and pend_vs and pend_vs[0][0].get("exclusion_code") == "satzungsverstoss")
    run(APP, "SELECT m05_decide(%s,'approved')", (appr_a,), actor=VORSTAND)
    execute(appr_a)
    check("Ausschluss wirkt sofort -> beendet, Aufbewahrung 7 J. (konservativ)",
          status(per_f2) == "beendet" and
          one(BOOT, "SELECT retention_until = m05_today() + interval '7 years' FROM membership_period WHERE id=%s", (per_f2,)))

    def row_for(actor, period, fn="m05_list_members()"):
        rows = run(APP, f"SELECT period_id, member_no, status, exclusion_reason_code, visible_classes FROM {fn}", actor=actor)
        return {str(r[0]): r for r in rows}

    vs, ob, ks, sf, kp, tr = (row_for(a, per_f2) for a in (VORSTAND, OBMANN, KINDER, SCHRIFT, PRUEF, TRAINER))
    check("Se-Ausschlussgrund: Vorstand/Obmann/Kinderschutz sehen ihn",
          all(x.get(per_f2) and x[per_f2][3] == "satzungsverstoss" for x in (vs, ob, ks)))
    check("Se-Ausschlussgrund: Schriftführer/Kassaprüfer sehen ihn NICHT (Spalte leer)",
          all(x.get(per_f2) and x[per_f2][3] is None and x[per_f2][1] is not None for x in (sf, kp)))
    check("Trainer (U18) sieht nur eigenes Team: Jonas ja, Kampfmannschaft nein",
          per_jonas in tr and per_f2 not in tr and per_fritz not in tr, str(list(tr)[:5]))
    check("Trainer sieht Jonas mit S (Mitgliedsnummer)", tr.get(per_jonas) and tr[per_jonas][1] is not None)
    fr = row_for(f"sub-fritz-{RUN}", per_fritz)
    check("Mitglied/Spieler: eigene Daten voll (S), Teamkollege nur Ö",
          fr.get(per_fritz) and fr[per_fritz][1] is not None and fr.get(per_f2) and fr[per_f2][1] is None
          and fr[per_f2][4] == ["Oe"])
    e = err(lambda: run(APP, "SELECT * FROM m05_list_members()", actor="sub-unbekannt"))
    check("unbekannter Actor (ohne Principal) -> deny", denied(e), e)
    e = err(lambda: run(APP, "SELECT * FROM m05_list_members()"))
    check("ohne app.actor -> deny", denied(e), e)
    e = err(lambda: run(APP, "SELECT * FROM m05_list_members()", tenant=None, actor=ADMIN))
    check("ohne Mandantenkontext -> deny", denied(e), e)

    # Export (P50-5)
    e = err(lambda: run(APP, "SELECT * FROM m05_export_members('kurz')", actor=PRUEF))
    check("Export ohne ausreichende Zweckangabe abgewiesen", "Zweckangabe" in e, e)
    e = err(lambda: run(APP, "SELECT * FROM m05_export_members('Kassaprüfung 2026 Mitgliederstand')", actor=TRAINER))
    check("Trainer darf nicht exportieren", denied(e), e)
    ex = run(APP, "SELECT exclusion_reason_code, member_no FROM m05_export_members('Kassaprüfung 2026 Mitgliederstand')",
             actor=PRUEF)
    check("Kassaprüfer exportiert mit Zweck; Export enthält nie Se", ex and all(r[0] is None for r in ex) and
          any(r[1] for r in ex))
    au = one(BOOT, "SELECT count(*) FROM audit_log WHERE action='m05.export' AND payload->>'purpose' LIKE 'Kassaprüfung%%'")
    check("Export mit Zweck protokolliert", au >= 1)

    # ---------------------------------------------------------------- Jobs: Stichtag, Sperre, Frist (AK-12)
    backdate(per_kurt, exit_effective_date=today)  # Stichtag erreicht (Test-Zeitraffer)
    j = one(WK, "SELECT m05_job_daily()")
    check("Tagesjob: gekündigt -> beendet am Stichtag", status(per_kurt) in ("beendet", "gesperrt"), str(j))
    check("Tagesjob: beendet -> gesperrt (Sperr-Nachlauf 0 Tage)", status(per_kurt) == "gesperrt")
    j2 = one(WK, "SELECT m05_job_daily()")
    check("Tagesjob idempotent (zweiter Lauf ändert nichts)", j2["ended"] == 0 and j2["locked"] == 0, str(j2))
    lst = row_for(SCHRIFT, per_kurt)
    check("gesperrte Periode nicht in normaler Liste", per_kurt not in lst)
    e = err(lambda: run(APP, "SELECT * FROM m05_list_members(true, NULL)", actor=OBMANN))
    check("gesperrte Daten nur mit Zweckangabe", "Zweckangabe" in e, e)
    backdate(per_kurt, retention_until=today)
    j3 = one(WK, "SELECT m05_job_daily()")
    appr_an = one(BOOT, "SELECT approval_id FROM m05_approval_request WHERE period_id=%s AND effect_id='m05.membership.anonymize' "
                        "AND closed_at IS NULL", (per_kurt,))
    check("Fristablauf -> Anonymisierungs-ANTRAG (nicht Ausführung)", appr_an is not None and status(per_kurt) == "gesperrt",
          str(j3))
    j4 = one(WK, "SELECT m05_job_daily()")
    check("kein doppelter Anonymisierungsantrag", j4["anonymize_requested"] == 0)
    run(APP, "SELECT m05_decide(%s,'approved')", (appr_an,), actor=VORSTAND)
    execute(appr_an)
    m = run(BOOT, "SELECT m.person_id, m.member_no, p.end_reason_code, p.status, extract(doy FROM p.entry_date) "
                  "FROM membership_period p JOIN member m ON m.id=p.member_id WHERE p.id=%s", (per_kurt,))[0]
    check("Anonymisierung: Personenbezug + Gründe entfernt, Daten auf Jahr gekürzt",
          m[0] is None and m[1] is None and m[2] is None and m[3] == "anonymisiert" and int(m[4]) == 1, str(m))
    e = err(lambda: run(BOOT, "UPDATE membership_period SET status='aktiv' WHERE id=%s", (per_kurt,),
                        extra={"m05.ctx": "exec"}))
    check("anonymisierte Periode endgültig", "endgültig" in e, e)

    # ---------------------------------------------------------------- Kündigung zurücknehmen
    appr_w = one(APP, "SELECT m05_request_termination(%s,'ausgetreten',m05_today(),NULL,NULL,NULL,NULL,%s)",
                 (per_s, version(per_s)), actor=SCHRIFT)
    # per_s ist 'unterstuetzend' (Frist 0, sofort) -> Stichtag heute -> sofort beendet; daher Artwechsel-freie Periode nehmen
    run(APP, "SELECT m05_decide(%s,'rejected')", (appr_w,), actor=VORSTAND)
    per_w = apply_admit(new_person("Ruecknahme", "1993-03-03"), f"M{RUN}08", t_akt)
    appr_w2 = one(APP, "SELECT m05_request_termination(%s,'ausgetreten',m05_today(),NULL,NULL,NULL,NULL,%s)",
                  (per_w, version(per_w)), actor=SCHRIFT)
    run(APP, "SELECT m05_decide(%s,'approved')", (appr_w2,), actor=OBMANN)
    execute(appr_w2)
    one(APP, "SELECT m05_withdraw_notice(%s,%s)", (per_w, version(per_w)), actor=SCHRIFT)
    check("Kündigung vor Stichtag zurückgenommen -> aktiv, Beendigungsdaten leer",
          status(per_w) == "aktiv" and one(BOOT, "SELECT end_kind IS NULL FROM membership_period WHERE id=%s", (per_w,)))

    # ---------------------------------------------------------------- Aging-up (AK-06)
    run(APP, "SELECT m05_settings_update(0, 7, 180)", actor=ADMIN)
    one(BOOT, "UPDATE person SET birth_date = m05_today() - interval '18 years' + interval '10 days' WHERE id=%s", (p_jonas,))
    j5 = one(WK, "SELECT m05_job_daily()")
    j6 = one(WK, "SELECT m05_job_daily()")
    props = run(BOOT, "SELECT id, status FROM membership_proposal WHERE period_id=%s", (per_jonas,))
    check("Aging-up: genau EIN Vorschlag je Periode × Stichtag (idempotent)", len(props) == 1 and j6["aging_up_proposed"] == 0,
          f"{j5} / {j6}")
    cur_t = one(BOOT, "SELECT (m05_current_type(%s, m05_today() + 30)).type_id", (per_jonas,), tenant=AA)
    check("ohne Bestätigung ändert sich die Art NICHT", str(cur_t) == str(t_jug))
    miss = one(BOOT, "SELECT count(*) FROM outbox WHERE topic='m05.aging_up.data_missing' AND payload->>'period_id'=%s",
               (per_otto,))
    check("Jugend ohne Geburtsdatum -> Hinweis-Event statt stiller Annahme", miss == 1)
    e = err(lambda: run(APP, "SELECT m05_decide_proposal(%s,'bestaetigt')", (props[0][0],), actor=TRAINER))
    check("Trainer kann Aging-up nicht bestätigen", denied(e), e)
    run(APP, "SELECT m05_decide_proposal(%s,'bestaetigt')", (props[0][0],), actor=SCHRIFT)
    cur_t2 = one(BOOT, "SELECT (m05_current_type(%s, m05_today() + 30)).type_id", (per_jonas,), tenant=AA)
    src = one(BOOT, "SELECT source FROM membership_type_assignment WHERE period_id=%s ORDER BY id DESC LIMIT 1", (per_jonas,))
    check("bestätigter Vorschlag -> Artwechsel zum Stichtag (Quelle aging_up)", str(cur_t2) == str(t_akt) and src == "aging_up")
    run(APP, "SELECT m05_settings_update(0, 7, 30)", actor=ADMIN)
    e = err(lambda: run(APP, "SELECT m05_settings_update(0, 3, 30)", actor=ADMIN))
    check("Aufbewahrung nie unter 7 J. konfigurierbar (P50-9)", "check" in e.lower() or "violates" in e.lower(), e)

    # ---------------------------------------------------------------- BASIS-02: SoD, Selbst-Zuweisung (AK-09)
    root = one(BOOT, "SELECT vv_scope_root()", tenant=AA)
    rr = one(APP, "SELECT rbac_assign_role(%s,'kassapruefer',%s)", (P_KASSIER, root), actor=ADMIN)
    check("SoD-Kern: Kassier -> Kassaprüfer blockiert (Ergebnis statt Fehler)", rr["ok"] is False and rr["reason"] == "sod_kern",
          str(rr))
    au = one(BOOT, "SELECT count(*) FROM audit_log WHERE action='rbac.assign.sod_blocked' AND subject_ref=%s", (P_KASSIER,))
    check("versuchte SoD-Verletzung ist protokolliert", au >= 1)
    e = err(lambda: run(BOOT, "INSERT INTO role_assignment (tenant_id,person_id,role_type,scope_node,scope_node_id) "
                              "VALUES (%s,%s,'kassapruefer',%s,%s)", (AA, P_KASSIER, root, root)))
    check("SoD-Kern: DB-Trigger blockt auch direkten Eintrag (kein Override)", "SoD-Kern" in e, e)
    rr = one(APP, "SELECT rbac_assign_role(%s,'obmann',%s)", (P_ADMIN, root), actor=ADMIN)
    check("Selbst-Zuweisung verboten", rr["ok"] is False and rr["reason"] == "selbst_zuweisung_verboten", str(rr))
    e = err(lambda: run(APP, "SELECT rbac_assign_role(%s,'trainer',%s)", (p_fritz, U18), actor=OBMANN))
    check("Obmann (ohne Zuweisungsrecht) kann keine Rollen vergeben", denied(e), e)
    rr = one(APP, "SELECT rbac_assign_role(%s,'betreuer',%s)", (p_fritz, U18), actor=ADMIN)
    check("Mandanten-Admin vergibt Rolle an Scope-Knoten", rr["ok"] is True, str(rr))
    e = err(lambda: run(BOOT, "UPDATE role_assignment SET role_type='obmann' WHERE id=%s", (rr["id"],)))
    check("bestehende Zuweisung nicht umdeutbar (nur Widerruf)", "nur Widerruf" in e, e)

    # ---------------------------------------------------------------- Mandantentrennung (AK-10)
    b_rows = run(APP, "SELECT period_id FROM m05_list_members()", tenant=BB, actor=ADMIN_B)
    check("Mandant B sieht keine Mitglieder von A", b_rows == [], str(b_rows))
    e = err(lambda: run(APP, "SELECT * FROM m05_list_members()", tenant=BB, actor=OBMANN))
    check("Actor aus A ist in B unbekannt (deny)", denied(e), e)
    e = err(lambda: run(APP, "SELECT m05_admit(%s,m05_today(),1)", (per_jonas,), tenant=BB, actor=ADMIN_B))
    check("Mandant B kann Periode aus A nicht verändern", denied(e) or "nicht gefunden" in e, e)
    e = err(lambda: run(BOOT, "INSERT INTO member (tenant_id, person_id, member_no) VALUES (%s,%s,'X1')", (BB, p_jonas),
                        tenant=BB))
    check("zusammengesetzter FK: kein Mitglied auf Person eines fremden Mandanten", "violates foreign key" in e, e)
    ok_iso = True
    try:
        run(WK, "SELECT m05_execute(%s)", (appr_a,), tenant=BB)
        ok_iso = False
    except psycopg.Error:
        pass
    check("Worker im fremden Mandanten findet die Freigabe nicht", ok_iso)

    # ---------------------------------------------------------------- Import (AK-11)
    p_i1 = new_person("ImportEins", "1995-01-01")
    p_i2 = new_person("ImportZwei", "1996-02-02")
    rows = [
        {"member_no": f"I{RUN}1", "person_id": p_i1, "type_code": f"aktiv_{RUN}", "entry_date": "2019-03-01", "status": "aktiv"},
        {"member_no": f"I{RUN}2", "person_id": p_i2, "type_code": f"aktiv_{RUN}", "entry_date": "2015-01-01",
         "status": "beendet", "exit_effective_date": "2024-12-31", "end_kind": "ausgetreten"},
        {"member_no": f"I{RUN}3", "person_id": p_i1, "type_code": f"aktiv_{RUN}", "entry_date": "2020-01-01", "status": "aktiv"},
        {"member_no": f"I{RUN}4", "person_id": str(uuid.uuid4()), "type_code": "gibtsnicht", "entry_date": "2020-01-01",
         "status": "aktiv"},
    ]
    rows_json = json.dumps(rows)
    h = one(BOOT, "SELECT encode(digest(convert_to(%s::jsonb::text,'UTF8'),'sha256'),'hex')", (rows_json,), tenant=None)
    batch = f"B{RUN}"
    e = err(lambda: run(APP, "SELECT m05_import_request(%s,%s,%s)", (batch, h, 4), actor=TRAINER))
    check("Trainer darf keinen Import beantragen", denied(e), e)
    run(APP, "SELECT m05_import_request(%s,%s,%s)", (batch, h, 4), actor=SCHRIFT)
    e = err(lambda: run(WK, "SELECT m05_import_apply(%s,%s::jsonb)", (batch, rows_json)))
    check("Import ohne Freigabe verweigert", "Freigeber nicht berechtigt" in e or "keine gültige" in e, e)
    e = err(lambda: run(APP, "SELECT m05_import_decide(%s,'approved')", (batch,), actor=SCHRIFT))
    check("Import-Selbstfreigabe/ohne Recht abgewiesen", e != "", e)
    run(APP, "SELECT m05_import_decide(%s,'approved')", (batch,), actor=VORSTAND)
    tampered = json.dumps(rows[:3] + [dict(rows[3], type_code=f"aktiv_{RUN}")])
    e = err(lambda: run(WK, "SELECT m05_import_apply(%s,%s::jsonb)", (batch, tampered)))
    check("Import mit anderen als den freigegebenen Zeilen verweigert (Hash)", "weichen" in e, e)
    rep = one(WK, "SELECT m05_import_apply(%s,%s::jsonb)", (batch, rows_json))
    codes = sorted(c["code"] for c in rep["konflikte"])
    check("Import: 2 neu, Konflikte gemeldet statt übernommen",
          rep["neu"] == 2 and codes == ["person_andere_mitgliedsnummer", "unbekannte_mitgliedsart"], str(rep))
    check("Import-Report ohne Klartext-Personenbezug", f"Import{RUN}" not in json.dumps(rep))
    rep2 = one(WK, "SELECT m05_import_apply(%s,%s::jsonb)", (batch, rows_json))
    check("gleicher Batch erneut = No-Op", rep2.get("noop") is True)
    batch2 = f"C{RUN}"
    rows2 = json.dumps(rows[:2])
    h2 = one(BOOT, "SELECT encode(digest(convert_to(%s::jsonb::text,'UTF8'),'sha256'),'hex')", (rows2,), tenant=None)
    run(APP, "SELECT m05_import_request(%s,%s,%s)", (batch2, h2, 2), actor=OBMANN)
    e = err(lambda: run(APP, "SELECT m05_import_decide(%s,'approved')", (batch2,), actor=OBMANN))
    check("Import: Antragsteller kann nicht selbst freigeben", "nicht selbst freigeben" in e, e)
    run(APP, "SELECT m05_import_decide(%s,'approved')", (batch2,), actor=VORSTAND)
    rep3 = one(WK, "SELECT m05_import_apply(%s,%s::jsonb)", (batch2, rows2))
    check("neuer Batch mit gleichen Zeilen: idempotent (alles unverändert)", rep3["neu"] == 0 and rep3["unveraendert"] == 2,
          str(rep3))
    j7 = one(WK, "SELECT m05_job_daily()")
    imp_st = one(BOOT, "SELECT p.status FROM membership_period p JOIN member m ON m.id=p.member_id WHERE m.member_no=%s",
                 (f"I{RUN}2",))
    check("importierte ausgetretene Mitgliedschaft wird gesperrt (Art. 18)", imp_st == "gesperrt", f"{imp_st} {j7}")

    # ---------------------------------------------------------------- Audit-Kette intakt (ADR-05)
    bad = one(BOOT, """
      WITH o AS (SELECT *, lag(entry_hash) OVER (ORDER BY id) AS lh FROM audit_log WHERE tenant_id = %s)
      SELECT count(*) FROM o WHERE prev_hash IS DISTINCT FROM lh OR entry_hash <> encode(digest(convert_to(
        jsonb_build_object('id', id, 'tenant_id', tenant_id, 'actor', actor, 'action', action,
          'subject_ref', subject_ref, 'payload', payload, 'occurred_at', occurred_at, 'prev_hash', prev_hash)::text,
        'UTF8'), 'sha256'), 'hex')""", (AA,), tenant=None)
    check("Audit-Hash-Kette von Mandant A vollständig verifiziert (kein Bruch, kein Fork)", bad == 0, f"{bad} Abweichungen")
    # Personennamen (z. B. 'Kicker<RUN>') und Mitgliedsnummern ('M<RUN>..', 'I<RUN>..') dürfen nie im Audit stehen.
    pii = one(BOOT, "SELECT count(*) FROM audit_log WHERE (action LIKE 'm05.%%' OR action LIKE 'rbac.%%') "
                    "AND payload::text ~ %s", (f"[A-Za-z]+{RUN}",))
    check("M05-Audit-Payloads ohne Klartext-Namen/Nummern", pii == 0, str(pii))

    fails = [n for n, ok, _ in RESULTS if not ok]
    print("-" * 70)
    print(f"M05-Gegenproben: {len(RESULTS) - len(fails)}/{len(RESULTS)} erfüllt" + (f" — FEHLGESCHLAGEN: {fails}" if fails else ""))
    out = os.environ.get("VV_M05_REPORT")
    if out:
        Path(out).write_text(json.dumps({"run": RUN, "passed": not fails, "total": len(RESULTS),
                                         "results": [{"name": n, "ok": ok} for n, ok, _ in RESULTS]},
                                        ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
