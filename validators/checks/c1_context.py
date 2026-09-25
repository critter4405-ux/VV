"""C-1 „Kontext-Signatur" (Bau-Auftrag v1.0, DoD 10): Mandant/Akteur nur noch über das geprüfte Ticket.

Statisch (immer) — HEURISTIK (Review R1, Codex N-03): ein Regex-Check kann dynamisch gebaute Aufrufe nie
vollständig erkennen. Maßgebliches Gate sind die DB-Invarianten (Live-Teil unten + scripts/c1_db_asserts.py):
selbst eine frei gesetzte GUC wirkt in der DB nicht mehr. Der statische Teil ist die Frühwarnung.
  * Kein App-Code (apps/**/*.ts, inkl. Tests) setzt/liest eine Kontext-GUC app.* per set_config/current_setting
    (Kommentare zählen nicht; Strings schon — SQL steht in Strings).
  * Produktiver App-Code (ohne *.test.ts / test-support) ruft set_config/current_setting ÜBERHAUPT NICHT auf
    und setzt keine Custom-GUC per SET — unabhängig davon, wie der Name gebaut wird ('app.' + 'x', Parameter).
  * Die Web-App (apps/web/src, ohne Tests) enthält kein HMAC-/Schlüsselmaterial (createHmac, WebCrypto
    sign/importKey, TICKET_KEYRING, ticket_key) — sie darf den Ticket-Schlüssel nie sehen.
  * Die jeweils LETZTE Definition von vv_current_tenant()/vv_actor() liest keine GUC und prüft den Ablauf
    gegen die reale Uhr (clock_timestamp, nie statement_timestamp — Review R1, Codex H-01).
Live (VV_VALIDATE_DSN):
  * vv_app hat KEIN direktes Tabellen-/Spalten-/Sequenzrecht (alle Schemata).
  * Keine Funktion im Schema public liest/setzt eine GUC app.*; vv_app hat kein TEMP/CREATE.
  * Jede Funktion, die M05-Perioden/-Arten schreibt, setzt vorher den internen Fachkontext (m05_ctx) —
    ein von der App vorab gesetzter m05.*-Wert kann so nie wirken.
"""
from __future__ import annotations
import glob
import os
import re
from pathlib import Path
from ..common import REPO, CheckResult, Finding, strip_sql_comments

GUC = re.compile(r"""(set_config|current_setting)\s*\(\s*['"]app\.""", re.IGNORECASE)
GUC_SET = re.compile(r"""\bSET\s+(LOCAL\s+)?app\.(tenant_id|actor)\b""", re.IGNORECASE)
KEYMAT = re.compile(r"\bcreateHmac\b|\bsubtle\s*\.\s*(sign|importKey)\b|\bTICKET_KEYRING\b|\bticket_key\b"
                    r"|\bVV_TICKET_KEYRING\b", re.IGNORECASE)
GUC_ANY = re.compile(r"\b(set_config|current_setting)\s*\(", re.IGNORECASE)          # jede Form, auch dynamisch
SET_CUSTOM = re.compile(r"\bSET\s+(?:LOCAL\s+|SESSION\s+)?[a-z_][a-z0-9_]*\.[a-z_][a-z0-9_]*\s*(=|TO)\b", re.IGNORECASE)
FN_DEF = re.compile(r"CREATE\s+(?:OR\s+REPLACE\s+)?FUNCTION\s+(vv_current_tenant|vv_actor)\s*\(\s*\)(.*?)(?=CREATE\s+(?:OR\s+REPLACE\s+)?FUNCTION|\Z)",
                    re.IGNORECASE | re.DOTALL)


def _blank_ts_comments(src: str) -> str:
    """Kommentare (// und /* */) längentreu blanken, Strings bleiben (SQL steht in Strings)."""
    out, i, n, q = list(src), 0, len(src), None
    while i < n:
        c = src[i]
        if q:
            if c == "\\":
                i += 2; continue
            if c == q:
                q = None
            i += 1; continue
        if c in "'\"`":
            q = c; i += 1; continue
        if src.startswith("//", i):
            while i < n and src[i] != "\n":
                out[i] = " "; i += 1
            continue
        if src.startswith("/*", i):
            while i < n and not src.startswith("*/", i):
                if src[i] != "\n":
                    out[i] = " "
                i += 1
            for k in range(i, min(i + 2, n)):
                out[k] = " "
            i += 2; continue
        i += 1
    return "".join(out)


def app_files() -> list[str]:
    return [p for p in glob.glob(str(REPO / "apps" / "**" / "*.ts"), recursive=True) if "node_modules" not in p]


