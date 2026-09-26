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
    p = os.path.join(PDIR, name)
    with open(p, "w", encoding="utf-8") as fh:
        fh.write(text)
    made.append(p)

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

    # M05-Bau: zweite, ungeschützte Aktion in derselben Datei + Helfer-Aufruf VOR dem Guard
    w("_st_multi.action.ts",
      'import { checkPolicy } from "../../platform/policy.ts";\n'
      'import { pool } from "../../db.ts";\n'
      'async function helper(){ return pool.query("SELECT m05_apply(1)"); }\n'
      'export async function ok1(c:any){\n'
      '  const decision = await checkPolicy(c);\n  if (!decision.allowed) { return 1; }\n  return helper();\n}\n'
      'export async function unguarded(c:any){\n  return helper();\n}\n'
      'export async function early(c:any){\n  await helper();\n'
      '  const decision = await checkPolicy(c);\n  if (!decision.allowed) { return 1; }\n  return 2;\n}\n')
    # Fachbefehl (DB-Funktion) außerhalb einer *.action.ts
    w("_st_bypass.ts", 'import { pool } from "../../db.ts";\nexport const x = () => pool.query("SELECT m05_admit($1,$2,$3)");\n')

    from validators.checks import adr02_imports as a2, adr04_policy as a4
    r2 = a2.run(); r4 = a4.run()
    multi = [f for f in r4.findings if "_st_multi" in f.detail]
    expect("ADR-04: zweite ungeschützte Aktion je Datei wird ROT",
           any(not f.ok and "unguarded()" in f.detail for f in multi))
    expect("ADR-04: Helfer-/DB-Zugriff vor dem Guard wird ROT",
           any(not f.ok and "early()" in f.detail and "VOR dem Policy-Guard" in f.detail for f in multi))
    expect("ADR-04: DB-Fachbefehl außerhalb *.action.ts wird ROT",
           any("_st_bypass" in f.detail and not f.ok for f in r4.findings))
    expect("ADR-02: dyn. import(`../${x}/...`) wird ROT", any("_st_tpl" in f.detail and not f.ok for f in r2.findings))
    expect("ADR-04: String-Decoy-Guard wird ROT", any("_st_decoy" in f.detail and not f.ok for f in r4.findings))
    expect("ADR-04: Destrukturierung mit echtem Guard bleibt GRÜN", any("_st_ok" in f.detail and f.ok for f in r4.findings))
finally:
    for p in made:
        try:
            os.remove(p)
        except OSError:
            pass  # Probe-Datei bereits entfernt — Aufräumen ist best effort

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
# Aufräum-PR (CodeQL): „Archiv“-Endung ohne ZIP-Inhalt wurde still übersprungen -> jetzt als Rohtext geprüft.
fz = os.path.join(tempfile.mkdtemp(prefix="vv_selftest_"), "export.xlsx")
with open(fz, "w", encoding="utf-8") as fh:
    fh.write("Name;IBAN\nMuster;" + IBAN + "\n")
gr2 = CheckResult(name="t", adr="K31"); g._scan_archive(fz, "export.xlsx", gr2)
out2 = "\n".join(f.detail for f in gr2.findings)
expect("K31: falsche Archiv-Endung (Text als .xlsx) wird ROT, maskiert", any(not f.ok for f in gr2.findings) and IBAN not in out2)
os.remove(fz); os.rmdir(os.path.dirname(fz))

# ADR-01 (M05-Bau): Reihenfolge der Policy-Statements zählt.
from validators.checks.adr01_rls import analyze
T = "CREATE TABLE t (id int, tenant_id uuid); ALTER TABLE t ENABLE ROW LEVEL SECURITY; ALTER TABLE t FORCE ROW LEVEL SECURITY; "
expect("ADR-01: idempotentes DROP IF EXISTS + CREATE POLICY bleibt GRÜN",
       analyze([T + "DROP POLICY IF EXISTS p ON t; CREATE POLICY p ON t USING (true);"])["t"] == [])
expect("ADR-01: CREATE POLICY gefolgt von DROP POLICY wird ROT",
       analyze([T + "CREATE POLICY p ON t USING (true); DROP POLICY p ON t;"])["t"] != [])

