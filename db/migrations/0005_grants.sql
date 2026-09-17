-- VV Migration 0005 — Least-Privilege-Grants für die App-Rolle vv_app (WP1)
-- Tabellen gehören dem Bootstrap-Superuser; vv_app bekommt nur die nötigen Rechte,
-- audit_* ausdrücklich APPEND-ONLY (INSERT/SELECT, kein UPDATE/DELETE).

GRANT USAGE ON SCHEMA public TO vv_app;

GRANT SELECT ON tenant TO vv_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON person, organisation, role_assignment, outbox, approval TO vv_app;

-- Audit: append-only (kein UPDATE/DELETE) — zusätzlich zum Block-Trigger aus 0003/0004.
GRANT SELECT, INSERT ON audit_log, audit_anchor TO vv_app;

GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO vv_app;

-- Outbox-Consumer-Funktionen (SECURITY DEFINER, 0003): NUR der Worker darf zustellen
-- (Review-Runde 2, Codex #4-new / Gemini #1). vv_app bekommt sie ausdrücklich NICHT — die
-- mandantenübergreifende SECURITY-DEFINER-Zustellung gehört allein zur Worker-Identität.
GRANT EXECUTE ON FUNCTION vv_outbox_claim(int) TO vv_worker;
GRANT EXECUTE ON FUNCTION vv_outbox_done(uuid) TO vv_worker;
-- Defensive: falls eine frühere Migration/Alt-DB das Recht vv_app gegeben hatte -> entziehen.
REVOKE EXECUTE ON FUNCTION vv_outbox_claim(int) FROM vv_app;
REVOKE EXECUTE ON FUNCTION vv_outbox_done(uuid) FROM vv_app;

-- Worker-Rolle: minimaler Fachdaten-Zugriff. Web SCHREIBT in die Outbox (Teil der Fach-Transaktion),
-- der Worker LIEST/verarbeitet sie nur über die Consumer-Funktionen. Für Stage-0-Protokollierung
-- braucht der Worker kein direktes DML auf public — pg-boss arbeitet im eigenen Schema pgboss.
GRANT USAGE ON SCHEMA public TO vv_worker;
GRANT USAGE ON SCHEMA pgboss TO vv_worker;   -- Eigentümer ist vv_worker (0001), CREATE inklusive
