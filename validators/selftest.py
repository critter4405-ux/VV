#!/usr/bin/env python3
"""VV Validator-Selbsttest (Sicherheits-Regressionsschutz).

Die ADR-Validatoren sind das Sicherheits-Gate. Dieser Selbsttest weist bei JEDEM CI-Lauf nach,
dass sie die bekannten Umgehungen weiterhin ROT melden (und legitimen Code GRÜN) — damit eine
spätere Änderung die Validatoren nicht unbemerkt wirkungslos macht.

    python3 -m validators.selftest      # Exit 0 = alle Erwartungen erfüllt, sonst 1

Erzeugt temporäre Probe-Dateien, prüft die Validatoren und räumt wieder auf. Enthält KEINE echten
PII-Literale (Muster werden zur Laufzeit aus Fragmenten gebaut, damit der K31-Guard diese Datei
nicht selbst als Treffer wertet).
"""
from __future__ import annotations
import os, sys, zipfile, tempfile

os.chdir(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))  # Repo-Wurzel
sys.path.insert(0, ".")
R: list[tuple[str, bool]] = []
def expect(name: str, ok: bool) -> None:
    R.append((name, ok)); print(f"  [{'OK ' if ok else 'ABW'}] {name}")

PDIR = "apps/web/src/modules/person"
os.makedirs(PDIR, exist_ok=True)
made: list[str] = []
def w(name: str, text: str) -> None:
    p = os.path.join(PDIR, name); open(p, "w", encoding="utf-8").write(text); made.append(p)

# Muster zur Laufzeit bauen (kein Literal im Quelltext -> kein Selbst-K31-Treffer).
IBAN = "AT" + "61190430023457320" + "1"
MAIL = "person" + "@" + "private.invalid"

try:
    w("_st_tpl.ts", 'const m="rbac";\nexport async function x(){ return import(`../${m}/rbac.action.ts`); }\n')
    w("_st_decoy.action.ts",
      'import { checkPolicy } from "../../platform/policy.ts";\n'
      'import { pool } from "../../db.ts";\n'
      'export async function d(c:any){\n'
      '  const decision = checkPolicy({tenantId:c.t,actor:c.a,resource:"person",action:"deactivate",scopeNode:"x"});\n'
      '  const decoy = "if (!decision.allowed) { return; }";\n'
      '  await pool.query("DELETE FROM person");\n'
      '  return decoy.length;\n}\n')
    w("_st_ok.action.ts",
      'import { checkPolicy } from "../../platform/policy.ts";\n'
      'import { pool } from "../../db.ts";\n'
      'export async function u(c:any){\n'
      "  const { allowed } = checkPolicy({tenantId:c.t,actor:c.a,resource:'person',action:'update',scopeNode:'x'});\n"
      "  if (!allowed) { return { ok:false }; }\n"
      "  await pool.query(\"UPDATE person SET status='x'\");\n"
      "  return { ok:true };\n}\n")

    from validators.checks import adr02_imports as a2, adr04_policy as a4
    r2 = a2.run(); r4 = a4.run()
    expect("ADR-02: dyn. import(`../${x}/...`) wird ROT", any("_st_tpl" in f.detail and not f.ok for f in r2.findings))
    expect("ADR-04: String-Decoy-Guard wird ROT", any("_st_decoy" in f.detail and not f.ok for f in r4.findings))
    expect("ADR-04: Destrukturierung mit echtem Guard bleibt GRÜN", any("_st_ok" in f.detail and f.ok for f in r4.findings))
finally:
    for p in made:
        try: os.remove(p)
        except OSError: pass

# K31/Guard: Archiv mit PII im Dateinamen + Inhalt -> ROT, aber maskiert (kein Klartext).
z = os.path.join(tempfile.gettempdir(), "vv_selftest.zip")
with zipfile.ZipFile(z, "w") as zf:
    zf.writestr(MAIL + ".xml", "<r>" + IBAN + "</r>")
from validators.checks import synthetic_guard as g
from validators.common import CheckResult
gr = CheckResult(name="t", adr="K31"); g._scan_archive(z, "selftest.zip", gr)
out = "\n".join(f.detail for f in gr.findings)
expect("K31: Archiv-PII wird ROT", any(not f.ok for f in gr.findings))
expect("K31: kein Klartext-Leak (Dateiname/IBAN maskiert)", (MAIL not in out) and (IBAN not in out))
os.remove(z)

# Mermaid: kaputt/leer wird abgelehnt.
from validators.checks.k29_dossier import _mermaid_problem
expect("K29: unbalanciertes Mermaid wird ROT", _mermaid_problem("```mermaid\nflowchart TB\n A[x --> B\n```") is not None)
expect("K29: leeres classDiagram wird ROT", _mermaid_problem("```mermaid\nclassDiagram\n```") is not None)

fails = [n for n, ok in R if not ok]
print("-" * 60)
print(f"Validator-Selbsttest: {sum(1 for _,ok in R if ok)}/{len(R)} Erwartungen erfüllt"
      + ("" if not fails else f" — FEHLGESCHLAGEN: {fails}"))
sys.exit(1 if fails else 0)
