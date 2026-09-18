-- VV Migration 0004 — Freigabe-Objekt (Vier-Augen, ADR-04/ADR-07), WP4-gehärtet
-- Bindendes ist NIE direkte Aktion, sondern ein Freigabe-Objekt. Antragsteller != Freigeber.
-- Review-Befund Codex #7: status='approved' bei approved_by IS NULL war erlaubt -> jetzt per CHECK verboten.

-- Review-Runde 3, Codex #1 (CRITICAL): der Zustand der Vier-Augen-Freigabe (approved/Freigeber/
-- Token) lag zuvor als Aufrufer-Metadaten in der App -> spoof-/fälsch-/replay-bar. Jetzt lebt die
-- Freigabe in DIESER Tabelle: mit einmaligem Token, Wirkungsbereich (scope = effect_id + subject),
-- Ablauf und atomarem Consume. Die App KANN keinen Zustand mehr behaupten — sie kann nur eine
-- echte, fremd-genehmigte, nicht abgelaufene, noch nicht eingelöste Freigabe atomar verbrauchen.
CREATE TABLE IF NOT EXISTS approval (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id     uuid NOT NULL REFERENCES tenant(id),
    kind          text NOT NULL,                -- money | federation_report | deletion | external_pii | legal
    effect_id     text NOT NULL,                -- fixe Aktions-/Senken-Identität (nicht relabelbar)
    subject_ref   text NOT NULL,                -- worauf sich die Freigabe bezieht (ID/Pseudonym)
    requested_by  text NOT NULL,
    builder_model text NOT NULL DEFAULT '',     -- wer/was den Vorschlag baute (Reviewer-Unabhängigkeit)
    approved_by   text,
    reviewer_model text,                        -- muss andere Modellfamilie sein (ADR-07)
    status        text NOT NULL DEFAULT 'pending',
    token         uuid NOT NULL DEFAULT gen_random_uuid(),  -- Einmal-Freigabe-Token
    context       jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at    timestamptz NOT NULL DEFAULT now(),
    decided_at    timestamptz,
    expires_at    timestamptz,                  -- Freigabe verfällt
    consumed_at   timestamptz,                  -- atomar genau einmal einlösbar
    CONSTRAINT approval_token_uk    UNIQUE (tenant_id, token),
    CONSTRAINT approval_status_ck   CHECK (status IN ('pending','approved','rejected')),
    CONSTRAINT approval_four_eyes   CHECK (approved_by IS NULL OR approved_by <> requested_by),
    CONSTRAINT approval_reviewer_ck CHECK (reviewer_model IS NULL OR reviewer_model <> builder_model),
    -- 'approved' erfordert einen (fremden) Freigeber + Entscheidungszeitpunkt:
    CONSTRAINT approval_approved_ck CHECK (status <> 'approved' OR (approved_by IS NOT NULL AND decided_at IS NOT NULL))
);
ALTER TABLE approval ENABLE ROW LEVEL SECURITY;
ALTER TABLE approval FORCE ROW LEVEL SECURITY;
CREATE POLICY approval_tenant_isolation ON approval
    USING (tenant_id = vv_current_tenant())
    WITH CHECK (tenant_id = vv_current_tenant());

-- Atomarer Einmal-Consume: gibt genau dann die Freigabe-id zurück, wenn sie 'approved', nicht
-- abgelaufen, noch nicht eingelöst ist UND zu (effect_id, subject_ref) passt. Der UPDATE setzt
-- consumed_at unter demselben Prädikat -> zwei Prozesse können NICHT beide gewinnen (Replay-fest,
-- auch über Neustarts hinweg, da der Zustand in der DB liegt). SECURITY DEFINER, aber streng
-- tenant-gebunden über vv_current_tenant().
CREATE OR REPLACE FUNCTION vv_consume_approval(p_effect_id text, p_subject_ref text)
RETURNS uuid LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  UPDATE approval SET consumed_at = now()
  WHERE id = (
    SELECT id FROM approval
    WHERE tenant_id = vv_current_tenant()
      AND effect_id = p_effect_id AND subject_ref = p_subject_ref
      AND status = 'approved' AND consumed_at IS NULL
      AND (expires_at IS NULL OR expires_at > now())
      AND approved_by IS NOT NULL AND approved_by <> requested_by
    ORDER BY created_at
    FOR UPDATE SKIP LOCKED
    LIMIT 1)
  RETURNING id;
$$;
REVOKE ALL ON FUNCTION vv_consume_approval(text, text) FROM PUBLIC;
-- EXECUTE-Grant folgt in 0005 (nach Rollen-Existenz).
