"""ADR-04: keine Aktion/kein DB-Schreibzugriff umgeht den zentralen Policy-Prüfpunkt.
Review-Runde 3, Codex #3: Der Guard wurde in einem String-Literal versteckt
(`const decoy = "if (!decision.allowed) { return; }"`) und trotzdem grün gewertet, weil nur
Kommentare, nicht aber Strings entfernt wurden. Außerdem (Gemini): Destrukturierung
`const { allowed } = checkPolicy(...)` wurde gar nicht erkannt (False-Positive).

Lösung ohne echten TS-Parser: LÄNGENTREUES Blanken.
- `base`  = Quelle mit geblankten Kommentaren (Strings bleiben) -> DB-Schreibzugriffe (SQL steht
  IN Strings) werden gefunden.
- `nostr` = `base` zusätzlich mit geblankten String-/Template-Innereien -> Guard/Decision werden
  nur als echter CODE erkannt (Decoy-Strings zählen nicht). Gleiche Länge -> Positionen passen.
Hinweis: robust final = TS-AST + Kontrollfluss; der zentrale Effekt-/Unit-of-Work-Zwang folgt
beim Modul-Bau (dann sind DB-Schreibzugriffe technisch erst nach der Policy-Entscheidung erreichbar).
"""
from __future__ import annotations
import glob
import os
import re
from ..common import REPO, CheckResult, Finding

SRC = REPO / "apps" / "web" / "src"
WRITE = re.compile(r"\b(INSERT\s+INTO|UPDATE\s+[A-Za-z_]\w*\s+SET|DELETE\s+FROM)\b", re.IGNORECASE)
IMPORT_POLICY = re.compile(r"""import\s*\{[^}]*\bcheckPolicy\b[^}]*\}\s*from\s*['"][^'"]*platform/policy""")
CALL_POLICY = re.compile(r"\bcheckPolicy\s*\(")
DECISION_ASSIGN = re.compile(r"(?:const|let|var)\s+(\w+)\s*=\s*(?:await\s+)?checkPolicy\s*\(")
DECISION_DESTRUCT = re.compile(r"(?:const|let|var)\s*\{\s*([^}]*)\}\s*=\s*(?:await\s+)?checkPolicy\s*\(")

WRITE_ALLOWLIST = {"apps/web/src/platform/audit.ts"}


def _blank_comments(src: str) -> str:
    """Kommentare durch gleich lange Leerzeichen ersetzen (Zeilenumbrüche erhalten)."""
    out = list(src)
    i, n = 0, len(src)
    while i < n:
        two = src[i:i + 2]
        if two == "//":
            j = i
            while j < n and src[j] != "\n":
                out[j] = " "; j += 1
            i = j
        elif two == "/*":
            j = i
            while j < n and src[j - 1:j + 1] != "*/":
                if src[j] != "\n":
                    out[j] = " "
                j += 1
            # schließendes '/' des '*/' auch blanken
            if j < n:
                out[j] = " "
            i = j + 1
        else:
            i += 1
    return "".join(out)


def _blank_strings(src: str) -> str:
    """String-/Template-Literal-INNEREIEN durch Leerzeichen ersetzen (Quotes + Länge bleiben)."""
    out = list(src)
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if c in "'\"`":
            quote = c
            j = i + 1
            while j < n:
                if src[j] == "\\":
                    out[j] = " "
                    if j + 1 < n:
                        out[j + 1] = " "
                    j += 2
                    continue
                if src[j] == quote:
                    break
                if src[j] != "\n":
                    out[j] = " "
                j += 1
            i = j + 1
        else:
            i += 1
    return "".join(out)


def _guard_ok(nostr: str, base: str) -> list[str]:
    # Import-Statement enthält den Pfad als STRING -> auf `base` prüfen (Strings erhalten);
    # Guard/Decision dagegen auf `nostr` (Strings geblankt, damit Decoy-Strings nicht zählen).
    problems: list[str] = []
    if not (IMPORT_POLICY.search(base) and CALL_POLICY.search(base)):
        miss = []
        if not IMPORT_POLICY.search(base): miss.append("Import checkPolicy fehlt")
        if not CALL_POLICY.search(base): miss.append("Aufruf checkPolicy() fehlt")
        return miss

    # Entscheidungsvariable ermitteln — benannt ODER destrukturiert.
    guard_re = None
    m = DECISION_ASSIGN.search(nostr)
    if m:
        var = m.group(1)
        guard_re = re.compile(rf"if\s*\(\s*!\s*{re.escape(var)}\s*\.\s*allowed\s*\)")
    else:
        md = DECISION_DESTRUCT.search(nostr)
        if md:
            fields = md.group(1)
            fm = re.search(r"\ballowed\b\s*(?::\s*(\w+))?", fields)
            if not fm:
                return ["checkPolicy destrukturiert, aber 'allowed' nicht entnommen"]
            name = fm.group(1) or "allowed"
            guard_re = re.compile(rf"if\s*\(\s*!\s*{re.escape(name)}\s*\)")
        else:
            return ["checkPolicy-Ergebnis wird nicht in einer Variablen gehalten (kann nicht gaten)"]

    guard = guard_re.search(nostr)
    if not guard:
        problems.append("kein negativer Guard auf die Policy-Entscheidung vor Schreibzugriff")
    else:
        tail = nostr[guard.end(): guard.end() + 160]
        if not re.search(r"\b(return|throw)\b", tail):
            problems.append("Guard ohne return/throw (Entscheidung folgenlos)")
    # Kein DB-Schreibzugriff VOR dem Guard (Positionen aus `base`, gleiche Länge wie `nostr`).
    first_write = WRITE.search(base)
    if first_write and guard and first_write.start() < guard.start():
        problems.append("DB-Schreibzugriff steht VOR dem Policy-Guard (Reihenfolge umgeht Policy)")
    return problems


def run() -> CheckResult:
    res = CheckResult(name="Zentraler Policy-Prüfpunkt nicht umgangen", adr="ADR-04")
    ts = glob.glob(str(SRC / "**" / "*.ts"), recursive=True)
    actions = [p for p in ts if p.endswith(".action.ts")]
    if not actions:
        res.findings.append(Finding("ADR-04", False, "keine *.action.ts gefunden (Beispiel-Aktion fehlt)"))

    for path in sorted(actions):
        rel = os.path.relpath(path, REPO)
        raw = open(path, encoding="utf-8").read()
        base = _blank_comments(raw)
        nostr = _blank_strings(base)
        probs = _guard_ok(nostr, base)
        res.findings.append(Finding("ADR-04", not probs,
            f"{rel}: " + ("; ".join(probs) if probs else "checkPolicy() gatet Schreibzugriffe (Guard + return)")))

    # Schreibzugriffe außerhalb erlaubter Stellen (Strings bleiben -> SQL sichtbar; Kommentare weg).
    for path in sorted(ts):
        rel = os.path.relpath(path, REPO).replace("\\", "/")
        allowed = rel.endswith(".action.ts") or rel in WRITE_ALLOWLIST
        base = _blank_comments(open(path, encoding="utf-8").read())
        if WRITE.search(base) and not allowed:
            res.findings.append(Finding("ADR-04", False,
                f"{rel}: DB-Schreibzugriff außerhalb *.action.ts/Allowlist (umgeht Policy)"))
    return res
