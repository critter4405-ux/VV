"""K29: je Baustein ein vollständiges 9-teiliges Bau-Dossier + Mermaid-Diagramm.

Prüft Vorhandensein + Minimum (alle 9 Abschnitte, ein Mermaid-Block, ein
Evidenz-/Test-Link) — nicht die Wortmenge."""
from __future__ import annotations
import re
from pathlib import Path
from ..common import REPO, CheckResult, Finding, load_fragments

# erwartete Abschnittsnummern 1..9
SECTIONS = [
    "Kopf", "Was", "Warum", "Wie umgesetzt", "Wie getestet",
    "Sicherheit", "Visual", "Nutzen", "Änderungshistorie",
]


def _check_md(path: Path) -> list[str]:
    problems: list[str] = []
    text = path.read_text(encoding="utf-8")
    for n in range(1, 10):
        if not re.search(rf"^##\s*{n}\.", text, re.MULTILINE):
            problems.append(f"Abschnitt {n} fehlt")
    if "```mermaid" not in text:
        problems.append("Mermaid-Diagramm fehlt (Abschnitt 7 Pflicht)")
    # Test-/Evidenz-Verlinkung (knapp + verlinkt statt kopiert)
    if not re.search(r"\]\((?:\.\./)*evidence/", text):
        problems.append("kein Evidenz-/Test-Link (Abschnitt 5)")
    return problems


def run() -> CheckResult:
    res = CheckResult(name="9-teiliges Bau-Dossier + Mermaid je Baustein", adr="K29")
    frags = load_fragments()
    # Stage-0-Kurzdossier zusätzlich prüfen
    targets = [(f.get("code"), REPO / f["dossier"]) for f in frags]
    stage0 = REPO / "docs" / "bausteine" / "STAGE-0.md"
    if stage0.exists():
        targets.append(("VV-STAGE-0", stage0))
    for code, path in targets:
        if not path.exists():
            res.findings.append(Finding("K29", False, f"{code}: Dossier fehlt ({path.name})"))
            continue
        problems = _check_md(path)
        if problems:
            res.findings.append(Finding("K29", False, f"{code}: " + "; ".join(problems)))
        else:
            res.findings.append(Finding("K29", True, f"{code}: 9 Abschnitte + Mermaid + Evidenz-Link"))
    return res
