-- VV Migration 0001 — Extensions & Rollen (WP1: RLS-sichere Rollentrennung)
-- Läuft als Bootstrap-Superuser (POSTGRES_USER, z.B. vv_bootstrap). Die App-Rolle vv_app
-- ist bewusst NOSUPERUSER + NOBYPASSRLS und besitzt keine Tabellen -> RLS greift auch bei
-- App-Bugs. (Review-Befund Codex #2 / Gemini A: POSTGRES_USER=vv_app machte die App-Rolle
-- zum Superuser und umging RLS.)

CREATE EXTENSION IF NOT EXISTS pgcrypto;   -- gen_random_uuid(), digest() (Hash-Kette, ADR-05)

-- App-Rolle (Web/API): NOSUPERUSER + NOBYPASSRLS, besitzt keine Tabellen -> RLS greift.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'vv_app') THEN
    CREATE ROLE vv_app LOGIN NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE NOREPLICATION
      PASSWORD 'change_me_dev_only';
  ELSE
    ALTER ROLE vv_app LOGIN NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE NOREPLICATION;
  END IF;
END $$;

-- Worker-Rolle (Agenten/Jobs): eigene technische Identität, NICHT vv_app (Review-Runde 2,
-- Codex #4-new / Gemini #1: Web und Worker teilten sich eine Rolle -> Web hatte Outbox-Consumer-
-- und pg-boss-Rechte, die nur der Worker braucht). Ebenfalls NOSUPERUSER + NOBYPASSRLS.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'vv_worker') THEN
    CREATE ROLE vv_worker LOGIN NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE NOREPLICATION
      PASSWORD 'change_me_dev_only';
  ELSE
    ALTER ROLE vv_worker LOGIN NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE NOREPLICATION;
  END IF;
END $$;

-- pg-boss (ADR-06) legt seine Job-Tabellen in ein EIGENES Schema; der Worker ist dessen
-- Eigentümer und darf dort anlegen — OHNE datenbankweites CREATE-Recht und OHNE Zugriff auf
-- das public-Schema der Fachdaten (Review-Runde 2, Codex #3-new: vv_app fehlte CREATE SCHEMA).
CREATE SCHEMA IF NOT EXISTS pgboss AUTHORIZATION vv_worker;

-- Prod: Passwörter werden per Secret gesetzt (init-Wrapper liest VV_APP_PASSWORD/VV_WORKER_PASSWORD).
