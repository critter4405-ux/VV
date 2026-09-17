"""ADR-04: keine Aktion/kein DB-Schreibzugriff umgeht den zentralen Policy-Prüfpunkt. WP5:
1. Jede *.action.ts MUSS checkPolicy importieren UND aufrufen (Kommentare zählen nicht).
2. DB-Schreibzugriffe (INSERT/UPDATE/DELETE) sind NUR erlaubt in *.action.ts (policy-gated)
   oder im kontrollierten platform/-Infrastruktur-Layer (z.B. audit.ts). Ein Schreibzugriff
   in einer beliebigen anderen Datei ist ein Verstoß (Review-Befund Codex #5).
"""
from __future__ import annotations
import glob
import os
import re
from ..common import REPO, CheckResult, Finding, strip_sql_comments

SRC = REPO / "apps" / "web" / "src"
WRITE = re.compile(r"\b(INSERT\s+INTO|UPDATE\s+[A-Za-z_]\w*\s+SET|DELETE\s+FROM)\b", re.IGNORECASE)
IMPORT_POLICY = re.compile(r"""import\s*\{[^}]*\bcheckPolicy\b[^}]*\}\s*from\s*['"][^'"]*platform/policy""")
CALL_POLICY = re.compile(r"\bcheckPolicy\s*\(")


def _strip_ts_comments(src: str) -> str:
    src = re.sub(r"/\*.*?\*/", " ", src, flags=re.DOTALL)
    src = re.sub(r"//[^\n]*", " ", src)
    return src


def run() -> CheckResult:
    res = CheckResult(name="Zentraler Policy-Prüfpunkt nicht umgangen", adr="ADR-04")
    ts = glob.glob(str(SRC / "**" / "*.ts"), recursive=True)
    actions = [p for p in ts if p.endswith(".action.ts")]
    if not actions:
        res.findings.append(Finding("ADR-04", False, "keine *.action.ts gefunden (Beispiel-Aktion fehlt)"))

    for path in sorted(actions):
        rel = os.path.relpath(path, REPO)
        src = _strip_ts_comments(open(path, encoding="utf-8").read())
        if IMPORT_POLICY.search(src) and CALL_POLICY.search(src):
            res.findings.append(Finding("ADR-04", True, f"{rel}: geht durch checkPolicy()"))
        else:
            miss = []
            if not IMPORT_POLICY.search(src): miss.append("Import checkPolicy fehlt")
            if not CALL_POLICY.search(src): miss.append("Aufruf checkPolicy() fehlt")
            res.findings.append(Finding("ADR-04", False, f"{rel}: " + ", ".join(miss)))

    # Schreibzugriffe außerhalb erlaubter Stellen aufspüren.
    for path in sorted(ts):
        rel = os.path.relpath(path, REPO).replace("\\", "/")
        allowed = rel.endswith(".action.ts") or "/src/platform/" in rel
        code = strip_sql_comments(_strip_ts_comments(open(path, encoding="utf-8").read()))
        if WRITE.search(code) and not allowed:
            res.findings.append(Finding("ADR-04", False,
                f"{rel}: DB-Schreibzugriff außerhalb *.action.ts/platform (umgeht Policy)"))
    return res
