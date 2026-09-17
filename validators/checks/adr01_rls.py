"""ADR-01: jede mandantenbezogene Tabelle (Spalte tenant_id) hat
ROW LEVEL SECURITY aktiviert UND mindestens eine Policy."""
from __future__ import annotations
import re
import glob
from ..common import REPO, CheckResult, Finding

CREATE_TABLE = re.compile(
    r"CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?([A-Za-z_][\w]*)\s*\((.*?)\);",
    re.IGNORECASE | re.DOTALL,
)


def run() -> CheckResult:
    res = CheckResult(name="RLS + Policy je mandantenbezogener Tabelle", adr="ADR-01")
    sql = "\n".join(
        open(p, encoding="utf-8").read()
        for p in sorted(glob.glob(str(REPO / "db" / "migrations" / "*.sql")))
    )
    if not sql.strip():
        res.findings.append(Finding("ADR-01", False, "keine Migrationen gefunden"))
        return res

    tenant_tables: list[str] = []
    for m in CREATE_TABLE.finditer(sql):
        name, body = m.group(1), m.group(2)
        if re.search(r"\btenant_id\b", body, re.IGNORECASE):
            tenant_tables.append(name)

    if not tenant_tables:
        res.findings.append(Finding("ADR-01", False, "keine mandantenbezogene Tabelle erkannt (tenant_id)"))
        return res

    for t in tenant_tables:
        has_rls = re.search(
            rf"ALTER\s+TABLE\s+{re.escape(t)}\s+ENABLE\s+ROW\s+LEVEL\s+SECURITY",
            sql, re.IGNORECASE)
        has_policy = re.search(
            rf"CREATE\s+POLICY\s+\w+\s+ON\s+{re.escape(t)}\b",
            sql, re.IGNORECASE)
        if has_rls and has_policy:
            res.findings.append(Finding("ADR-01", True, f"{t}: RLS + Policy vorhanden"))
        else:
            missing = []
            if not has_rls:
                missing.append("ENABLE ROW LEVEL SECURITY fehlt")
            if not has_policy:
                missing.append("CREATE POLICY fehlt")
            res.findings.append(Finding("ADR-01", False, f"{t}: " + ", ".join(missing)))
    return res
