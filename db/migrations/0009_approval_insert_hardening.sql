-- VV Migration 0009 — Härtung Freigabe-Objekt beim INSERT (im M05-Bau entdeckter Stage-0-Befund)
--
-- BEFUND S0-1 (hoch): vv_app hat INSERT auf `approval` (0005). Die Stage-0-Reparatur H1 entzog nur
--   UPDATE — beim EINFÜGEN konnte die Web-Rolle aber status='approved', approved_by='<beliebig>',
--   decided_at, consumed_at, token und created_at frei setzen, also eine bereits „genehmigte"
--   Freigabe fälschen (Vier-Augen-Umgehung für jeden Effekt, der vv_consume_approval nutzt).
-- BEFUND S0-2 (mittel): requested_by war beim INSERT ein freier String -> Antragsteller-Spoofing
--   (A legt Antrag „im Namen von B" an und gibt ihn anschließend selbst frei: A ≠ B passiert die SoD).
--
-- FIX (DB-erzwungen, rollenunabhängig): BEFORE-INSERT-Trigger normalisiert JEDE neue Freigabe auf
--   den Anfangszustand (pending, kein Freigeber, nicht eingelöst, Server-Zeit, Server-Token).
--   Für die Web-Rolle gilt zusätzlich requested_by = app.actor (transaktionsgebundener OIDC-Actor).
--   Entscheidung bleibt ausschließlich vv_decide_approval, Einlösung vv_consume_approval.
-- Idempotent + atomar.

BEGIN;
SET LOCAL client_min_messages = warning;

CREATE OR REPLACE FUNCTION vv_approval_insert_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_actor text := nullif(current_setting('app.actor', true), '');
BEGIN
  NEW.status         := 'pending';
  NEW.approved_by    := NULL;
  NEW.reviewer_model := NULL;
  NEW.decided_at     := NULL;
  NEW.consumed_at    := NULL;
  NEW.created_at     := now();
  NEW.token          := gen_random_uuid();
  IF NEW.expires_at IS NULL OR NEW.expires_at > now() + interval '90 days' THEN
    NEW.expires_at := now() + interval '30 days';           -- Freigaben verfallen immer
  END IF;
  IF session_user = 'vv_app' OR current_user = 'vv_app' THEN
    IF v_actor IS NULL OR NEW.requested_by IS DISTINCT FROM v_actor THEN
      RAISE EXCEPTION 'approval: requested_by muss dem verifizierten app.actor entsprechen (Antragsteller-Spoofing verweigert)'
        USING ERRCODE = '42501';
    END IF;
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION vv_approval_insert_guard() FROM PUBLIC;

DROP TRIGGER IF EXISTS approval_insert_guard ON approval;
CREATE TRIGGER approval_insert_guard BEFORE INSERT ON approval
  FOR EACH ROW EXECUTE FUNCTION vv_approval_insert_guard();

-- Freigaben werden nie gelöscht (Nachweis, BASIS-03).
CREATE OR REPLACE FUNCTION vv_approval_no_delete() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'approval ist nicht löschbar (Nachweis, Operation %)', TG_OP;
END $$;
REVOKE ALL ON FUNCTION vv_approval_no_delete() FROM PUBLIC;
DROP TRIGGER IF EXISTS approval_no_delete ON approval;
CREATE TRIGGER approval_no_delete BEFORE DELETE ON approval
  FOR EACH ROW EXECUTE FUNCTION vv_approval_no_delete();
DROP TRIGGER IF EXISTS approval_no_truncate ON approval;
CREATE TRIGGER approval_no_truncate BEFORE TRUNCATE ON approval
  FOR EACH STATEMENT EXECUTE FUNCTION vv_approval_no_delete();

COMMIT;
