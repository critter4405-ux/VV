-- VV Migration 0011 — Sicherheits-Retrofit des Stage-0-Kerns (M05-Reparaturrunde 1)
-- Grundlage: VV_M05_Repair-Auftrag_Sicherheitsbefunde.md (R1, R3, R4, R5, R8) — am Code bestätigt.
-- Betrifft Stage-0-Objekte (audit_log, approval, outbox) → Sicherheits-Retrofit (Register, Bezug P48/P49),
-- von der M05-Freigabe ausdrücklich mit abgedeckt. Idempotent + atomar.
--
--  R1 (B-02) Audit: vv_app/vv_worker verlieren direktes INSERT auf audit_log/audit_anchor. Die App schreibt
--            nur über vv_audit_log (Actor fest aus app.actor, kein Actor-Parameter, reservierte Präfixe
--            gesperrt, Größenlimit). Kein IDENTITY-Override, keine frei gesetzte Zeit/Actor mehr möglich.
--  R3 (H-02) Fremdmodell-Attestation: Stammt ein Vorschlag von einem Modell (builder_model weder human:*
--            noch system:*), ist bei 'approved' eine Attestation einer ANDEREN Modellfamilie Pflicht —
--            per CHECK, in vv_decide_approval und im Consume-Prädikat (Betreiber-Entscheidung 24.09.2026).
--  R4 (H-03) Freigeber-Recht DB-seitig: vv_decide_approval prüft deny-by-default das für den Effekt
--            nötige Recht (Rolle × Scope × Datenklasse); Effekt ohne Zuordnung -> niemand darf entscheiden.
--  R5 (H-06) Outbox-Claim nur für Topics mit registriertem Consumer; alle anderen Events bleiben geparkt
--            (unverändert, für künftige Konsumenten BASIS-07/M06) — kein Quittieren ohne Verarbeitung.
--  R8 (H-07) Lease-Fencing: Claim vergibt ein Lease-Token; done/fail/renew nur mit passendem Token
--            (ein Worker mit abgelaufenem Lease kann nichts mehr quittieren).

BEGIN;
SET LOCAL client_min_messages = warning;

-- =============================================================================================
-- R1 — Audit nur über geprüfte Funktionen
-- =============================================================================================
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON audit_log, audit_anchor FROM vv_app, vv_worker;

CREATE OR REPLACE FUNCTION vv_audit_log(p_action text, p_subject text DEFAULT NULL, p_payload jsonb DEFAULT '{}'::jsonb)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF vv_current_tenant() IS NULL OR vv_actor() IS NULL THEN
    RAISE EXCEPTION 'vv_audit_log: kein Mandanten-/Actor-Kontext (deny-by-default)' USING ERRCODE = '42501';
  END IF;
  -- Web darf nur eigene, nicht-reservierte Aktionen protokollieren (keine gefälschten Fach-Events).
  IF p_action IS NULL OR p_action !~ '^(app|policy)\.[a-z0-9_.]{1,60}$' THEN
    RAISE EXCEPTION 'vv_audit_log: Aktionsname % reserviert/ungültig', p_action USING ERRCODE = '42501';
  END IF;
  IF octet_length(coalesce(p_payload, '{}'::jsonb)::text) > 4096 OR octet_length(coalesce(p_subject, '')) > 200 THEN
    RAISE EXCEPTION 'vv_audit_log: Eintrag zu groß' USING ERRCODE = '22001';
  END IF;
  PERFORM vv_audit_write(p_action, p_subject, coalesce(p_payload, '{}'::jsonb));   -- Actor aus app.actor
END $$;
REVOKE ALL ON FUNCTION vv_audit_log(text, text, jsonb) FROM PUBLIC;
ALTER FUNCTION vv_audit_log(text, text, jsonb) OWNER TO vv_definer;
GRANT EXECUTE ON FUNCTION vv_audit_log(text, text, jsonb) TO vv_app, vv_definer;
REVOKE EXECUTE ON FUNCTION vv_audit_write(text, text, jsonb, text) FROM vv_app, vv_worker;

