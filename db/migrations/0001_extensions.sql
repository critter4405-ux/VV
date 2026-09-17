-- VV Migration 0001 — Extensions & Grundrollen
-- Ein Migrations-Set (ADR-02). Reihenfolge über Dateinamen.

CREATE EXTENSION IF NOT EXISTS pgcrypto;   -- gen_random_uuid(), digest() für Hash-Kette (ADR-05)

-- App-Rolle OHNE BYPASSRLS (ADR-01): die Mandantentrennung übersteht App-Bugs.
-- (Rolle wird vom Superuser-Init erstellt; im Compose ist POSTGRES_USER die App-Rolle.)
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'vv_app') THEN
    CREATE ROLE vv_app LOGIN NOBYPASSRLS;
  END IF;
  -- Dedizierte Append-only-Audit-Rolle (ADR-05): nur INSERT, kein UPDATE/DELETE.
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'vv_audit_writer') THEN
    CREATE ROLE vv_audit_writer NOBYPASSRLS;
  END IF;
END $$;
