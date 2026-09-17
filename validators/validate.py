"""VV Gate-Validator (ADR-09) — Einstieg. WP5: UTF-8-robust, atomarer Report, Live-DB-Check.

    python3 -m validators.validate            # lokal (Live-DB übersprungen, wenn kein DSN)
    VV_VALIDATE_DSN=postgres://... python3 -m validators.validate   # CI: Live-DB gate-blockierend
"""
from __future__ import annotations
import io
import json
import os
import sys
from datetime import datetime, timezone

# UTF-8 erzwingen (Review Codex #17: UnicodeEncodeError am Pfeilzeichen unter Windows).
try:
    sys.stdout.reconfigure(encoding="utf-8")  # type: ignore[attr-defined]
except Exception:  # noqa: BLE001
    sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")

from .common import REPO, CheckResult, Finding
from . import merge as merge_mod
from .checks import (
    schema_check, adr01_rls, adr02_imports, adr04_policy,
    k29_dossier, evidence, synthetic_guard, project_recon, db_live,
)


def _merge_check() -> CheckResult:
    res = CheckResult(name="Merge: eindeutige Codes, ein Tabellen-Eigentümer", adr="ADR-09")
    merged = merge_mod.merge()
    if merged["merge_errors"]:
        for e in merged["merge_errors"]:
            res.findings.append(Finding("ADR-09", False, e))
    else:
        res.findings.append(Finding("ADR-09", True,
            f"{len(merged['bausteine'])} Bausteine, {len(merged['table_owner'])} Tabellen, keine Doppelung"))
    return res


def _atomic_write(path, data: str) -> None:
    tmp = str(path) + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(data)
    os.replace(tmp, path)


def main() -> int:
    checks = [
        _merge_check(),
        schema_check.run(),
        adr01_rls.run(),
        adr02_imports.run(),
        adr04_policy.run(),
        project_recon.run(),
        k29_dossier.run(),
        evidence.run(),
        synthetic_guard.run(),
        db_live.run(),
    ]

    print("=" * 74)
    print("VV Gate-Validator (Stage 0) — ADR-Invarianten gate-blockierend")
    print("=" * 74)
    total_fail = 0
    total_skip = 0
    report = {"generated_at": datetime.now(timezone.utc).isoformat(), "stage": 0,
              "live_db": bool(os.environ.get("VV_VALIDATE_DSN")),
              "require_live": bool(os.environ.get("VV_REQUIRE_LIVE")), "checks": []}
    for c in checks:
        nfail = len(c.failed); total_fail += nfail
        if c.is_skipped:
            status = "SKIP"; total_skip += 1
        elif c.passed:
            status = "PASS"
        else:
            status = "FAIL"
        print(f"[{status}] {c.adr:<7} {c.name}  ({len(c.findings)-nfail}/{len(c.findings)} ok)")
        for f in c.failed:
            print(f"        x {f.detail}")
        for f in c.skipped_findings:
            print(f"        ~ übersprungen: {f.detail}")
        report["checks"].append({"adr": c.adr, "name": c.name,
            "status": status.lower(), "passed": c.passed, "skipped": c.is_skipped,
            "findings": [{"rule": f.rule, "ok": f.ok, "skipped": f.skipped, "detail": f.detail}
                         for f in c.findings]})

    report["passed"] = total_fail == 0
    report["total_failures"] = total_fail
    report["total_skipped"] = total_skip
    ev_dir = REPO / "evidence" / "stage-0"; ev_dir.mkdir(parents=True, exist_ok=True)
    _atomic_write(ev_dir / "validator-report.json", json.dumps(report, ensure_ascii=False, indent=2) + "\n")

    print("-" * 74)
    if total_fail == 0 and total_skip == 0:
        print("GATE 0 -> 1: GRÜN — alle ADR-Invarianten erfüllt (inkl. Live-DB).")
    elif total_fail == 0:
        print(f"GATE 0 -> 1: GRÜN (lokal) — {total_skip} Check übersprungen "
              "(Live-DB); im Gate via VV_REQUIRE_LIVE erzwungen.")
    else:
        print(f"GATE 0 -> 1: ROT — {total_fail} Verstoß/Verstöße. Gate gesperrt.")
    print("Report: evidence/stage-0/validator-report.json")
    return 0 if total_fail == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
