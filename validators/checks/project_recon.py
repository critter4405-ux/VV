"""ADR-09: Abgleich der real erzeugten Tabellen gegen die project.json-Fragmente
(Review Codex #15 / Gemini): jede in den Migrationen erzeugte Tabelle MUSS in genau einem
Fragment deklariert sein (fehlende Deklaration = Fail). Infra-Tabellen sind explizit gelistet.
"""
from __future__ import annotations
import re
import glob
from ..common import REPO, CheckResult, Finding, load_fragments, strip_sql_comments

CREATE_TABLE = re.compile(r"CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?([A-Za-z_]\w*)", re.IGNORECASE)
INFRA = {"tenant"}  # Stammtabelle, keinem Baustein zugeordnet (bewusst)


def run() -> CheckResult:
    res = CheckResult(name="project.json ↔ reale Tabellen (Abgleich)", adr="ADR-09")
    created: set[str] = set()
    for p in sorted(glob.glob(str(REPO / "db" / "migrations" / "*.sql"))):
        sql = strip_sql_comments(open(p, encoding="utf-8").read())
        created.update(m.group(1).lower() for m in CREATE_TABLE.finditer(sql))

    declared: dict[str, list[str]] = {}
    for f in load_fragments():
        for t in f.get("tables", []):
            declared.setdefault(t["name"].lower(), []).append(f.get("code"))

    ok = True
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