-- =============================================================================================
-- R3 — Fremdmodell-Attestation (Modellfamilien-Kanon, ADR-07)
-- =============================================================================================
CREATE OR REPLACE FUNCTION vv_model_family(p text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN p IS NULL OR btrim(p) = ''                               THEN NULL
    WHEN lower(p) ~ '^(human|system):'                              THEN split_part(lower(p), ':', 1)
    WHEN lower(p) ~ '(claude|anthropic|opus|sonnet|haiku)'          THEN 'anthropic'
    WHEN lower(p) ~ '(gpt|openai|codex|chatgpt)' OR lower(p) ~ '^o[0-9]' THEN 'openai'
    WHEN lower(p) ~ '(gemini|google|bard|palm)'                     THEN 'google'
    WHEN lower(p) ~ '(mistral|mixtral|codestral)'                   THEN 'mistral'
    WHEN lower(p) ~ '(llama|meta)'                                  THEN 'meta'
    ELSE nullif(regexp_replace(lower(p), '[^a-z].*$', ''), '')
  END
$$;

-- Menschliche/System-Anträge: die zweite PERSON ist das Vier-Augen-Element (keine Modell-Attestation).
-- Modell-Vorschlag (inkl. leerem/unbekanntem builder_model = deny-by-default): Reviewer einer
-- bekannten, ANDEREN Modellfamilie Pflicht.
CREATE OR REPLACE FUNCTION vv_attestation_ok(p_builder text, p_reviewer text) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN vv_model_family(p_builder) IN ('human', 'system') THEN true
    ELSE vv_model_family(p_reviewer) IS NOT NULL
         AND vv_model_family(p_reviewer) NOT IN ('human', 'system')
         AND vv_model_family(p_reviewer) IS DISTINCT FROM vv_model_family(p_builder)
  END
$$;
GRANT EXECUTE ON FUNCTION vv_model_family(text), vv_attestation_ok(text, text) TO vv_app, vv_worker, vv_definer;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'approval_attestation_ck') THEN
    ALTER TABLE approval ADD CONSTRAINT approval_attestation_ck
      CHECK (status <> 'approved' OR vv_attestation_ok(builder_model, reviewer_model));
  END IF;
END $$;

-- =============================================================================================
-- R4 — Freigeber-Recht je Effekt (deny-by-default)
-- =============================================================================================
CREATE TABLE IF NOT EXISTS approval_effect_permission (
    effect_id   text PRIMARY KEY,
    resource    text NOT NULL,
    action      text NOT NULL CHECK (action = 'approve'),
    data_class  text NOT NULL CHECK (data_class IN ('Oe','S','Se','F-Buch','F-Bank','A9')),
    scope_kind  text NOT NULL CHECK (scope_kind IN ('root','m05_period'))
);
INSERT INTO approval_effect_permission (effect_id, resource, action, data_class, scope_kind) VALUES
  ('m05.membership.terminate', 'membership', 'approve', 'S', 'm05_period'),
  ('m05.membership.anonymize', 'membership', 'approve', 'S', 'm05_period'),
  ('q05.import.commit',        'membership', 'approve', 'S', 'root')
ON CONFLICT (effect_id) DO NOTHING;
-- Stage-0-Platzhalter-Effekte (person.delete, payment.execute, …) haben bewusst KEINE Zuordnung:
-- solange ihr Modul nicht gebaut ist, darf sie niemand freigeben.
GRANT SELECT ON approval_effect_permission TO vv_app, vv_definer;

CREATE OR REPLACE FUNCTION vv_approval_scopes(p_scope_kind text, p_subject text) RETURNS uuid[]
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_person uuid;
BEGIN
  IF p_scope_kind = 'root' THEN
    RETURN ARRAY[vv_scope_root()];
  ELSIF p_scope_kind = 'm05_period' THEN
    IF p_subject !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN RETURN NULL; END IF;
    v_person := m05_period_person(p_subject::uuid);
    RETURN CASE WHEN v_person IS NULL THEN NULL ELSE vv_person_scopes(v_person) END;
  END IF;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION vv_approval_scopes(text, text) FROM PUBLIC;
ALTER FUNCTION vv_approval_scopes(text, text) OWNER TO vv_definer;
GRANT EXECUTE ON FUNCTION vv_approval_scopes(text, text) TO vv_definer;

