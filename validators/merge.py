"""Merge-Schritt (ADR-09): Fragmente -> project.merged.json (generiert).

Prüft Eindeutigkeit der Codes und dass jede Tabelle genau EINEN Eigentümer-Baustein
hat (ADR-02: keine Doppelung). Schreibt die Merge-Datei für Transparenz/CI-Artefakt."""
from __future__ import annotations
import json
from .common import REPO, load_fragments


def merge() -> dict:
    frags = load_fragments()
    codes: dict[str, str] = {}
    table_owner: dict[str, str] = {}
    errors: list[str] = []
    bausteine = []
    for f in frags:
        code = f.get("code")
        if code in codes:
            errors.append(f"doppelter Code {code}")
        codes[code] = f["__path"]
        for t in f.get("tables", []):
            name = t["name"]
            if name in table_owner:
                errors.append(f"Tabelle {name} hat mehrere Eigentümer ({table_owner[name]}, {code})")
            table_owner[name] = code
        bausteine.append({k: v for k, v in f.items() if k != "__path"})

    merged = {
        "project": "VV",
        "stage": 0,
        "generated": True,
        "bausteine": bausteine,
        "table_owner": table_owner,
        "merge_errors": errors,
    }
    out = REPO / "project" / "project.merged.json"
    out.write_text(json.dumps(merged, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return merged


if __name__ == "__main__":
    m = merge()
    print(f"gemerged: {len(m['bausteine'])} Bausteine, {len(m['table_owner'])} Tabellen, "
          f"{len(m['merge_errors'])} Fehler")
