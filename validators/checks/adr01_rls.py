"""ADR-01: jede mandantenbezogene Tabelle (Spalte tenant_id) hat FORCE ROW LEVEL SECURITY
UND mindestens eine Policy. WP5-gehärtet gegen die im Review gefundenen Umgehungen:
- Kommentare werden entfernt (auskommentierte Schein-RLS zählt nicht).
- Statements werden einzeln geparst (Multi-DDL in einer Datei: jede Tabelle wird geprüft).
- Reihenfolge über alle Dateien: spätere DISABLE RLS / DROP POLICY / NO FORCE heben auf.
"""
from __future__ import annotations
import re
import glob
from ..common import REPO, CheckResult, Finding, strip_sql_comments

CREATE_TABLE = re.compile(r"CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?([A-Za-z_]\w*)\s*\((.*?)\)\s*;",
                          re.IGNORECASE | re.DOTALL)
ENABLE = re.compile(r"ALTER\s+TABLE\s+([A-Za-z_]\w*)\s+ENABLE\s+ROW\s+LEVEL\s+SECURITY", re.IGNORECASE)
FORCE = re.compile(r"ALTER\s+TABLE\s+([A-Za-z_]\w*)\s+FORCE\s+ROW\s+LEVEL\s+SECURITY", re.IGNORECASE)
NOFORCE = re.compile(r"ALTER\s+TABLE\s+([A-Za-z_]\w*)\s+NO\s+FORCE\s+ROW\s+LEVEL\s+SECURITY", re.IGNORECASE)
DISABLE = re.compile(r"ALTER\s+TABLE\s+([A-Za-z_]\w*)\s+DISABLE\s+ROW\s+LEVEL\s+SECURITY", re.IGNORECASE)
CREATE_POLICY = re.compile(r"CREATE\s+POLICY\s+([A-Za-z_]\w*)\s+ON\s+([A-Za-z_]\w*)", re.IGNORECASE)
DROP_POLICY = re.compile(r"DROP\s+POLICY\s+(?:IF\s+EXISTS\s+)?([A-Za-z_]\w*)\s+ON\s+([A-Za-z_]\w*)", re.IGNORECASE)


def run() -> CheckResult:
    res = CheckResult(name="RLS FORCE + Policy je mandantenbezogener Tabelle", adr="ADR-01")
    files = sorted(glob.glob(str(REPO / "db" / "migrations" / "*.sql")))
    if not files:
        res.findings.append(Finding("ADR-01", False, "keine Migrationen gefunden")); return res

    tenant_tables: dict[str, bool] = {}   # name -> ist tenant-bezogen
    enabled: set[str] = set(); forced: set[str] = set()
    policies: dict[str, set[str]] = {}

    for p in files:
        sql = strip_sql_comments(open(p, encoding="utf-8").read())
        for m in CREATE_TABLE.finditer(sql):
            name, body = m.group(1), m.group(2)
            if re.search(r"\btenant_id\b", body, re.IGNORECASE):
                tenant_tables.setdefault(name, True)
        for m in ENABLE.finditer(sql): enabled.add(m.group(1))
        for m in FORCE.finditer(sql): forced.add(m.group(1))
        for m in NOFORCE.finditer(sql): forced.discard(m.group(1))
        for m in DISABLE.finditer(sql): enabled.discard(m.group(1))
        for m in CREATE_POLICY.finditer(sql):
            policies.setdefault(m.group(2), set()).add(m.group(1))
        for m in DROP_POLICY.finditer(sql):
            policies.get(m.group(2), set()).discard(m.group(1))

    if not tenant_tables:
        res.findings.append(Finding("ADR-01", False, "keine mandantenbezogene Tabelle (tenant_id) erkannt")); return res

    for t in sorted(tenant_tables):
        miss = []
        if t not in enabled: miss.append("ENABLE RLS fehlt/aufgehoben")
        if t not in forced: miss.append("FORCE RLS fehlt/aufgehoben")
        if not policies.get(t): miss.append("keine (aktive) Policy")
        if miss:
            res.findings.append(Finding("ADR-01", False, f"{t}: " + ", ".join(miss)))
        else:
            res.findings.append(Finding("ADR-01", True, f"{t}: ENABLE+FORCE+Policy"))
    return res
