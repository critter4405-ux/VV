"""ADR-09: jedes Gate hat verlinkte, existierende Evidenz."""
from __future__ import annotations
from ..common import REPO, CheckResult, Finding, load_fragments


def run() -> CheckResult:
    res = CheckResult(name="Jedes Gate hat verlinkte Evidenz", adr="ADR-09")
    for frag in load_fragments():
        code = frag.get("code")
        for gate in frag.get("gates", []):
            gid = gate.get("id")
            ev = gate.get("evidence", [])
            if not ev:
                res.findings.append(Finding("ADR-09", False, f"{code} Gate {gid}: keine Evidenz verlinkt"))
                continue
            for path in ev:
                if (REPO / path).exists():
                    res.findings.append(Finding("ADR-09", True, f"{code} Gate {gid}: {path}"))
                else:
                    res.findings.append(Finding("ADR-09", False, f"{code} Gate {gid}: Evidenz fehlt → {path}"))
    return res
