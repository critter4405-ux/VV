"""ADR-09: Abgleich der real erzeugten Tabellen gegen die project.json-Fragmente
(Review Codex #15 / Gemini): jede in den Migrationen erzeugte Tabelle MUSS in genau einem
Fragment deklariert sein (fehlende Deklaration = Fail). Infra-Tabellen sind explizit gelistet.
"""
from __future__ import annotations
import re
import glob
from pathlib import Path
from ..common import REPO, CheckResult, Finding, load_fragments, strip_sql_comments

CREATE_TABLE = re.compile(r"CREATE\s+(?:(?:GLOBAL|LOCAL)\s+)?(?:UNLOGGED\s+|TEMP(?:ORARY)?\s+)?TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?(?:([A-Za-z_]\w*)\.)?([A-Za-z_]\w*)(?![\w.])", re.IGNORECASE)
INFRA = {"tenant"}  # Stammtabelle, keinem Baustein zugeordnet (bewusst)
# Fremd-Infrastruktur-Schema (pg-boss, ADR-06): Tabellen darin sind keine Fachdaten und werden NUR
# über die generierte Migration *_pgboss_schema.sql angelegt (scripts/gen_pgboss_schema.mjs, P57).
# Anderswo angelegte pgboss.*-Tabellen sind ein Verstoß (kein Schlupfloch für undeklarierte Tabellen).
INFRA_SCHEMA = "pgboss"
INFRA_SCHEMA_FILE = re.compile(r"^\d{4}_pgboss_schema\.sql$")


def run() -> CheckResult:
    res = CheckResult(name="project.json ↔ reale Tabellen (Abgleich)", adr="ADR-09")
    created: set[str] = set()
    ok = True
    for p in sorted(glob.glob(str(REPO / "db" / "migrations" / "*.sql"))):
        sql = strip_sql_comments(Path(p).read_text(encoding="utf-8"))
        fname = Path(p).name
        for m in CREATE_TABLE.finditer(sql):
            schema, table = (m.group(1) or "").lower(), m.group(2).lower()
            if schema == INFRA_SCHEMA:
                if not INFRA_SCHEMA_FILE.match(fname):
                    ok = False
                    res.findings.append(Finding("ADR-09", False,
                        f"{fname}: Tabelle {schema}.{table} außerhalb der generierten pg-boss-Migration"))
                continue
            created.add(table)

    declared: dict[str, list[str]] = {}
    for f in load_fragments():
        for t in f.get("tables", []):
            declared.setdefault(t["name"].lower(), []).append(f.get("code"))

    for t in sorted(created):
        if t in INFRA:
            continue
        owners = declared.get(t, [])
        if len(owners) == 1:
            res.findings.append(Finding("ADR-09", True, f"{t}: deklariert in {owners[0]}"))
        elif not owners:
            ok = False; res.findings.append(Finding("ADR-09", False, f"{t}: in keinem Fragment deklariert"))
        else:
            ok = False; res.findings.append(Finding("ADR-09", False, f"{t}: mehrere Eigentümer {owners}"))

    # Umgekehrt: deklarierte Tabellen, die es real nicht gibt.
    for t, owners in declared.items():
        if t not in created:
            ok = False; res.findings.append(Finding("ADR-09", False, f"{t} (in {owners}) hat keine reale CREATE TABLE"))
    if ok and not res.findings:
        res.findings.append(Finding("ADR-09", True, "keine Tabellen deklariert/erzeugt"))
    return res