-- Entscheidung: Actor aus app.actor, SoD, Freigeber-RECHT je Effekt (neu), Attestation bei Freigabe (neu).
CREATE OR REPLACE FUNCTION vv_decide_approval(p_id uuid, p_decision text, p_reviewer_model text DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_actor text; a approval; m approval_effect_permission; v_scopes uuid[];
BEGIN
  v_actor := nullif(current_setting('app.actor', true), '');
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'kein app.actor gesetzt — Freigeber-Identität unbekannt (deny-by-default)';
  END IF;
  IF p_decision NOT IN ('approved','rejected') THEN
    RAISE EXCEPTION 'ungültige Entscheidung: %', p_decision;
  END IF;
  SELECT * INTO a FROM approval
    WHERE id = p_id AND tenant_id = vv_current_tenant() AND status = 'pending'
    FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'keine offene Freigabe % im aktuellen Mandanten', p_id;
  END IF;
  IF v_actor = a.requested_by THEN
    RAISE EXCEPTION 'Antragsteller darf nicht selbst freigeben (SoD, K27)';
  END IF;
  -- R4: Recht des Freigebers für GENAU diesen Effekt im Scope des Gegenstands (deny-by-default).
  SELECT * INTO m FROM approval_effect_permission WHERE effect_id = a.effect_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Effekt % hat keine Freigeber-Zuordnung — niemand darf entscheiden (deny-by-default)', a.effect_id
      USING ERRCODE = '42501';
  END IF;
  v_scopes := vv_approval_scopes(m.scope_kind, a.subject_ref);
  IF v_scopes IS NULL OR NOT vv_authorize_subject(v_actor, m.resource, m.action, m.data_class, v_scopes) THEN
    RAISE EXCEPTION 'Freigeber % hat kein Recht %.% für diesen Gegenstand (deny-by-default)', v_actor, m.resource, m.action
      USING ERRCODE = '42501';
  END IF;
  -- R3: Modell-Vorschläge nur mit Fremdfamilien-Attestation freigebbar.
  IF p_decision = 'approved' AND NOT vv_attestation_ok(a.builder_model, coalesce(p_reviewer_model, a.reviewer_model)) THEN
    RAISE EXCEPTION 'Fremdmodell-Attestation fehlt/ungültig (Reviewer muss andere Modellfamilie sein als %)', a.builder_model
      USING ERRCODE = '42501';
  END IF;
  UPDATE approval SET
    status         = p_decision,
    approved_by    = CASE WHEN p_decision = 'approved' THEN v_actor ELSE approved_by END,
    reviewer_model = coalesce(p_reviewer_model, reviewer_model),
    decided_at     = now()
  WHERE id = p_id;
  RETURN p_id;
END $$;
REVOKE ALL ON FUNCTION vv_decide_approval(uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION vv_decide_approval(uuid, text, text) TO vv_app, vv_definer;

-- Consume zusätzlich an die Attestation gebunden (Defense-in-Depth zum CHECK).
CREATE OR REPLACE FUNCTION vv_consume_approval(p_effect_id text, p_subject_ref text)
RETURNS uuid LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp AS $$
  UPDATE approval SET consumed_at = now()
  WHERE id = (
    SELECT id FROM approval
    WHERE tenant_id = vv_current_tenant()
      AND effect_id = p_effect_id AND subject_ref = p_subject_ref
      AND status = 'approved' AND consumed_at IS NULL
      AND (expires_at IS NULL OR expires_at > now())
      AND approved_by IS NOT NULL AND approved_by <> requested_by
      AND vv_attestation_ok(builder_model, reviewer_model)
    ORDER BY created_at
    FOR UPDATE SKIP LOCKED
    LIMIT 1)
  RETURNING id;
$$;
REVOKE ALL ON FUNCTION vv_consume_approval(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION vv_consume_approval(text, text) TO vv_worker, vv_definer;
REVOKE EXECUTE ON FUNCTION vv_consume_approval(text, text) FROM vv_app;

-- =============================================================================================
-- R5 + R8 — Outbox: Claim nach Consumer-Topics, Lease-Fencing
-- =============================================================================================
ALTER TABLE outbox ADD COLUMN IF NOT EXISTS lease_token uuid;

DROP FUNCTION IF EXISTS vv_outbox_claim(int);
DROP FUNCTION IF EXISTS vv_outbox_done(uuid);
DROP FUNCTION IF EXISTS vv_outbox_fail(uuid, text, int);

-- Claim NUR für die Topics, die der aufrufende Worker tatsächlich konsumiert (p_topics Pflicht).
-- Alle anderen Events bleiben unberührt geparkt (attempts=0, kein DLQ) — nichts wird „weg-quittiert".
CREATE OR REPLACE FUNCTION vv_outbox_claim(max_rows int, p_topics text[])
RETURNS SETOF outbox LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF p_topics IS NULL OR cardinality(p_topics) = 0 THEN
    RETURN;                                           -- ohne Consumer-Liste nichts claimen (deny-by-default)
  END IF;
  -- Reaper (Hard-Crash-DLQ, H2/H3/P46) — nur für die eigenen Topics, SKIP LOCKED, abgelaufenes Lease.
  UPDATE outbox SET dead_at = now(), last_error = coalesce(last_error, 'max attempts (hard crash reaper)')
    WHERE id IN (
      SELECT id FROM outbox
      WHERE topic = ANY (p_topics)
        AND processed_at IS NULL AND dead_at IS NULL AND attempts >= 5
        AND (locked_until IS NULL OR locked_until < now())
      FOR UPDATE SKIP LOCKED
      LIMIT max_rows);
  -- Claim mit NEUEM Lease-Token (Fencing): ein älterer Lease-Inhaber kann danach nichts mehr quittieren.
  RETURN QUERY
    UPDATE outbox SET locked_until = now() + interval '1 minute', attempts = attempts + 1,
                      lease_token = gen_random_uuid()
    WHERE id IN (
      SELECT id FROM outbox
      WHERE topic = ANY (p_topics)
        AND processed_at IS NULL AND dead_at IS NULL AND attempts < 5
        AND (locked_until IS NULL OR locked_until < now())
      ORDER BY created_at
      FOR UPDATE SKIP LOCKED
      LIMIT max_rows)
    RETURNING *;
END $$;

-- Erfolg nur mit gültigem Lease-Token. P46 bleibt: Spät-Erfolg (derselbe Lease, inzwischen vom Reaper
-- tot markiert) räumt dead_at ab. Ein von einem anderen Worker neu geclaimter Eintrag (neues Token)
-- kann vom alten Worker NICHT quittiert werden. Rückgabe: true = quittiert.
CREATE OR REPLACE FUNCTION vv_outbox_done(p_id uuid, p_token uuid)
RETURNS boolean LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp AS $$
  WITH u AS (
    UPDATE outbox SET processed_at = now(), locked_until = NULL, dead_at = NULL
     WHERE id = p_id AND lease_token = p_token AND p_token IS NOT NULL AND processed_at IS NULL
    RETURNING 1)
  SELECT EXISTS (SELECT 1 FROM u);
$$;

CREATE OR REPLACE FUNCTION vv_outbox_fail(p_id uuid, p_token uuid, p_err text, p_max int DEFAULT 5)
RETURNS boolean LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp AS $$
  WITH u AS (
    UPDATE outbox SET
      last_error   = left(p_err, 2000),
      dead_at      = CASE WHEN attempts >= p_max THEN now() ELSE NULL END,
      locked_until = CASE WHEN attempts >= p_max THEN locked_until ELSE NULL END
     WHERE id = p_id AND lease_token = p_token AND p_token IS NOT NULL AND processed_at IS NULL
    RETURNING 1)
  SELECT EXISTS (SELECT 1 FROM u);
$$;

-- Lease verlängern (lange Handler) — nur der aktuelle Lease-Inhaber, max. 10 Minuten.
CREATE OR REPLACE FUNCTION vv_outbox_renew(p_id uuid, p_token uuid, p_seconds int DEFAULT 60)
RETURNS boolean LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp AS $$
  WITH u AS (
    UPDATE outbox SET locked_until = now() + make_interval(secs => least(greatest(p_seconds, 1), 600))
     WHERE id = p_id AND lease_token = p_token AND p_token IS NOT NULL
       AND processed_at IS NULL AND dead_at IS NULL AND locked_until > now()
    RETURNING 1)
  SELECT EXISTS (SELECT 1 FROM u);
$$;

REVOKE ALL ON FUNCTION vv_outbox_claim(int, text[]), vv_outbox_done(uuid, uuid),
                       vv_outbox_fail(uuid, uuid, text, int), vv_outbox_renew(uuid, uuid, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION vv_outbox_claim(int, text[]), vv_outbox_done(uuid, uuid),
                       vv_outbox_fail(uuid, uuid, text, int), vv_outbox_renew(uuid, uuid, int) TO vv_worker;

COMMIT;
