#!/usr/bin/env python3
"""Extrahiert alle ```mermaid-Blöcke aus docs/**/*.md in einzelne .mmd-Dateien.
Die CI rendert jede Datei anschließend mit dem echten Mermaid-Parser (mmdc) — ein Syntaxfehler
lässt mmdc mit Exit != 0 scheitern (Review-Runde 3, Codex #7: der Python-Check ist kein Parser).

    python3 scripts/mermaid_lint.py            # nach build/mermaid/*.mmd extrahieren
Gibt die Anzahl extrahierter Blöcke aus; Exit 0.
"""
from __future__ import annotations
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
OUT = REPO / "build" / "mermaid"
BLOCK = re.compile(r"```mermaid\s*\n(.*?)```", re.DOTALL)


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    for old in OUT.glob("*.mmd"):
        old.unlink()
    n = 0
    for md in sorted((REPO / "docs").rglob("*.md")):
        text = md.read_text(encoding="utf-8")
        for i, m in enumerate(BLOCK.finditer(text)):
            rel = md.relative_to(REPO).as_posix().replace("/", "__").replace(".md", "")
            (OUT / f"{rel}__{i}.mmd").write_text(m.group(1).strip() + "\n", encoding="utf-8")
            n += 1
    print(f"{n} Mermaid-Block/Blöcke extrahiert nach {OUT.relative_to(REPO)}/")
    return 0


if __name__ == "__main__":
    sys.exit(main())