def static_findings(files: list[str] | None = None, migrations: list[str] | None = None) -> list[Finding]:
    out: list[Finding] = []
    for p in sorted(files if files is not None else app_files()):
        rel = os.path.relpath(p, REPO).replace("\\", "/")
        code = _blank_ts_comments(Path(p).read_text(encoding="utf-8"))
        is_test = rel.endswith(".test.ts") or "/test-support/" in rel
        if GUC.search(code) or GUC_SET.search(code):
            out.append(Finding("C-1", False, f"{rel}: setzt/liest Kontext-GUC app.* (nur Ticket/vv_set_context erlaubt)"))
        elif not is_test and (GUC_ANY.search(code) or SET_CUSTOM.search(code)):
            out.append(Finding("C-1", False, f"{rel}: setzt/liest eine GUC (set_config/current_setting/SET x.y) — "
                                             "Kontext nur über vv_set_context(ticket)"))
        if rel.startswith("apps/web/src/") and not rel.endswith(".test.ts") and KEYMAT.search(code):
            out.append(Finding("C-1", False, f"{rel}: Schlüsselmaterial/HMAC in der Web-App (Schlüssel nur Ticket-Dienst + DB)"))
    migs = migrations if migrations is not None else sorted(glob.glob(str(REPO / "db" / "migrations" / "*.sql")))
    last: dict[str, str] = {}
    for m in migs:
        sql = strip_sql_comments(Path(m).read_text(encoding="utf-8") if os.path.exists(m) else m)
        for fm in FN_DEF.finditer(sql):
            last[fm.group(1).lower()] = fm.group(2)
    for fn in ("vv_current_tenant", "vv_actor"):
        body = last.get(fn)
        if body is None:
            out.append(Finding("C-1", False, f"{fn}(): keine Definition gefunden"))
        elif re.search(r"current_setting\s*\(", body, re.IGNORECASE):
            out.append(Finding("C-1", False, f"{fn}(): letzte Definition liest eine GUC (frei setzbar)"))
        elif re.search(r"statement_timestamp|transaction_timestamp|\bnow\s*\(", body, re.IGNORECASE) \
                or not re.search(r"clock_timestamp", body, re.IGNORECASE):
            out.append(Finding("C-1", False, f"{fn}(): Ablaufprüfung nicht gegen die reale Uhr (clock_timestamp)"))
        else:
            out.append(Finding("C-1", True, f"{fn}(): liest nur geprüften Kontext"))
    return out


def run() -> CheckResult:
    res = CheckResult(name="C-1: Kontext nur per Ticket (keine app.*-GUC, kein Schlüssel in der App)", adr="C-1")
    st = static_findings()
    res.findings.extend(st)
    if not any(not f.ok for f in st if "setzt/liest" in f.detail or "Schlüsselmaterial" in f.detail):
        res.findings.append(Finding("C-1", True, f"{len(app_files())} App-Dateien ohne Kontext-GUC; Web ohne Schlüsselmaterial"))
    dsn = os.environ.get("VV_VALIDATE_DSN")
    if not dsn:
        return res                                   # Live-Teil deckt db_live/CI ab (VV_REQUIRE_LIVE)
    try:
        import psycopg  # type: ignore
        with psycopg.connect(dsn) as conn, conn.cursor() as cur:
            cur.execute("""
                SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                 WHERE n.nspname NOT IN ('pg_catalog','information_schema') AND n.nspname NOT LIKE 'pg_toast%%'
                   AND c.relkind IN ('r','p','v','m','S','f')
                   AND (CASE WHEN c.relkind = 'S' THEN has_sequence_privilege('vv_app', c.oid, 'USAGE')
                        ELSE has_any_column_privilege('vv_app', c.oid, 'SELECT') OR has_any_column_privilege('vv_app', c.oid, 'INSERT')
                          OR has_any_column_privilege('vv_app', c.oid, 'UPDATE') OR has_table_privilege('vv_app', c.oid, 'DELETE')
                          OR has_table_privilege('vv_app', c.oid, 'TRUNCATE') END)""")
            n = cur.fetchone()[0]
            res.findings.append(Finding("C-1", n == 0, f"LIVE: direkte Tabellenrechte von vv_app: {n} (Soll 0)"))
            cur.execute("""SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace AND n.nspname = 'public'
                           WHERE p.prosrc ~* '(current_setting|set_config)\\s*\\(\\s*''app\\.'""")
            g = cur.fetchone()[0]
            res.findings.append(Finding("C-1", g == 0, f"LIVE: DB-Funktionen mit app.*-GUC: {g} (Soll 0)"))
            cur.execute("""SELECT coalesce(string_agg(p.proname, ','), '') FROM pg_proc p
                             JOIN pg_namespace n ON n.oid = p.pronamespace AND n.nspname = 'public'
                            WHERE p.prosrc ~* '(UPDATE|INSERT\\s+INTO)\\s+membership_(period|type_assignment)'
                              AND p.prosrc !~ 'm05_ctx\\('""")
            w = cur.fetchone()[0]
            res.findings.append(Finding("C-1", w == "", f"LIVE: M05-Schreibfunktionen ohne internen Fachkontext: "
                                                        f"{w or 'keine'} (Soll keine)"))
            cur.execute("SELECT has_database_privilege('vv_app', current_database(), 'TEMP') "
                        "OR has_database_privilege('vv_app', current_database(), 'CREATE')")
            t = cur.fetchone()[0]
            res.findings.append(Finding("C-1", not t, f"LIVE: vv_app TEMP/CREATE auf DB: {t} (Soll false)"))
    except Exception as e:  # noqa: BLE001
        res.findings.append(Finding("C-1", False, f"LIVE-Check-Fehler: {e}"))
    return res
