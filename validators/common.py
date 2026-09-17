"""Gemeinsame Typen/Helfer für die VV-Validatoren."""
from __future__ import annotations
from dataclasses import dataclass, field
from pathlib import Path
import glob
import json

# Repo-Wurzel = eine Ebene über validators/
REPO = Path(__file__).resolve().parent.parent


@dataclass
class Finding:
    rule: str          # z.B. "ADR-01"
    ok: bool
    detail: str


@dataclass
class CheckResult:
    name: str
    adr: str
    findings: list[Finding] = field(default_factory=list)

    @property
    def failed(self) -> list[Finding]:
        return [f for f in self.findings if not f.ok]

    @property
    def passed(self) -> bool:
        return len(self.failed) == 0


def load_fragments() -> list[dict]:
    frags = []
    for p in sorted(glob.glob(str(REPO / "project" / "fragments" / "*.project.json"))):
        with open(p, encoding="utf-8") as fh:
            data = json.load(fh)
            data["__path"] = p
            frags.append(data)
    return frags


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")
