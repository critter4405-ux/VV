-- VV Migration 0004 — Freigabe-Objekt (Vier-Augen, ADR-04/ADR-07)
-- Bindendes (Geld/Meldung/Löschung/Personendaten nach außen/rechtsverbindl. Erklärung)
-- ist NIE eine direkte Aktion, sondern erzeugt ein Freigabe-Objekt. Antragsteller ≠ Freigeber.

CREATE TABLE IF NOT EXISTS approval (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id     uuid NOT NULL REFERENCES tenant(id),
    kind          text NOT NULL,                -- 'money' | 'federation_report' | 'deletion' | 'external_pii' | 'legal'
    requested_by  text NOT NULL,                -- Referenz (kein Klartext-Personenbezug)
    approved_by   text,                         -- MUSS != requested_by (SoD, im App-Layer erzwungen)
    status        text NOT NULL DEFAULT 'pending', -- pending | approved | rejected
    context       jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at    timestamptz NOT NULL DEFAULT now(),
    decided_at    timestamptz,
    CONSTRAINT approval_four_eyes CHECK (approved_by IS NULL OR approved_by <> requested_by)
);
ALTER TABLE approval ENABLE ROW LEVEL SECURITY;
ALTER TABLE approval FORCE ROW LEVEL SECURITY;
CREATE POLICY approval_tenant_isolation ON approval
    USING (tenant_id = vv_current_tenant())
    WITH CHECK (tenant_id = vv_current_tenant());