# Mermaid: kaputt/leer wird abgelehnt.
from validators.checks.k29_dossier import _mermaid_problem
expect("K29: unbalanciertes Mermaid wird ROT", _mermaid_problem("```mermaid\nflowchart TB\n A[x --> B\n```") is not None)
expect("K29: leeres classDiagram wird ROT", _mermaid_problem("```mermaid\nclassDiagram\n```") is not None)
expect("K29: classDiagram mit Beziehung bleibt GRÜN (ohne Regex geprüft)",
       _mermaid_problem("```mermaid\nclassDiagram\n  A <|-- B\n```") is None)
expect("K29: Flowchart ohne Kante wird ROT (ohne Regex geprüft)",
       _mermaid_problem("```mermaid\nflowchart TB\n  A[x]\n  B[y]\n```") is not None)

# R6/H-14 (M05-Reparaturrunde 1): CI + CodeQL müssen auf dem REALEN Hauptbranch auslösen.
# Realer Hauptbranch = `master` (git); zusätzlich `main` als Migrationsziel. Ohne YAML-Abhängigkeit:
# den push.branches-Block zeilengenau lesen.
def _push_branches(path: str) -> list[str]:
    """Liest `on: → push: → branches: [..]` zeilenweise (kein Regex-Backtracking, CodeQL py/redos)."""
    with open(path, encoding="utf-8") as fh:
        lines = fh.read().splitlines()
    in_on = in_push = False
    for ln in lines:
        body = ln.split("#", 1)[0].rstrip()
        if not body.strip():
            continue
        indent = len(body) - len(body.lstrip())
        key = body.strip()
        if indent == 0:
            in_on, in_push = key == "on:", False
        elif in_on and key == "push:":
            in_push = True
        elif in_on and in_push and key.startswith("branches:") and "[" in key and "]" in key:
            inner = key[key.index("[") + 1:key.rindex("]")]
            return [b.strip().strip('"\'') for b in inner.split(",") if b.strip()]
        elif in_on and key.endswith(":") and not key.startswith("branches"):
            in_push = key == "push:"
    return []
# Review R2: feste Hauptbranch-Menge — nicht aus origin/HEAD ableiten (ein Klon eines Klons erbt dort
# einen Feature-Branch und würde die Probe fälschlich rot machen).
_mains = {"master", "main"}
for _wf in (".github/workflows/ci.yml", ".github/workflows/codeql.yml"):
    _b = _push_branches(_wf)
    expect(f"R6: {_wf} push-Trigger deckt realen Hauptbranch ({', '.join(sorted(_mains))})", _mains.issubset(set(_b)))

# P57: pgboss.*-Tabellen nur über die generierte Migration; anderswo = ROT (kein Schlupfloch).
import validators.checks.project_recon as _pr
_probe = REPO_MIG = os.path.join("db", "migrations", "9999_selftest_probe.sql")
try:
    with open(_probe, "w", encoding="utf-8") as _fh:
        _fh.write("CREATE TABLE pgboss.schmuggel (id int);\n")
    _r = _pr.run()
    expect("P57: pgboss-Tabelle außerhalb der generierten Migration wird ROT",
           any(not f.ok and "9999_selftest_probe.sql" in f.detail for f in _r.findings))
finally:
    try:
        os.remove(_probe)
    except OSError:
        pass  # Probe-Migration bereits entfernt — Aufräumen ist best effort
_r2 = _pr.run()
expect("P57: generierte pg-boss-Migration bleibt GRÜN (kein Fund zu pgboss)",
       all(f.ok for f in _r2.findings if "pgboss" in f.detail))

# C-1 (Kontext-Signatur): Kontext-GUC in App-Code und Schlüsselmaterial in der Web-App werden ROT,
# ein bloßer Kommentar bleibt GRÜN; eine spätere GUC-Definition von vv_current_tenant() wird ROT.
from validators.checks import c1_context as _c1
_c1dir = os.path.join("apps", "web", "src", "modules", "person")
_c1files = {n: os.path.join(_c1dir, n) for n in ("_st_c1_guc.ts", "_st_c1_ok.ts", "_st_c1_key.ts", "_st_c1_setlocal.ts",
                                                  "_st_c1_dyn.ts", "_st_c1_subtle.ts")}
