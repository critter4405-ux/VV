"""ADR-01: jede mandantenbezogene Tabelle (Spalte tenant_id) hat FORCE ROW LEVEL SECURITY
UND mindestens eine Policy. WP5-gehärtet gegen die im Review gefundenen Umgehungen:
- Kommentare werden entfernt (auskommentierte Schein-RLS zählt nicht).
- Statements werden einzeln geparst (Multi-DDL in einer Datei: jede Tabelle wird geprüft).
- Reihenfolge über alle Dateien: spätere DISABLE RLS / DROP POLICY / NO FORCE heben auf.
"""
from __future__ import annotations
import re
import glob
from pathlib import Path
from ..common import REPO, CheckResult, Finding, strip_sql_comments

CREATE_TABLE = re.compile(r"CREATE\s+(?:(?:GLOBAL|LOCAL)\s+)?(?:UNLOGGED\s+|TEMP(?:ORARY)?\s+)?TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?([A-Za-z_]\w*)\s*\((.*?)\)\s*;",
                          re.IGNORECASE | re.DOTALL)
ENABLE = re.compile(r"ALTER\s+TABLE\s+([A-Za-z_]\w*)\s+ENABLE\s+ROW\s+LEVEL\s+SECURITY", re.IGNORECASE)
FORCE = re.compile(r"ALTER\s+TABLE\s+([A-Za-z_]\w*)\s+FORCE\s+ROW\s+LEVEL\s+SECURITY", re.IGNORECASE)
NOFORCE = re.compile(r"ALTER\s+TABLE\s+([A-Za-z_]\w*)\s+NO\s+FORCE\s+ROW\s+LEVEL\s+SECURITY", re.IGNORECASE)
DISABLE = re.compile(r"ALTER\s+TABLE\s+([A-Za-z_]\w*)\s+DISABLE\s+ROW\s+LEVEL\s+SECURITY", re.IGNORECASE)
CREATE_POLICY = re.compile(r"CREATE\s+POLICY\s+([A-Za-z_]\w*)\s+ON\s+([A-Za-z_]\w*)", re.IGNORECASE)
DROP_POLICY = re.compile(r"DROP\s+POLICY\s+(?:IF\s+EXISTS\s+)?([A-Za-z_]\w*)\s+ON\s+([A-Za-z_]\w*)", re.IGNORECASE)


def analyze(sql_texts: list[str]) -> dict[str, list[str]]:
    """Wertet Migrationen in TEXTUELLER Reihenfolge aus (Datei für Datei, Statement für Statement).
    M05-Bau: vorher wurden je Datei erst alle CREATE POLICY und DANACH alle DROP POLICY angewandt —
    das idempotente Muster `DROP POLICY IF EXISTS p; CREATE POLICY p` galt dadurch fälschlich als
    „keine Policy" (False-Negative), während ein echtes `CREATE ...; DROP ...` korrekt ROT wäre.
    Rückgabe: Tabelle -> Liste fehlender Eigenschaften (leer = ok)."""
    tenant_tables: dict[str, bool] = {}
    enabled: set[str] = set(); forced: set[str] = set()
    policies: dict[str, set[str]] = {}
    for raw in sql_texts:
        sql = strip_sql_comments(raw)
        events: list[tuple[int, str, re.Match]] = []
        for kind, rx in (("table", CREATE_TABLE), ("enable", ENABLE), ("force", FORCE), ("noforce", NOFORCE),
                         ("disable", DISABLE), ("cpol", CREATE_POLICY), ("dpol", DROP_POLICY)):
            events.extend((m.start(), kind, m) for m in rx.finditer(sql))
        for _, kind, m in sorted(events, key=lambda e: e[0]):
            if kind == "table":
                if re.search(r"\btenant_id\b", m.group(2), re.IGNORECASE):
                    tenant_tables.setdefault(m.group(1), True)
            elif kind == "enable": enabled.add(m.group(1))
            elif kind == "force": forced.add(m.group(1))
            elif kind == "noforce": forced.discard(m.group(1))
            elif kind == "disable": enabled.discard(m.group(1))
            elif kind == "cpol": policies.setdefault(m.group(2), set()).add(m.group(1))
            elif kind == "dpol": policies.get(m.group(2), set()).discard(m.group(1))
    out: dict[str, list[str]] = {}
    for t in sorted(tenant_tables):
        miss = []
        if t not in enabled: miss.append("ENABLE RLS fehlt/aufgehoben")
        if t not in forced: miss.append("FORCE RLS fehlt/aufgehoben")
        if not policies.get(t): miss.append("keine (aktive) Policy")
        out[t] = miss
    return out


def run() -> CheckResult:
    res = CheckResult(name="RLS FORCE + Policy je mandantenbezogener Tabelle", adr="ADR-01")
    files = sorted(glob.glob(str(REPO / "db" / "migrations" / "*.sql")))
    if not files:
        res.findings.append(Finding("ADR-01", False, "keine Migrationen gefunden")); return res
    result = analyze([Path(p).read_text(encoding="utf-8") for p in files])
    if not result:
        res.findings.append(Finding("ADR-01", False, "keine mandantenbezogene Tabelle (tenant_id) erkannt")); return res
    for t, miss in result.items():
        if miss:
            res.findings.append(Finding("ADR-01", False, f"{t}: " + ", ".join(miss)))
        else:
            res.findings.append(Finding("ADR-01", True, f"{t}: ENABLE+FORCE+Policy"))
    return res
