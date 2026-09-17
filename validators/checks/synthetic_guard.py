"""Datenschutz-Guard: kein Personenbezug im Repo/CI (K31/ADR-10). WP5-gehärtet (Review Codex #9):
- scannt ALLE Textdateien inkl. .csv/.json (nicht nur eine feste Extension-Liste).
- Treffer werden MASKIERT geloggt (nie Klartext) -> kein PII-Leak in Report/CI-Log.
- schließt den eigenen Report + Binär-/Bibliotheksdateien aus.
"""
from __future__ import annotations
import os
import re
from ..common import REPO, CheckResult, Finding

SKIP_DIRS = {".git", "node_modules", ".next", "__pycache__", ".venv", "venv", "dist"}
SKIP_NAMES = {"mermaid.min.js"}
SKIP_RELPATHS = {"evidence/stage-0/validator-report.json"}   # eigener Output
BINARY_EXT = {".png", ".jpg", ".jpeg", ".webp", ".ico", ".gz", ".zip", ".pdf", ".woff", ".woff2"}
FORBIDDEN_FILES = re.compile(r"(mitglieder|personen|members)[\w-]*\.(csv|xlsx|xls)$", re.IGNORECASE)

IBAN_AT = re.compile(r"\bAT\d{18}\b")
EMAIL = re.compile(r"\b[\w.+-]+@[\w-]+\.[A-Za-z]{2,}\b")
EMAIL_ALLOW = re.compile(r"@(example\.(com|org|net)|localhost|keycloak|minio|postgres|vv\.local)\b", re.IGNORECASE)


def _mask(s: str) -> str:
    return (s[:2] + "***" + s[-2:]) if len(s) > 5 else "***"


def run() -> CheckResult:
    res = CheckResult(name="Kein Personenbezug im Repo/CI (nur synthetisch)", adr="K31")
    hits = 0
    for root, dirs, files in os.walk(REPO):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        for fn in files:
            path = os.path.join(root, fn)
            rel = os.path.relpath(path, REPO).replace("\\", "/")
            if FORBIDDEN_FILES.search(fn):
                res.findings.append(Finding("K31", False, f"{rel}: verdächtige Personen-Exportdatei")); hits += 1
                continue
            if fn in SKIP_NAMES or rel in SKIP_RELPATHS: continue
            if os.path.splitext(fn)[1].lower() in BINARY_EXT: continue
            try:
                text = open(path, encoding="utf-8", errors="strict").read()
            except (OSError, UnicodeDecodeError):
                continue  # echte Binärdatei -> übersprungen
            for m in IBAN_AT.finditer(text):
                res.findings.append(Finding("K31", False, f"{rel}: AT-IBAN-Muster ({_mask(m.group(0))})")); hits += 1
            for m in EMAIL.finditer(text):
                if not EMAIL_ALLOW.search(m.group(0)):
                    res.findings.append(Finding("K31", False, f"{rel}: echte E-Mail? ({_mask(m.group(0))})")); hits += 1

    env = REPO / ".env.example"
    if env.exists() and "VV_DATA_MODE=synthetic" in env.read_text(encoding="utf-8"):
        res.findings.append(Finding("K31", True, ".env.example: VV_DATA_MODE=synthetic"))
    else:
        res.findings.append(Finding("K31", False, ".env.example: VV_DATA_MODE=synthetic fehlt"))
    if hits == 0:
        res.findings.append(Finding("K31", True, "kein Personenbezug-Muster gefunden (alle Textdateien inkl. csv/json)"))
    return res
