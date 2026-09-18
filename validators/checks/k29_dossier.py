"""K29: 9-teiliges Bau-Dossier + Mermaid je Baustein. WP5-gehärtet (Review Gemini E / Codex #14):
- Status-bewusst: 'skeleton' darf Platzhalter haben (Stage 0 = Gerüst); ab 'in_bau'/'geprueft'/
  'freigegeben' wird Mindest-Inhalt je Abschnitt verlangt (kein Durchwinken von Dummy-Text).
- Mermaid-Grundsyntax wird geprüft (Block nicht leer, enthält Diagrammtyp/Kante).
- Evidenz-Link muss auf existierende Datei zeigen (kein toter Link).
"""
from __future__ import annotations
import re
from pathlib import Path
from ..common import REPO, CheckResult, Finding, load_fragments

PLACEHOLDER = re.compile(r"\(zu füllen beim Bau\)", re.IGNORECASE)
LINK = re.compile(r"\]\(([^)]+)\)")


def _mermaid_problem(text: str) -> str | None:
    """Strengere Mermaid-Grundprüfung (Review-Runde 2, Codex #5-new: vorher nur Muster).
    Gibt None zurück, wenn ok, sonst eine kurze Fehlerbeschreibung."""
    m = re.search(r"```mermaid\s*(.+?)```", text, re.DOTALL)
    if not m:
        return "Mermaid-Block fehlt"
    body = m.group(1).strip()
    if not body:
        return "Mermaid-Block leer"
    lines = [ln.strip() for ln in body.splitlines() if ln.strip()]
    if not re.match(r"^(flowchart|graph)\s+(TB|TD|BT|LR|RL)\b|^(sequenceDiagram|classDiagram|stateDiagram(-v2)?)\b", lines[0]):
        return "erste Zeile ist keine gültige Mermaid-Direktive"
    # Klammerbalance (Review-Runde 3, Codex #7: nicht geschlossene Node-Klammer galt als ok).
    for op, cl in (("[", "]"), ("(", ")"), ("{", "}")):
        if body.count(op) != body.count(cl):
            return f"unbalancierte Klammern '{op}{cl}' ({body.count(op)} vs. {body.count(cl)})"
    is_flow = bool(re.match(r"^(flowchart|graph)\b", lines[0]))
    if is_flow:
        opens = sum(1 for ln in lines if re.match(r"^subgraph\b", ln))
        closes = sum(1 for ln in lines if ln == "end")
        if opens != closes:
            return f"unbalancierte subgraph/end ({opens} subgraph vs. {closes} end)"
        if not re.search(r"-->|---|-\.->|==>", body):
            return "keine gültige Kante (-->/---/==>) im Flowchart"
    elif lines[0].startswith("sequenceDiagram"):
        if "->>" not in body and "-->>" not in body:
            return "keine Nachricht (->>/-->>) im Sequenzdiagramm"
    elif lines[0].startswith("classDiagram"):
        # leeres classDiagram (nur Direktive) galt zuvor als ok -> Inhalt verlangen.
        content = [ln for ln in lines[1:] if ln]
        if not content:
            return "leeres classDiagram (keine Klassen/Beziehungen)"
        if not any(re.search(r"(<\|--|\*--|o--|-->|\.\.>|:|\bclass\b)", ln) for ln in content):
            return "classDiagram ohne Klassen/Member/Beziehungen"
    elif lines[0].startswith("stateDiagram"):
        if not any("-->" in ln for ln in lines[1:]):
            return "stateDiagram ohne Übergänge"
    return None


def _mermaid_ok(text: str) -> bool:
    return _mermaid_problem(text) is None


def _check(path: Path, require_content: bool) -> list[str]:
    problems: list[str] = []
    text = path.read_text(encoding="utf-8")
    # 9 Abschnitte + Inhalt dazwischen
    positions = []
    for n in range(1, 10):
        m = re.search(rf"^##\s*{n}\.\s*(.+)$", text, re.MULTILINE)
        if not m:
            problems.append(f"Abschnitt {n} fehlt"); positions.append(None)
        else:
            positions.append(m.start())
    mp = _mermaid_problem(text)
    if mp:
        problems.append(f"Mermaid: {mp}")
    # Evidenz-Link existiert?
    ev = [l for l in LINK.findall(text) if "evidence/" in l]
    if not ev:
        problems.append("kein Evidenz-Link (Abschnitt 5)")
    else:
        for rel in ev:
            target = (path.parent / rel.split("#")[0]).resolve()
            if not target.exists():
                problems.append(f"toter Evidenz-Link: {rel}")
    if require_content:
        # zwischen aufeinanderfolgenden Headern muss echter Inhalt stehen (kein Platzhalter).
        idx = [p for p in positions if p is not None] + [len(text)]
        for a, b in zip(idx, idx[1:]):
            seg = text[a:b]
            seg_body = re.sub(r"^##.*$", "", seg, flags=re.MULTILINE).strip()
            if PLACEHOLDER.search(seg_body) or len(re.sub(r"\s+", "", seg_body)) < 20:
                problems.append("Abschnitt mit Platzhalter/zu wenig Inhalt (Status ≥ in_bau verlangt echten Inhalt)")
                break
    return problems


def run() -> CheckResult:
    res = CheckResult(name="9-teiliges Bau-Dossier + Mermaid (status-bewusst)", adr="K29")
    frags = load_fragments()
    seen = set()
    for f in frags:
        code = f.get("code"); path = REPO / f["dossier"]
        seen.add(str(path))
        require = f.get("status") not in ("skeleton", None)
        if not path.exists():
            res.findings.append(Finding("K29", False, f"{code}: Dossier fehlt")); continue
        probs = _check(path, require)
        res.findings.append(Finding("K29", not probs,
            f"{code}: " + ("; ".join(probs) if probs else ("9 Abschnitte + Mermaid + Evidenz"
            + (" + Inhalt" if require else " (Skeleton)")))))
    stage0 = REPO / "docs" / "bausteine" / "STAGE-0.md"
    if stage0.exists() and str(stage0) not in seen:
        probs = _check(stage0, require_content=True)   # STAGE-0 ist ein echtes Dossier
        res.findings.append(Finding("K29", not probs, "VV-STAGE-0: " + ("; ".join(probs) if probs else "vollständig + Mermaid + Evidenz")))
    return res
