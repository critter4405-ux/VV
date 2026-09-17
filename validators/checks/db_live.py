"""ADR-01/-04 LIVE-Check (WP5/Review Codex #14): prüft die Invarianten am effektiven
End-Zustand einer echten PostgreSQL (pg_class/pg_policy/pg_roles), nicht am Text.

Läuft, wenn VV_VALIDATE_DSN auf eine bereits migrierte DB zeigt (in CI gesetzt -> gate-blockierend).
Ohne DSN:
  - VV_REQUIRE_LIVE gesetzt (CI/Gate)  -> FAIL (ein übersprungener Live-Check ist im Gate KEIN PASS)
  - sonst (lokal)                      -> SKIPPED (weder pass noch fail, klar ausgewiesen)
Review-Runde 2, Codex #5-new: „Live übersprungen" durfte bisher als erfolgreicher Check zählen.
"""
from __future__ import annotations
import os
from ..common import CheckResult, Finding


def run() -> CheckResult:
    res = CheckResult(name="LIVE: RLS/Rollen effektiv (echte PostgreSQL)", adr="ADR-01")
    dsn = os.environ.get("VV_VALIDATE_DSN")
    if not dsn:
        if os.environ.get("VV_REQUIRE_LIVE"):
            res.findings.append(Finding("ADR-01", False,
                "VV_REQUIRE_LIVE gesetzt, aber kein VV_VALIDATE_DSN — Live-Check im Gate PFLICHT (kein stiller PASS)"))
        else:
            res.findings.append(Finding("ADR-01", False,
                "übersprungen: kein VV_VALIDATE_DSN (lokal; im Gate via VV_REQUIRE_LIVE erzwungen)",
                skipped=True))
        return res
    try:
        import psycopg  # type: ignore
    except ImportError:
        res.findings.append(Finding("ADR-01", False, "psycopg nicht installiert (validators/requirements.txt)"))
        return res
    try:
        with psycopg.connect(dsn) as conn, conn.cursor() as cur:
            # App-Rolle darf RLS nicht umgehen.
            cur.execute("SELECT rolsuper, rolbypassrls FROM pg_roles WHERE rolname='vv_app'")
            row = cur.fetchone()
            if not row:
                res.findings.append(Finding("ADR-01", False, "Rolle vv_app existiert nicht"))
            elif row[0] or row[1]:
                res.findings.append(Finding("ADR-01", False, f"vv_app rolsuper={row[0]} rolbypassrls={row[1]} (muss f/f sein)"))
            else:
                res.findings.append(Finding("ADR-01", True, "vv_app: NOSUPERUSER + NOBYPASSRLS"))
            # Jede Tabelle mit tenant_id: FORCE RLS + Policy.
            cur.execute("""
                SELECT c.relname, c.relforcerowsecurity,
                       (SELECT count(*) FROM pg_policy p WHERE p.polrelid=c.oid)
                FROM pg_class c
                JOIN pg_namespace n ON n.oid=c.relnamespace AND n.nspname='public'
                WHERE c.relkind='r'
                  AND EXISTS (SELECT 1 FROM pg_attribute a
                              WHERE a.attrelid=c.oid AND a.attname='tenant_id' AND NOT a.attisdropped)
                ORDER BY c.relname
            """)
            rows = cur.fetchall()
            if not rows:
                res.findings.append(Finding("ADR-01", False, "keine tenant_id-Tabelle in der DB gefunden"))
            for name, forced, npol in rows:
                ok = bool(forced) and npol > 0
                res.findings.append(Finding("ADR-01", ok,
                    f"{name}: force={forced}, policies={npol}" + ("" if ok else "  <- FEHLT")))
    except Exception as e:  # noqa: BLE001
        res.findings.append(Finding("ADR-01", False, f"LIVE-Check-Fehler: {e}"))
    return res
