"""Datenschutz-Guard: kein Personenbezug im Repo/CI (K31/ADR-10).

Blockiert echte-Daten-Muster (AT-IBAN, echte E-Mail-Adressen außerhalb Platzhaltern)
und Mitglieder-/Personen-Exportdateien. Nur synthetische Testdaten sind erlaubt."""
from __future__ import annotations
import os
import re
from ..common import REPO, CheckResult, Finding

SKIP_DIRS = {".git", "node_modules", ".next", "__pycache__", ".venv", "venv"}
SCAN_EXT = {".sql", ".ts", ".js", ".mjs", ".json", ".md", ".yml", ".yaml", ".env", ".example", ".txt"}
FORBIDDEN_FILES = re.compile(r"(mitglieder|personen|members)[\w-]*\.(csv|xlsx|xls)$", re.IGNORECASE)

IBAN_AT = re.compile(r"\bAT\d{18}\b")
EMAIL = re.compile(r"\b[\w.+-]+@[\w-]+\.[A-Za-z]{2,}\b")
EMAIL_ALLOW = re.compile(r"@(example\.(com|org|net)|localhost|keycloak|minio|postgres)\b", re.IGNORECASE)


def run() -> CheckResult:
    res = CheckResult(name="Kein Personenbezug im Repo/CI (nur synthetisch)", adr="K31")
    for root, dirs, files in os.walk(REPO):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        for fn in files:
            path = os.path.join(root, fn)
            rel = os.path.relpath(path, REPO)
            if FORBIDDEN_FILES.search(fn):
                res.findings.append(Finding("K31", False, f"{rel}: verdächtige Personen-Exportdatei"))
                continue
            ext = os.path.splitext(fn)[1].lower()
            base_ok = ext in SCAN_EXT or fn == ".env.example"
            if not base_ok:
                continue
            try:
                text = open(path, encoding="utf-8", errors="ignore").read()
            except OSError:
                continue
            for m in IBAN_AT.finditer(text):
                res.findings.append(Finding("K31", False, f"{rel}: AT-IBAN-Muster gefunden ({m.group(0)})"))
            for m in EMAIL.finditer(text):
                if not EMAIL_ALLOW.search(m.group(0)):
                    res.findings.append(Finding("K31", False, f"{rel}: echte E-Mail-Adresse? ({m.group(0)})"))

    env_example = REPO / ".env.example"
    if env_example.exists() and "VV_DATA_MODE=synthetic" in env_example.read_text(encoding="utf-8"):
        res.findings.append(Finding("K31", True, ".env.example: VV_DATA_MODE=synthetic gesetzt"))
    else:
        res.findings.append(Finding("K31", False, ".env.example: VV_DATA_MODE=synthetic fehlt"))

    if all(f.ok for f in res.findings):
        res.findings.append(Finding("K31", True, "kein Personenbezug-Muster im Repo gefunden"))
    return res
