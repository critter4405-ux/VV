#!/usr/bin/env python3
"""VV Doku-Pipeline — CommonMark-Listenfix.

Stellt sicher, dass VOR jeder Liste (Bullet oder nummeriert) eine Leerzeile steht
(sonst rendert Markdown die Liste als Fließtext). In-place oder nach STDOUT.

    python3 scripts/fix_lists.py DATEI.md [DATEI2.md ...]
    python3 scripts/fix_lists.py --check DATEI.md      # Exit!=0 wenn Fix nötig
"""
from __future__ import annotations
import re
import sys
from pathlib import Path

LIST_ITEM = re.compile(r"^\s*(?:[-*+]\s+|\d+\.\s+)")
FENCE = re.compile(r"^\s*```")


def fix(text: str) -> str:
    lines = text.split("\n")
    out: list[str] = []
    in_fence = False
    in_list = False  # innerhalb einer Liste (inkl. eingerückter Fortsetzungszeilen)
    for line in lines:
        if FENCE.match(line):
            in_fence = not in_fence
            in_list = False
            out.append(line)
            continue
        if in_fence:
            out.append(line)
            continue
        if LIST_ITEM.match(line):
            if not in_list:
                prev = out[-1] if out else ""
                if prev.strip() != "":
                    out.append("")  # Leerzeile vor Listenbeginn
            in_list = True
        elif line.strip() == "":
            # Leerzeile beendet die Liste noch nicht (könnte lockere Liste sein),
            # aber zwei Leerzeilen / neuer Absatz schon: konservativ Liste beenden.
            in_list = in_list and False if out and out[-1].strip() == "" else in_list
        elif line[:1] not in (" ", "\t"):
            in_list = False  # nicht eingerückter Fließtext beendet die Liste
        out.append(line)
    return "\n".join(out)


def main(argv: list[str]) -> int:
    check = "--check" in argv
    files = [a for a in argv[1:] if not a.startswith("--")]
    if not files:
        sys.exit("Aufruf: fix_lists.py [--check] DATEI.md ...")
    need = 0
    for f in files:
        p = Path(f)
        original = p.read_text(encoding="utf-8")
        fixed = fix(original)
        if fixed != original:
            need += 1
            if check:
                print(f"[fix nötig] {f}")
            else:
                p.write_text(fixed, encoding="utf-8")
                print(f"[gefixt] {f}")
        else:
            print(f"[ok] {f}")
    return 1 if (check and need) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