def _wf(path: str, text: str) -> None:
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)


try:
    _wf(_c1files["_st_c1_guc.ts"], 
        'export const q = (c: any, t: string) => c.query("SELECT set_config(' + "'app.tenant_id'" + ', $1, true)", [t]);\n')
    _wf(_c1files["_st_c1_ok.ts"], 
        "// früher: set_config('app.tenant_id') — heute nur vv_set_context(ticket)\nexport const ok = 1;\n")
    _wf(_c1files["_st_c1_key.ts"], 
        'import { createHmac } from "node:crypto";\nexport const s = (k: Buffer) => createHmac("sha256", k);\n')
    _wf(_c1files["_st_c1_setlocal.ts"], 
        'export const q = (c: any) => c.query("SET LOCAL app.actor = ' + "'x'" + '");\n')
    # Review R1 (Codex N-03): dynamisch gebauter GUC-Name + WebCrypto-Schlüsselmaterial
    _wf(_c1files["_st_c1_dyn.ts"], 
        "const name = 'app.' + 'tenant_id';\nexport const q = (c: any, t: string) => "
        "c.query('SELECT set_config($1,$2,true)', [name, t]);\n")
    _wf(_c1files["_st_c1_subtle.ts"], 
        "export const k = (raw: ArrayBuffer) => crypto.subtle.importKey('raw', raw, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);\n")
    _f = _c1.static_findings()
    expect("C-1/R1: dynamisch gebauter GUC-Name (set_config($1…)) wird ROT", any(not f.ok and "_st_c1_dyn" in f.detail for f in _f))
    expect("C-1/R1: WebCrypto-Schlüsselmaterial in der Web-App wird ROT", any(not f.ok and "_st_c1_subtle" in f.detail for f in _f))
    expect("C-1: set_config('app.…') im App-Code wird ROT", any(not f.ok and "_st_c1_guc" in f.detail for f in _f))
    expect("C-1: SET LOCAL app.actor im App-Code wird ROT", any(not f.ok and "_st_c1_setlocal" in f.detail for f in _f))
    expect("C-1: Erwähnung nur im Kommentar bleibt GRÜN", not any("_st_c1_ok" in f.detail for f in _f))
    expect("C-1: HMAC-/Schlüsselmaterial in der Web-App wird ROT", any(not f.ok and "_st_c1_key" in f.detail for f in _f))
    _mig = ["CREATE OR REPLACE FUNCTION vv_current_tenant() RETURNS uuid LANGUAGE sql AS $$ SELECT 1 $$;",
            "CREATE OR REPLACE FUNCTION vv_actor() RETURNS text LANGUAGE sql AS $$ SELECT 'x' $$;",
            "CREATE OR REPLACE FUNCTION vv_current_tenant() RETURNS uuid LANGUAGE sql AS $$ SELECT current_setting('app.tenant_id')::uuid $$;"]
    _m = _c1.static_findings(files=[], migrations=_mig)
    expect("C-1: spätere GUC-Definition von vv_current_tenant() wird ROT",
           any(not f.ok and "vv_current_tenant" in f.detail for f in _m))
    _mig2 = ["CREATE OR REPLACE FUNCTION vv_actor() RETURNS text LANGUAGE sql AS $$ SELECT c.actor FROM vv_ctx c "
             "WHERE c.exp_at >= statement_timestamp() $$;"]
    expect("C-1/R1: Ablaufprüfung mit statement_timestamp statt realer Uhr wird ROT",
           any(not f.ok and "reale Uhr" in f.detail for f in _c1.static_findings(files=[], migrations=_mig2)))
    expect("C-1: reale Migrationen: Kontext-Funktionen lesen keine GUC (GRÜN)",
           all(f.ok for f in _c1.static_findings(files=[]) ))
finally:
    for _p in _c1files.values():
        try:
            os.remove(_p)
        except OSError:
            pass  # Probe-Datei bereits entfernt — Aufräumen ist best effort

fails = [n for n, ok in R if not ok]
print("-" * 60)
print(f"Validator-Selbsttest: {sum(1 for _,ok in R if ok)}/{len(R)} Erwartungen erfüllt"
      + ("" if not fails else f" — FEHLGESCHLAGEN: {fails}"))
sys.exit(1 if fails else 0)
