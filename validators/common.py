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
    skipped: bool = False   # WP5-Runde2: 'übersprungen' ist WEDER pass NOCH fail (Codex #5-new)


@dataclass
class CheckResult:
    name: str
    adr: str
    findings: list[Finding] = field(default_factory=list)

    @property
    def failed(self) -> list[Finding]:
        return [f for f in self.findings if not f.ok and not f.skipped]

    @property
    def skipped_findings(self) -> list[Finding]:
        return [f for f in self.findings if f.skipped]

    @property
    def is_skipped(self) -> bool:
        # Reiner Skip-Check: nichts ausgeführt, nichts fehlgeschlagen.
        return len(self.findings) > 0 and all(f.skipped for f in self.findings)

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


import re as _re


def strip_sql_comments(sql: str) -> str:
    """Entfernt -- Zeilen- und /* */ Blockkommentare (verhindert Kommentar-Trick)."""
    sql = _re.sub(r"/\*.*?\*/", " ", sql, flags=_re.DOTALL)
    sql = _re.sub(r"--[^\n]*", " ", sql)
    return sql


def strip_ts_comments(src: str) -> str:
    """Entfernt nur // und /* */ Kommentare (String-Literale bleiben — für Import-Pfad-Analyse)."""
    src = _re.sub(r"/\*.*?\*/", " ", src, flags=_re.DOTALL)
    src = _re.sub(r"//[^\n]*", " ", src)
    return src


def strip_ts_comments_strings(src: str) -> str:
    """Entfernt // und /* */ Kommentare und String-/Template-Literale (grob, für Import-Analyse)."""
    src = _re.sub(r"/\*.*?\*/", " ", src, flags=_re.DOTALL)
    src = _re.sub(r"//[^\n]*", " ", src)
    # Strings maskieren, damit z.B. "checkPolicy(" in einem String nicht zählt.
    src = _re.sub(r"'(?:\\.|[^'\\])*'", "''", src)
    src = _re.sub(r'"(?:\\.|[^"\\])*"', '""', src)
    src = _re.sub(r"`(?:\\.|[^`\\])*`", "``", src)
    return src
