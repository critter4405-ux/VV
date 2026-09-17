"""ADR-04: keine Aktion umgeht den zentralen Policy-Prüfpunkt.

Konvention: jede Datei *.action.ts unter apps/web/src MUSS checkPolicy aus dem
Platform-Prüfpunkt importieren UND aufrufen (deny-by-default)."""
from __future__ import annotations
import glob
import os
import re
from ..common import REPO, CheckResult, Finding

SRC = REPO / "apps" / "web" / "src"


def run() -> CheckResult:
    res = CheckResult(name="Zentraler Policy-Prüfpunkt nicht umgangen", adr="ADR-04")
    action_files = glob.glob(str(SRC / "**" / "*.action.ts"), recursive=True)
    if not action_files:
        res.findings.append(Finding("ADR-04", False,
            "keine *.action.ts gefunden — Stage-0-Skeleton muss mind. eine Beispiel-Aktion zeigen"))
        return res
    for path in sorted(action_files):
        rel = os.path.relpath(path, REPO)
        src = open(path, encoding="utf-8").read()
        imports_policy = re.search(r"""import\s*\{[^}]*\bcheckPolicy\b[^}]*\}\s*from\s*['"][^'"]*platform/policy""", src)
        calls_policy = re.search(r"\bcheckPolicy\s*\(", src)
        if imports_policy and calls_policy:
            res.findings.append(Finding("ADR-04", True, f"{rel}: geht durch checkPolicy()"))
        else:
            miss = []
            if not imports_policy:
                miss.append("Import von checkPolicy fehlt")
            if not calls_policy:
                miss.append("Aufruf checkPolicy() fehlt")
            res.findings.append(Finding("ADR-04", False, f"{rel}: " + ", ".join(miss)))
    return res
