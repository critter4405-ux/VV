-- VV Migration 0003 — Audit-Log + Outbox (ADR-05), WP2-gehärtet
-- Hash-Kette wird DB-seitig in einem BEFORE-INSERT-Trigger unter per-Mandant-Advisory-Lock
-- berechnet -> keine App-Read-then-write-Race, kein Ketten-Fork (Review-Befund Gemini B / Codex #6).
-- Hash deckt ALLE unveränderlichen Felder ab. UPDATE/DELETE per Trigger hart blockiert.

CREATE TABLE IF NOT EXISTS audit_log (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id    uuid NOT NULL REFERENCES tenant(id),
    occurred_at  timestamptz NOT NULL DEFAULT now(),
    actor        text NOT NULL,
    action       text NOT NULL,
    subject_ref  text,                          -- ID/Pseudonym (B03-2), nie Klartext
    payload      jsonb NOT NULL DEFAULT '{}'::jsonb,
    prev_hash    text,                           -- vom Trigger gesetzt
    entry_hash   text NOT NULL DEFAULT ''        -- vom Trigger überschrieben
);
ALTER TABLE audit_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_log FORCE ROW LEVEL SECURITY;
CREATE POLICY audit_log_tenant_isolation ON audit_log
    USING (tenant_id = vv_current_tenant())
    WITH CHECK (tenant_id = vv_current_tenant());

-- Hash-Kette je Mandant, serialisiert per Advisory-Lock (kein Fork bei Nebenläufigkeit).
CREATE OR REPLACE FUNCTION vv_audit_chain() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE prev text;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtextextended(NEW.tenant_id::text, 0));
  SELECT entry_hash INTO prev FROM audit_log
    WHERE tenant_id = NEW.tenant_id ORDER BY id DESC LIMIT 1;
  NEW.prev_hash := prev;
  NEW.entry_hash := encode(
    digest(convert_to(
      coalesce(prev,'') || '|' || NEW.tenant_id::text || '|' || NEW.actor || '|' ||
      NEW.action || '|' || coalesce(NEW.subject_ref,'') || '|' || NEW.payload::text || '|' ||
      NEW.occurred_at::text, 'UTF8'), 'sha256'), 'hex');
  RETURN NEW;
END $$;
CREATE TRIGGER audit_log_chain BEFORE INSERT ON audit_log
  FOR EACH ROW EXECUTE FUNCTION vv_audit_chain();

-- Append-only: UPDATE/DELETE hart abweisen (auch für Tabelleneigentümer).
CREATE OR REPLACE FUNCTION vv_audit_block() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'audit_log ist append-only (Operation % nicht erlaubt).', TG_OP;
END $$;
CREATE TRIGGER audit_log_no_change BEFORE UPDATE OR DELETE ON audit_log
  FOR EACH ROW EXECUTE FUNCTION vv_audit_block();

-- Kopf-Anchoring (ADR-05, v1.1): reale Offsite-WORM-Senke = spätere Infra-Stufe (WP7/ADR-11).
CREATE TABLE IF NOT EXISTS audit_anchor (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id    uuid NOT NULL REFERENCES tenant(id),
    anchored_at  timestamptz NOT NULL DEFAULT now(),
    head_hash    text NOT NULL,
    reason       text NOT NULL
);
ALTER TABLE audit_anchor ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_anchor FORCE ROW LEVEL SECURITY;
CREATE POLICY audit_anchor_tenant_isolation ON audit_anchor
    USING (tenant_id = vv_current_tenant())
    WITH CHECK (tenant_id = vv_current_tenant());

-- Transactional Outbox (ADR-05). Idempotenz-Schlüssel je Mandant (Review-Befund Codex #13).
CREATE TABLE IF NOT EXISTS outbox (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       uuid NOT NULL REFERENCES tenant(id),
    topic           text NOT NULL,
    payload         jsonb NOT NULL,
    created_at      timestamptz NOT NULL DEFAULT now(),
    locked_until    timestamptz,                 -- Leasing für FOR UPDATE SKIP LOCKED (WP4)
    processed_at    timestamptz,
    idempotency_key text NOT NULL,
    CONSTRAINT outbox_idem_uk UNIQUE (tenant_id, idempotency_key)
);
ALTER TABLE outbox ENABLE ROW LEVEL SECURITY;
ALTER TABLE outbox FORCE ROW LEVEL SECURITY;
CREATE POLICY outbox_tenant_isolation ON outbox
    USING (tenant_id = vv_current_tenant())
    WITH CHECK (tenant_id = vv_current_tenant());
