-- VV Migration 0001 — Extensions & Rollen (WP1: RLS-sichere Rollentrennung)
-- Läuft als Bootstrap-Superuser (POSTGRES_USER, z.B. vv_bootstrap). Die App-Rolle vv_app
-- ist bewusst NOSUPERUSER + NOBYPASSRLS und besitzt keine Tabellen -> RLS greift auch bei
-- App-Bugs. (Review-Befund Codex #2 / Gemini A: POSTGRES_USER=vv_app machte die App-Rolle
-- zum Superuser und umging RLS.)

CREATE EXTENSION IF NOT EXISTS pgcrypto;   -- gen_random_uuid(), digest() (Hash-Kette, ADR-05)

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'vv_app') THEN
    CREATE ROLE vv_app LOGIN NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE NOREPLICATION
      PASSWORD 'change_me_dev_only';
  ELSE
    ALTER ROLE vv_app LOGIN NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE NOREPLICATION;
  END IF;
END $$;

-- Prod: Passwort wird per Secret gesetzt (init-Wrapper liest VV_APP_PASSWORD), nicht hier.
