-- VV Migration 0005 — Least-Privilege-Grants für die App-Rolle vv_app (WP1)
-- Tabellen gehören dem Bootstrap-Superuser; vv_app bekommt nur die nötigen Rechte,
-- audit_* ausdrücklich APPEND-ONLY (INSERT/SELECT, kein UPDATE/DELETE).

GRANT USAGE ON SCHEMA public TO vv_app;

GRANT SELECT ON tenant TO vv_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON person, organisation, role_assignment, outbox, approval TO vv_app;

-- Audit: append-only (kein UPDATE/DELETE) — zusätzlich zum Block-Trigger aus 0003/0004.
GRANT SELECT, INSERT ON audit_log, audit_anchor TO vv_app;

GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO vv_app;
