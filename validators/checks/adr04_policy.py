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
# Entscheidung MUSS in einer Variablen gehalten werden, damit sie gaten kann.
DECISION_ASSIGN = re.compile(r"(?:const|let|var)\s+(\w+)\s*=\s*(?:await\s+)?checkPolicy\s*\(")

# Explizite Datei-Allowlist für DB-Schreibzugriffe außerhalb von *.action.ts (Gemini #4):
# NUR der Audit-Writer im Plattform-Layer, nicht das ganze platform/-Verzeichnis.
WRITE_ALLOWLIST = {"apps/web/src/platform/audit.ts"}


def _strip_ts_comments(src: str) -> str:
    src = re.sub(r"/\*.*?\*/", " ", src, flags=re.DOTALL)
    src = re.sub(r"//[^\n]*", " ", src)
    return src


def _action_gates_writes(src: str) -> list[str]:
    """Prüft, dass die checkPolicy-Entscheidung Schreibzugriffe tatsächlich GATET
    (Review-Runde 2, Codex #5-new: Aktion rief checkPolicy, ignorierte aber das Ergebnis
    und löschte trotzdem). Heuristik, fail-closed."""
    problems: list[str] = []
    if not (IMPORT_POLICY.search(src) and CALL_POLICY.search(src)):
        miss = []
        if not IMPORT_POLICY.search(src): miss.append("Import checkPolicy fehlt")
        if not CALL_POLICY.search(src): miss.append("Aufruf checkPolicy() fehlt")
        return miss
    m = DECISION_ASSIGN.search(src)
    if not m:
        return ["checkPolicy-Ergebnis wird nicht in einer Variablen gehalten (kann nicht gaten)"]
    var = m.group(1)
    guard = re.search(rf"if\s*\(\s*!\s*{re.escape(var)}\s*\.\s*allowed\s*\)", src)
    if not guard:
        problems.append(f"kein negativer Guard 'if (!{var}.allowed)' vor Schreibzugriff")
    else:
        # nach dem Guard muss ein return/throw folgen (verweigern, nicht weiterlaufen).
        tail = src[guard.end(): guard.end() + 160]
        if not re.search(r"\b(return|throw)\b", tail):
            problems.append(f"Guard auf {var}.allowed ohne return/throw (Entscheidung folgenlos)")
    # Kein Schreibzugriff VOR dem Guard.
    first_write = WRITE.search(src)
    if first_write and guard and first_write.start() < guard.start():
        problems.append("DB-Schreibzugriff steht VOR dem Policy-Guard (Reihenfolge umgeht Policy)")
    return problems


def run() -> CheckResult:
    res = CheckResult(name="Zentraler Policy-Prüfpunkt nicht umgangen", adr="ADR-04")
    ts = glob.glob(str(SRC / "**" / "*.ts"), recursive=True)
    actions = [p for p in ts if p.endswith(".action.ts")]
    if not actions:
        res.findings.append(Finding("ADR-04", False, "keine *.action.ts gefunden (Beispiel-Aktion fehlt)"))

    for path in sorted(actions):
        rel = os.path.relpath(path, REPO)
        src = strip_sql_comments(_strip_ts_comments(open(path, encoding="utf-8").read()))
        probs = _action_gates_writes(src)
        res.findings.append(Finding("ADR-04", not probs,
            f"{rel}: " + ("; ".join(probs) if probs else "checkPolicy() gatet Schreibzugriffe (Guard + return)")))

    # Schreibzugriffe außerhalb erlaubter Stellen aufspüren (explizite Allowlist statt ganzem Ordner).
    for path in sorted(ts):
        rel = os.path.relpath(path, REPO).replace("\\", "/")
        allowed = rel.endswith(".action.ts") or rel in WRITE_ALLOWLIST
        code = strip_sql_comments(_strip_ts_comments(open(path, encoding="utf-8").read()))
        if WRITE.search(code) and not allowed:
            res.findings.append(Finding("ADR-04", False,
                f"{rel}: DB-Schreibzugriff außerhalb *.action.ts/Allowlist (umgeht Policy)"))
    return res
