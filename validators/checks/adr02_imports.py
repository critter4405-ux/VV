"""ADR-02: keine verbotenen Cross-Modul-Imports. WP5-gehärtet:
- Kommentare/Strings werden entfernt.
- erkennt statische Imports, `export ... from`, UND dynamische Importe `import(...)`.
- Allowlist je Modul aus dem project.json-Fragment.
"""
from __future__ import annotations
import re
import glob
import os
from ..common import REPO, CheckResult, Finding, load_fragments, strip_ts_comments

MODULES_DIR = REPO / "apps" / "web" / "src" / "modules"
SPEC = re.compile(
    r"""(?:import\s+[^;]*?from\s*|export\s+[^;]*?from\s*|import\s*\(\s*)['"]([^'"]+)['"]""",
    re.DOTALL)
# Dynamischer import() mit nicht-STATISCHEM Argument ist statisch nicht prüfbar -> in Modulcode
# fail-closed verboten. Erfasst: Variable/Ausdruck (kein Quote) UND Template-Literal MIT ${…}
# (Review-Runde 3, Codex #2: import(`../${x}/...`) galt fälschlich als statisches Literal).
IMPORT_CALL = re.compile(r"\bimport\s*\(\s*")


def _dynamic_import_violation(src: str) -> str | None:
    """Gibt eine Fehlerbeschreibung zurück, wenn ein import() ein nicht-statisches Argument hat."""
    for m in IMPORT_CALL.finditer(src):
        i = m.end()
        if i >= len(src):
            continue
        c = src[i]
        if c in "'\"":
            continue  # statisches String-Literal -> ok (SPEC prüft den Pfad)
        if c == "`":
            # Template-Literal: bis zum schließenden Backtick lesen, auf ${ prüfen.
            j = i + 1
            while j < len(src) and src[j] != "`":
                if src[j] == "\\":
                    j += 2; continue
                j += 1
            body = src[i + 1:j]
            if "${" in body:
                return "dynamischer import() mit Template-Interpolation `${…}` (nicht statisch prüfbar)"
            continue  # Template ohne Interpolation = statisch -> ok
        # Variable/Ausdruck/Funktion
        return "dynamischer import() mit nicht-literalem Argument (Variable/Ausdruck)"
    return None


def _allowlist() -> dict[str, list[str]]:
    allow: dict[str, list[str]] = {}
    for frag in load_fragments():
        mod = frag.get("module")
        if mod and mod.get("path", "").startswith("apps/web/src/modules/"):
            allow[mod["path"].rsplit("/", 1)[-1]] = mod.get("allowed_cross_module_imports", []) or []
    return allow


def run() -> CheckResult:
    res = CheckResult(name="Keine verbotenen Cross-Modul-Imports (inkl. dynamisch)", adr="ADR-02")
    if not MODULES_DIR.exists():
        res.findings.append(Finding("ADR-02", True, "keine Module vorhanden")); return res
    module_names = {d for d in os.listdir(MODULES_DIR) if (MODULES_DIR / d).is_dir()}
    allow = _allowlist()
    violations = 0
    for path in glob.glob(str(MODULES_DIR / "**" / "*.ts"), recursive=True):
        rel = os.path.relpath(path, MODULES_DIR)
        current = rel.split(os.sep)[0]
        with open(path, encoding="utf-8") as fh:
            src = strip_ts_comments(fh.read())
        # Fail-closed: dynamischer import() mit nicht-statischem Argument ist nicht verifizierbar.
        dyn = _dynamic_import_violation(src)
        if dyn:
            violations += 1
            res.findings.append(Finding("ADR-02", False,
                f"{rel}: {dyn} — in Modulcode verboten (Cross-Modul nicht prüfbar, fail-closed)"))
        for spec in SPEC.findall(src):
            target = None
            m = re.match(r"\.\./([^/]+)/", spec)
            if m and m.group(1) in module_names and m.group(1) != current:
                target = m.group(1)
            m2 = re.search(r"modules/([^/]+)/", spec)
            if m2 and m2.group(1) in module_names and m2.group(1) != current:
                target = m2.group(1)
            if target and target not in allow.get(current, []):
                violations += 1
                res.findings.append(Finding("ADR-02", False,
                    f"{rel}: verbotener Import aus Modul '{target}' ({spec})"))
    if violations == 0:
        res.findings.append(Finding("ADR-02", True,
            f"{len(module_names)} Module, keine verbotenen Cross-Modul-Imports (statisch/dynamisch)"))
    return res
