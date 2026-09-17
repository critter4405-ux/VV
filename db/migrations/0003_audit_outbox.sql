-- VV Migration 0003 — Governance & Audit-Log + Transactional Outbox (ADR-05, BASIS-03)
-- Append-only Hash-Kette je Mandant; Events in derselben Transaktion wie die Datenänderung.

-- ---------------------------------------------------------------------------
-- Audit-Log (BASIS-03) — append-only, Hash-Kette je Mandant. tenant-scoped.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS audit_log (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id    uuid NOT NULL REFERENCES tenant(id),
    occurred_at  timestamptz NOT NULL DEFAULT now(),
    actor        text NOT NULL,                 -- Mensch/Agent/System (Referenz, kein Klartext-Personenbezug)
    action       text NOT NULL,
    subject_ref  text,                          -- ID/Pseudonym (B03-2), NIE Klartext
    payload      jsonb NOT NULL DEFAULT '{}'::jsonb,
    prev_hash    text,
    entry_hash   text NOT NULL                  -- H(prev_hash + Inhalt), Kette (ADR-05)
);
ALTER TABLE audit_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_log FORCE ROW LEVEL SECURITY;
CREATE POLICY audit_log_tenant_isolation ON audit_log
    USING (tenant_id = vv_current_tenant())
    WITH CHECK (tenant_id = vv_current_tenant());

-- Append-only auf DB-Rollenebene: kein UPDATE/DELETE für Audit-Writer (ADR-05).
REVOKE UPDATE, DELETE ON audit_log FROM PUBLIC;
GRANT INSERT, SELECT ON audit_log TO vv_audit_writer;

-- Kopf-Anchoring (ADR-05, v1.1): täglich/kritisch in Offsite-WORM gespiegelt.
CREATE TABLE IF NOT EXISTS audit_anchor (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id    uuid NOT NULL REFERENCES tenant(id),
    anchored_at  timestamptz NOT NULL DEFAULT now(),
    head_hash    text NOT NULL,
    reason       text NOT NULL                  -- 'daily' | 'critical:<event>'
);
ALTER TABLE audit_anchor ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_anchor FORCE ROW LEVEL SECURITY;
CREATE POLICY audit_anchor_tenant_isolation ON audit_anchor
    USING (tenant_id = vv_current_tenant())
    WITH CHECK (tenant_id = vv_current_tenant());

-- ---------------------------------------------------------------------------
-- Transactional Outbox (ADR-05) — Event in derselben Tx wie die Datenänderung.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS outbox (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id     uuid NOT NULL REFERENCES tenant(id),
    topic         text NOT NULL,
    payload       jsonb NOT NULL,
    created_at    timestamptz NOT NULL DEFAULT now(),
    processed_at  timestamptz,
    -- Idempotenz-Schlüssel (ADR-06): kein doppelter Effekt bei Retry.
    idempotency_key text NOT NULL UNIQUE
);
ALTER TABLE outbox ENABLE ROW LEVEL SECURITY;
ALTER TABLE outbox FORCE ROW LEVEL SECURITY;
CREATE POLICY outbox_tenant_isolation ON outbox
    USING (tenant_id = vv_current_tenant())
    WITH CHECK (tenant_id = vv_current_tenant());
