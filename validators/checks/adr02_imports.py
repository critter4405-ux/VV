"""ADR-02: keine verbotenen Cross-Modul-Imports.

Module leben unter apps/web/src/modules/<mod>/. Ein Modul darf NICHT direkt aus
einem anderen Modul importieren (nur über platform/db/öffentliche Schnittstelle
oder eine im Fragment allowlistete Ausnahme)."""
from __future__ import annotations
import re
import glob
import os
from ..common import REPO, CheckResult, Finding, load_fragments

MODULES_DIR = REPO / "apps" / "web" / "src" / "modules"
IMPORT_RE = re.compile(r"""import\s+[^;]*?from\s+['"]([^'"]+)['"]""", re.DOTALL)


def _allowlist() -> dict[str, list[str]]:
    allow: dict[str, list[str]] = {}
    for frag in load_fragments():
        mod = frag.get("module")
        if mod and mod.get("path", "").startswith("apps/web/src/modules/"):
            key = mod["path"].rsplit("/", 1)[-1]
            allow[key] = mod.get("allowed_cross_module_imports", []) or []
    return allow


def run() -> CheckResult:
    res = CheckResult(name="Keine verbotenen Cross-Modul-Imports", adr="ADR-02")
    if not MODULES_DIR.exists():
        res.findings.append(Finding("ADR-02", True, "keine Module vorhanden (nichts zu prüfen)"))
        return res

    module_names = {d for d in os.listdir(MODULES_DIR) if (MODULES_DIR / d).is_dir()}
    allow = _allowlist()
    checked = 0
    for path in glob.glob(str(MODULES_DIR / "**" / "*.ts"), recursive=True):
        rel = os.path.relpath(path, MODULES_DIR)
        current = rel.split(os.sep)[0]
        src = open(path, encoding="utf-8").read()
        for spec in IMPORT_RE.findall(src):
            target_mod = None
            # relativer Sprung in ein Geschwister-Modul: ../<other>/...
            m = re.match(r"\.\./([^/]+)/", spec)
            if m and m.group(1) in module_names and m.group(1) != current:
                target_mod = m.group(1)
            # absoluter Modulpfad
            m2 = re.search(r"modules/([^/]+)/", spec)
            if m2 and m2.group(1) in module_names and m2.group(1) != current:
                target_mod = m2.group(1)
            if target_mod and target_mod not in allow.get(current, []):
                checked += 1
                res.findings.append(Finding(
                    "ADR-02", False,
                    f"{rel}: verbotener Import aus Modul '{target_mod}' ({spec})"))
    if not res.findings:
        res.findings.append(Finding("ADR-02", True,
            f"{len(module_names)} Module, keine verbotenen Cross-Modul-Imports"))
    return res
