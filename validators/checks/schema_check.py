"""Schema-Prüfung (ADR-09): jedes project.json-Fragment gegen das JSON-Schema."""
from __future__ import annotations
import json
from ..common import REPO, CheckResult, Finding, load_fragments


def run() -> CheckResult:
    res = CheckResult(name="project.json-Fragmente ↔ JSON-Schema", adr="ADR-09")
    schema_path = REPO / "project" / "schema" / "project.schema.json"
    try:
        import jsonschema  # type: ignore
    except ImportError:
        res.findings.append(Finding("ADR-09", False, "jsonschema nicht installiert (pip install -r validators/requirements.txt)"))
        return res
    schema = json.loads(schema_path.read_text(encoding="utf-8"))
    validator = jsonschema.Draft7Validator(schema)
    frags = load_fragments()
    if not frags:
        res.findings.append(Finding("ADR-09", False, "keine Fragmente gefunden"))
        return res
    for frag in frags:
        errs = sorted(validator.iter_errors({k: v for k, v in frag.items() if k != "__path"}),
                      key=lambda e: e.path)
        name = frag.get("code", frag["__path"])
        if errs:
            for e in errs:
                res.findings.append(Finding("ADR-09", False, f"{name}: {e.message}"))
        else:
            res.findings.append(Finding("ADR-09", True, f"{name}: schema-valide"))
    return res
