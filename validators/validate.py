"""VV Gate-Validator (ADR-09) — Einstieg.

Führt alle Invarianten-Checks aus, schreibt einen Evidenz-Report und beendet
mit Exit-Code != 0, sobald ein Gate-blockierender Verstoß vorliegt.

    python3 -m validators.validate
"""
from __future__ import annotations
import json
import sys
from datetime import datetime, timezone

from .common import REPO, CheckResult, Finding
from . import merge as merge_mod
from .checks import (
    schema_check, adr01_rls, adr02_imports, adr04_policy,
    k29_dossier, evidence, synthetic_guard,
)


def _merge_check() -> CheckResult:
    res = CheckResult(name="Merge: eindeutige Codes, ein Tabellen-Eigentümer", adr="ADR-09")
    merged = merge_mod.merge()
    if merged["merge_errors"]:
        for e in merged["merge_errors"]:
            res.findings.append(Finding("ADR-09", False, e))
    else:
        res.findings.append(Finding(
            "ADR-09", True,
            f"{len(merged['bausteine'])} Bausteine, {len(merged['table_owner'])} Tabellen, keine Doppelung"))
    return res


def main() -> int:
    checks = [
        _merge_check(),
        schema_check.run(),
        adr01_rls.run(),
        adr02_imports.run(),
        adr04_policy.run(),
        k29_dossier.run(),
        evidence.run(),
        synthetic_guard.run(),
    ]

    print("=" * 74)
    print("VV Gate-Validator (Stage 0) — ADR-Invarianten gate-blockierend")
    print("=" * 74)
    total_fail = 0
    report = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "stage": 0,
        "checks": [],
    }
    for c in checks:
        status = "PASS" if c.passed else "FAIL"
        nfail = len(c.failed)
        total_fail += nfail
        print(f"[{status}] {c.adr:<7} {c.name}  ({len(c.findings)-nfail}/{len(c.findings)} ok)")
        for f in c.failed:
            print(f"        ✗ {f.detail}")
        report["checks"].append({
            "adr": c.adr,
            "name": c.name,
            "passed": c.passed,
            "findings": [{"rule": f.rule, "ok": f.ok, "detail": f.detail} for f in c.findings],
        })

    report["passed"] = total_fail == 0
    report["total_failures"] = total_fail

    ev_dir = REPO / "evidence" / "stage-0"
    ev_dir.mkdir(parents=True, exist_ok=True)
    (ev_dir / "validator-report.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    print("-" * 74)
    if total_fail == 0:
        print("GATE 0 → 1: GRÜN — alle ADR-Invarianten erfüllt.")
    else:
        print(f"GATE 0 → 1: ROT — {total_fail} Verstoß/Verstöße. Gate gesperrt.")
    print(f"Report: evidence/stage-0/validator-report.json")
    return 0 if total_fail == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
