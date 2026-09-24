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
WRITE = re.compile(r"\b(INSERT\s+INTO|UPDATE\s+[A-Za-z_]\w*\s+SET|DELETE\s+FROM)\b"
                   # M05-Bau: Fachbefehle laufen als DB-Funktionen (SELECT m05_x(...)/rbac_x(...)) — sie zählen
                   # wie Schreibzugriffe und sind nur aus *.action.ts (nach dem Policy-Guard) erlaubt.
                   r"|\bSELECT\s+(?:\*\s+FROM\s+)?(?:m05|rbac)_\w+\s*\(", re.IGNORECASE)
# Pro exportierter Aktion (M05-Bau: vorher prüfte der Validator nur den ERSTEN Guard je Datei —
# eine zweite, ungeschützte Aktion in derselben Datei blieb grün).
FUNC_START = re.compile(r"^(export\s+)?(?:async\s+)?function\s+(\w+)\s*[<(]", re.MULTILINE)
DB_ACCESS = re.compile(r"\bwithTenant\s*\(|\bpool\s*\.|\.query\s*\(|\.connect\s*\(")
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


def _guard_ok(nostr: str, base: str, require_import: bool = True) -> list[str]:
    # Import-Statement enthält den Pfad als STRING -> auf `base` prüfen (Strings erhalten);
    # Guard/Decision dagegen auf `nostr` (Strings geblankt, damit Decoy-Strings nicht zählen).
    problems: list[str] = []
    if not ((IMPORT_POLICY.search(base) or not require_import) and CALL_POLICY.search(base)):
        miss = []
        if require_import and not IMPORT_POLICY.search(base): miss.append("Import checkPolicy fehlt")
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


def _function_segments(nostr: str) -> list[tuple[str, bool, int, int]]:
    """(Name, exportiert?, Start, Ende) je Top-Level-Funktion (grob, ohne TS-Parser)."""
    starts = [(m.start(), m.group(2), bool(m.group(1))) for m in FUNC_START.finditer(nostr)]
    out = []
    for i, (pos, name, exported) in enumerate(starts):
        end = starts[i + 1][0] if i + 1 < len(starts) else len(nostr)
        out.append((name, exported, pos, end))
    return out


def check_actions(raw: str) -> list[str]:
    """Jede EXPORTIERTE Funktion einer *.action.ts, die (direkt oder über lokale Helfer) die DB
    erreicht, muss ZUERST checkPolicy aufrufen, das Ergebnis mit `if (!x.allowed) return/throw`
    gaten und darf VOR dem Guard weder DB noch lokale Helfer aufrufen."""
    base = _blank_comments(raw)
    nostr = _blank_strings(base)
    segs = _function_segments(nostr)
    if not (IMPORT_POLICY.search(base) and CALL_POLICY.search(base)):
        return ["Import/Aufruf checkPolicy fehlt"]
    local_helpers = [name for name, exported, _, _ in segs if not exported]
    helper_call = re.compile(r"\b(" + "|".join(map(re.escape, local_helpers)) + r")\s*\(") if local_helpers else None
    problems: list[str] = []
    for name, exported, a, b in segs:
        if not exported:
            continue
        seg_nostr, seg_base = nostr[a:b], base[a:b]
        body_start = seg_nostr.find("{")
        body_nostr = seg_nostr[body_start:] if body_start >= 0 else seg_nostr
        body_base = seg_base[body_start:] if body_start >= 0 else seg_base
        sensitive = [m.start() for m in DB_ACCESS.finditer(body_nostr)]
        sensitive += [m.start() for m in WRITE.finditer(body_base)]
        if helper_call:
            sensitive += [m.start() for m in helper_call.finditer(body_nostr) if m.group(1) != "denied"]
        if not sensitive:
            continue                       # rein/ohne DB -> kein Guard nötig
        probs = _guard_ok(body_nostr, body_base, require_import=False)
        if not probs:
            guard = None
            m = DECISION_ASSIGN.search(body_nostr)
            if m:
                guard = re.search(rf"if\s*\(\s*!\s*{re.escape(m.group(1))}\s*\.\s*allowed\s*\)", body_nostr)
            else:
                md = DECISION_DESTRUCT.search(body_nostr)
                fm = re.search(r"\ballowed\b\s*(?::\s*(\w+))?", md.group(1)) if md else None
                if fm:
                    guard = re.search(rf"if\s*\(\s*!\s*{re.escape(fm.group(1) or 'allowed')}\s*\)", body_nostr)
            if guard and min(sensitive) < guard.start():
                probs.append("DB-/Helfer-Zugriff VOR dem Policy-Guard")
        if probs:
            problems.append(f"{name}(): " + "; ".join(probs))
    return problems


def run() -> CheckResult:
    res = CheckResult(name="Zentraler Policy-Prüfpunkt nicht umgangen", adr="ADR-04")
    ts = [p for p in glob.glob(str(SRC / "**" / "*.ts"), recursive=True) if not p.endswith(".test.ts")]
    actions = [p for p in ts if p.endswith(".action.ts")]
    if not actions:
        res.findings.append(Finding("ADR-04", False, "keine *.action.ts gefunden (Beispiel-Aktion fehlt)"))

    for path in sorted(actions):
        rel = os.path.relpath(path, REPO)
        probs = check_actions(open(path, encoding="utf-8").read())
        res.findings.append(Finding("ADR-04", not probs,
            f"{rel}: " + ("; ".join(probs) if probs else "jede exportierte Aktion: checkPolicy() + Guard vor DB-Zugriff")))

    # Schreibzugriffe/Fachbefehle außerhalb erlaubter Stellen (Strings bleiben -> SQL sichtbar; Kommentare weg).
    for path in sorted(ts):
        rel = os.path.relpath(path, REPO).replace("\\", "/")
        allowed = rel.endswith(".action.ts") or rel in WRITE_ALLOWLIST
        base = _blank_comments(open(path, encoding="utf-8").read())
        if WRITE.search(base) and not allowed:
            res.findings.append(Finding("ADR-04", False,
                f"{rel}: DB-Schreibzugriff/Fachbefehl außerhalb *.action.ts/Allowlist (umgeht Policy)"))
    return res
