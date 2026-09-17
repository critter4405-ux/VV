-- VV Migration 0004 — Freigabe-Objekt (Vier-Augen, ADR-04/ADR-07), WP4-gehärtet
-- Bindendes ist NIE direkte Aktion, sondern ein Freigabe-Objekt. Antragsteller != Freigeber.
-- Review-Befund Codex #7: status='approved' bei approved_by IS NULL war erlaubt -> jetzt per CHECK verboten.

CREATE TABLE IF NOT EXISTS approval (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id     uuid NOT NULL REFERENCES tenant(id),
    kind          text NOT NULL,                -- money | federation_report | deletion | external_pii | legal
    requested_by  text NOT NULL,
    approved_by   text,
    status        text NOT NULL DEFAULT 'pending',
    context       jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at    timestamptz NOT NULL DEFAULT now(),
    decided_at    timestamptz,
    CONSTRAINT approval_status_ck   CHECK (status IN ('pending','approved','rejected')),
    CONSTRAINT approval_four_eyes   CHECK (approved_by IS NULL OR approved_by <> requested_by),
    -- 'approved' erfordert einen (fremden) Freigeber + Entscheidungszeitpunkt:
    CONSTRAINT approval_approved_ck CHECK (status <> 'approved' OR (approved_by IS NOT NULL AND decided_at IS NOT NULL))
);
ALTER TABLE approval ENABLE ROW LEVEL SECURITY;
ALTER TABLE approval FORCE ROW LEVEL SECURITY;
CREATE POLICY approval_tenant_isolation ON approval
    USING (tenant_id = vv_current_tenant())
    WITH CHECK (tenant_id = vv_current_tenant());
