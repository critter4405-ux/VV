-- VV Migration 0013 — C-1 „Kontext-Signatur“ (Ticket-Dienst), Register P54/P58, Bau-Auftrag v1.0
--
-- PROBLEM (Codex C-1, P54): vv_current_tenant()/vv_actor() lasen frei setzbare Custom-GUCs
--   (app.tenant_id/app.actor). Wer die DB-Zugangsdaten der Web-App besaß, konnte jeden Mandanten
--   lesen und in EINER Verbindung Antragsteller und Freigeber spielen.
--
-- LÖSUNG (Schutzziel B, Grill P58):
--   * Die DB nimmt Mandant + Nutzer NUR noch über ein HMAC-signiertes Kurzzeit-Ticket an
--     (vv_set_context). Den Schlüssel kennen nur Ticket-Dienst und DB (Tabelle ticket_key, lesbar
--     ausschließlich für die NOLOGIN-Rolle vv_ticketcheck, der die Prüffunktion gehört).
--   * Der geprüfte Kontext liegt in vv_ctx (Schlüssel: Backend-PID + Transaktions-ID), schreibbar nur
--     durch die Prüffunktionen. Kein frei beschreibbarer Parameter, keine GUC mehr.
--   * Einmal-Tickets: verbindliche Aktionen verbrauchen die Ticket-Kennung (ticket_used, atomar).
--   * vv_app verliert ALLE direkten Tabellenrechte; Web-Zugriffe nur über geprüfte DB-Funktionen.
--   * vv_worker: feste Positivliste von Systemfunktionen, fester Akteur 'system:worker', keine Tickets.
--   * Positivlisten für EXECUTE (vv_app / vv_worker) statt PUBLIC-Default; TEMP für PUBLIC entzogen
--     (kein von der App anlegbares gleichnamiges Objekt).
--
-- Idempotent (mehrfach ausführbar) + atomar.

BEGIN;
SET LOCAL client_min_messages = warning;

-- =============================================================================================
-- 1) Rolle der Prüffunktion (besitzt Schlüssel-/Kontext-Tabellen-Zugriff, sonst nichts)
-- =============================================================================================
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'vv_ticketcheck') THEN
    CREATE ROLE vv_ticketcheck NOLOGIN NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE NOREPLICATION;
  ELSE
    ALTER ROLE vv_ticketcheck NOLOGIN NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE NOREPLICATION;
  END IF;
END $$;
GRANT USAGE ON SCHEMA public TO vv_ticketcheck;

-- =============================================================================================
-- 2) Tabellen
-- =============================================================================================
-- HMAC-Schlüssel (Wechsel: zwei gleichzeitig aktiv; deaktiviert = Geheimnis gelöscht).
CREATE TABLE IF NOT EXISTS ticket_key (
    kid          text PRIMARY KEY CHECK (kid ~ '^[a-z0-9]{1,16}$'),
    secret       bytea,
    status       text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'disabled')),
    created_at   timestamptz NOT NULL DEFAULT now(),
    valid_until  timestamptz,                         -- Ende der Übergangszeit (danach verweigert)
    disabled_at  timestamptz,
    CONSTRAINT ticket_key_secret_ck CHECK (
      (status = 'active'   AND secret IS NOT NULL AND octet_length(secret) BETWEEN 32 AND 64)
   OR (status = 'disabled' AND secret IS NULL AND disabled_at IS NOT NULL))
);

-- Verbrauchte Einmal-Tickets (verbindliche Aktionen). Aufräumen nach Ablauf (Tagesjob).
CREATE TABLE IF NOT EXISTS ticket_used (
    jti      uuid PRIMARY KEY,
    exp_at   timestamptz NOT NULL,
    action   text NOT NULL CHECK (action ~ '^[a-z0-9_.]{1,60}$'),
    used_at  timestamptz NOT NULL DEFAULT now()
);

-- Geprüfter Kontext je Backend + Transaktion. UNLOGGED: flüchtig (nach Absturz leer = fail-closed).
-- Spalte heißt bewusst `tenant` (kein Fach-Datensatz, kein RLS-Mandantenbezug; Zugriff nur vv_ticketcheck).
CREATE TABLE IF NOT EXISTS vv_ctx (
    pid      integer PRIMARY KEY,
    xid      xid8 NOT NULL,
    kind     text NOT NULL CHECK (kind IN ('ticket', 'system', 'bootstrap')),
    tenant   uuid NOT NULL,
    actor    text NOT NULL CHECK (length(actor) BETWEEN 1 AND 255),
    jti      uuid,
    exp_at   timestamptz,
    set_at   timestamptz NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT vv_ctx_kind_ck CHECK (
      (kind = 'ticket'    AND jti IS NOT NULL AND exp_at IS NOT NULL AND actor !~ '^system:')
   OR (kind = 'system'    AND jti IS NULL AND actor = 'system:worker')
   OR (kind = 'bootstrap' AND jti IS NULL))
);
ALTER TABLE vv_ctx SET UNLOGGED;

REVOKE ALL ON ticket_key, ticket_used, vv_ctx FROM PUBLIC, vv_app, vv_worker, vv_definer;
GRANT SELECT ON ticket_key TO vv_ticketcheck;                                  -- nur die Prüffunktion
GRANT SELECT, INSERT, DELETE ON ticket_used TO vv_ticketcheck;
GRANT SELECT, INSERT, UPDATE, DELETE ON vv_ctx TO vv_ticketcheck;
GRANT SELECT (id) ON tenant TO vv_ticketcheck;

-- =============================================================================================
-- 3) Hilfsfunktion Base64url (RFC 4648 §5, ohne Padding)
-- =============================================================================================
CREATE OR REPLACE FUNCTION vv_b64url_decode(p text) RETURNS bytea
LANGUAGE sql IMMUTABLE STRICT
BEGIN ATOMIC
  SELECT pg_catalog.decode(pg_catalog.translate(p, '-_', '+/')
         || pg_catalog.repeat('=', (4 - pg_catalog.length(p) % 4) % 4), 'base64');
END;

-- =============================================================================================
-- 4) Kontext lesen — NUR geprüfter Zustand (SQL-Standard-Body: Namen/Operatoren beim Anlegen
--    gebunden -> kein search_path-/Objekt-Schatten durch den Aufrufer möglich)
-- =============================================================================================
CREATE OR REPLACE FUNCTION vv_current_tenant() RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER
BEGIN ATOMIC
  SELECT c.tenant FROM public.vv_ctx c
   WHERE c.pid = pg_catalog.pg_backend_pid()
     AND c.xid = pg_catalog.pg_current_xact_id_if_assigned()
     AND (c.exp_at IS NULL OR c.exp_at >= pg_catalog.statement_timestamp());
END;

CREATE OR REPLACE FUNCTION vv_actor() RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER
BEGIN ATOMIC
  SELECT c.actor FROM public.vv_ctx c
   WHERE c.pid = pg_catalog.pg_backend_pid()
     AND c.xid = pg_catalog.pg_current_xact_id_if_assigned()
     AND (c.exp_at IS NULL OR c.exp_at >= pg_catalog.statement_timestamp());
END;

CREATE OR REPLACE FUNCTION vv_ctx_kind() RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER
BEGIN ATOMIC
  SELECT c.kind FROM public.vv_ctx c
   WHERE c.pid = pg_catalog.pg_backend_pid()
     AND c.xid = pg_catalog.pg_current_xact_id_if_assigned()
     AND (c.exp_at IS NULL OR c.exp_at >= pg_catalog.statement_timestamp());
END;

-- =============================================================================================
-- 5) Kontext setzen
-- =============================================================================================
-- (a) Web-App: nur mit gültigem Ticket  v1.<kid>.<payload_b64url>.<hmac_sha256_b64url>
--     Nutzlast (JSON, genau diese Schlüssel): t = Mandant (uuid), s = Akteur (OIDC-sub),
--     iat/exp = Unix-Sekunden (exp - iat ≤ 60), jti = Ticket-Kennung (uuid). Kein Klartext-Personenbezug.
CREATE OR REPLACE FUNCTION vv_set_context(p_ticket text) RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE
  parts text[]; v_kid text; v_key bytea; v_sig bytea; v_calc bytea; v_nonce bytea;
  v_payload jsonb; v_keys text[]; v_t uuid; v_s text; v_iat bigint; v_exp bigint; v_jti uuid;
  v_now numeric := extract(epoch FROM clock_timestamp());
BEGIN
  IF session_user = 'vv_worker' THEN
    RAISE EXCEPTION 'Ticket verweigert: Worker handelt nie mit Nutzer-Tickets' USING ERRCODE = '28000';
  END IF;
  IF p_ticket IS NULL OR length(p_ticket) > 1024 THEN
    RAISE EXCEPTION 'Ticket verweigert: Format' USING ERRCODE = '28000';
  END IF;
  parts := string_to_array(p_ticket, '.');
  IF array_length(parts, 1) IS DISTINCT FROM 4 OR parts[1] <> 'v1'
     OR parts[2] !~ '^[a-z0-9]{1,16}$' OR parts[3] !~ '^[A-Za-z0-9_-]+$' OR length(parts[3]) NOT BETWEEN 16 AND 700
     OR parts[4] !~ '^[A-Za-z0-9_-]{43}$' THEN
    RAISE EXCEPTION 'Ticket verweigert: Format' USING ERRCODE = '28000';
  END IF;
  v_kid := parts[2];
  SELECT k.secret INTO v_key FROM public.ticket_key k
   WHERE k.kid = v_kid AND k.status = 'active' AND (k.valid_until IS NULL OR k.valid_until > clock_timestamp());
  IF v_key IS NULL THEN
    RAISE EXCEPTION 'Ticket verweigert: unbekannte oder deaktivierte Schlüssel-Kennung' USING ERRCODE = '28000';
  END IF;
  -- Signatur: HMAC-SHA256 über 'v1.<kid>.<payload_b64url>'. Vergleich über einen zweiten HMAC mit
  -- Zufallsschlüssel (Double-HMAC) -> kein verwertbarer Zeitunterschied beim Vergleich.
  v_sig   := vv_b64url_decode(parts[4]);
  v_calc  := public.hmac(convert_to('v1.' || v_kid || '.' || parts[3], 'UTF8'), v_key, 'sha256');
  v_nonce := public.gen_random_bytes(32);
  IF public.hmac(v_calc, v_nonce, 'sha256') <> public.hmac(v_sig, v_nonce, 'sha256') THEN
    RAISE EXCEPTION 'Ticket verweigert: Signatur ungültig' USING ERRCODE = '28000';
  END IF;
  -- Nutzlast erst NACH gültiger Signatur auswerten.
  BEGIN
    v_payload := convert_from(vv_b64url_decode(parts[3]), 'UTF8')::jsonb;
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'Ticket verweigert: Nutzlast' USING ERRCODE = '28000';
  END;
  IF jsonb_typeof(v_payload) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'Ticket verweigert: Nutzlast' USING ERRCODE = '28000';
  END IF;
  SELECT array_agg(k ORDER BY k) INTO v_keys FROM jsonb_object_keys(v_payload) k;
  IF v_keys IS DISTINCT FROM ARRAY['exp', 'iat', 'jti', 's', 't']
     OR jsonb_typeof(v_payload->'t') <> 'string' OR jsonb_typeof(v_payload->'s') <> 'string'
     OR jsonb_typeof(v_payload->'jti') <> 'string'
     OR jsonb_typeof(v_payload->'iat') <> 'number' OR jsonb_typeof(v_payload->'exp') <> 'number'
     OR (v_payload->>'iat') !~ '^[0-9]{1,12}$' OR (v_payload->>'exp') !~ '^[0-9]{1,12}$'
     OR NOT pg_input_is_valid(v_payload->>'t', 'uuid') OR NOT pg_input_is_valid(v_payload->>'jti', 'uuid') THEN
    RAISE EXCEPTION 'Ticket verweigert: Nutzlast' USING ERRCODE = '28000';
  END IF;
  v_t := (v_payload->>'t')::uuid;  v_s := v_payload->>'s';  v_jti := (v_payload->>'jti')::uuid;
  v_iat := (v_payload->>'iat')::bigint;  v_exp := (v_payload->>'exp')::bigint;
  IF length(v_s) NOT BETWEEN 1 AND 255 OR v_s ~ '^system:' OR v_s ~ '[[:cntrl:]]' THEN
    RAISE EXCEPTION 'Ticket verweigert: Akteur' USING ERRCODE = '28000';
  END IF;
  IF v_exp - v_iat NOT BETWEEN 1 AND 60 OR v_iat > v_now + 5 THEN
    RAISE EXCEPTION 'Ticket verweigert: Gültigkeitsfenster' USING ERRCODE = '28000';
  END IF;
  IF v_exp <= v_now THEN
    RAISE EXCEPTION 'Ticket verweigert: abgelaufen' USING ERRCODE = '28000';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.tenant WHERE id = v_t) THEN
    RAISE EXCEPTION 'Ticket verweigert: Mandant unbekannt' USING ERRCODE = '28000';
  END IF;
  IF EXISTS (SELECT 1 FROM public.ticket_used u WHERE u.jti = v_jti) THEN
    RAISE EXCEPTION 'Ticket verweigert: Einmal-Ticket bereits verbraucht' USING ERRCODE = '28000';
  END IF;
  -- Genau EIN Kontext je Transaktion (kein Identitätswechsel mitten in der Transaktion).
  IF EXISTS (SELECT 1 FROM public.vv_ctx c WHERE c.pid = pg_backend_pid()
              AND c.xid = pg_current_xact_id_if_assigned()) THEN
    RAISE EXCEPTION 'Ticket verweigert: Kontext in dieser Transaktion bereits gesetzt' USING ERRCODE = '28000';
  END IF;
  INSERT INTO public.vv_ctx AS c (pid, xid, kind, tenant, actor, jti, exp_at, set_at)
  VALUES (pg_backend_pid(), pg_current_xact_id(), 'ticket', v_t, v_s, v_jti, to_timestamp(v_exp), clock_timestamp())
  ON CONFLICT (pid) DO UPDATE SET xid = EXCLUDED.xid, kind = EXCLUDED.kind, tenant = EXCLUDED.tenant,
    actor = EXCLUDED.actor, jti = EXCLUDED.jti, exp_at = EXCLUDED.exp_at, set_at = EXCLUDED.set_at;
  RETURN jsonb_build_object('tenant', v_t, 'actor', v_s, 'exp', to_timestamp(v_exp));
END $$;

-- (b) Worker: fester Systemakteur, kein Ticket, nur Rolle vv_worker.
CREATE OR REPLACE FUNCTION vv_worker_context(p_tenant uuid) RETURNS void
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
BEGIN
  IF session_user <> 'vv_worker' THEN
    RAISE EXCEPTION 'Systemkontext nur für die Worker-Rolle' USING ERRCODE = '42501';
  END IF;
  IF p_tenant IS NULL OR NOT EXISTS (SELECT 1 FROM public.tenant WHERE id = p_tenant) THEN
    RAISE EXCEPTION 'Systemkontext: Mandant unbekannt' USING ERRCODE = '42501';
  END IF;
  IF EXISTS (SELECT 1 FROM public.vv_ctx c WHERE c.pid = pg_backend_pid()
              AND c.xid = pg_current_xact_id_if_assigned()) THEN
    RAISE EXCEPTION 'Systemkontext in dieser Transaktion bereits gesetzt' USING ERRCODE = '42501';
  END IF;
  INSERT INTO public.vv_ctx AS c (pid, xid, kind, tenant, actor, jti, exp_at, set_at)
  VALUES (pg_backend_pid(), pg_current_xact_id(), 'system', p_tenant, 'system:worker', NULL, NULL, clock_timestamp())
  ON CONFLICT (pid) DO UPDATE SET xid = EXCLUDED.xid, kind = EXCLUDED.kind, tenant = EXCLUDED.tenant,
    actor = EXCLUDED.actor, jti = NULL, exp_at = NULL, set_at = EXCLUDED.set_at;
END $$;

-- Mandantenliste für die Systemjobs (statt direktem Tabellenrecht).
CREATE OR REPLACE FUNCTION vv_worker_tenants() RETURNS SETOF uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
  SELECT id FROM public.tenant ORDER BY id
$$;

-- (c) Bootstrap/Onboarding/Tests: nur Superuser-Sitzung (Betreiber). Darf den Mandanten innerhalb
--     einer Transaktion wechseln (Seeds). Kein SECURITY DEFINER, keine Grants.
CREATE OR REPLACE FUNCTION vv_bootstrap_context(p_tenant uuid, p_actor text DEFAULT 'system:bootstrap')
RETURNS void LANGUAGE plpgsql VOLATILE SET search_path = pg_catalog, public, pg_temp AS $$
BEGIN
  IF NOT coalesce((SELECT rolsuper FROM pg_roles WHERE rolname = session_user), false) THEN
    RAISE EXCEPTION 'Bootstrap-Kontext nur für den Betreiber (Superuser)' USING ERRCODE = '42501';
  END IF;
  INSERT INTO public.vv_ctx AS c (pid, xid, kind, tenant, actor, jti, exp_at, set_at)
  VALUES (pg_backend_pid(), pg_current_xact_id(), 'bootstrap', p_tenant, coalesce(p_actor, 'system:bootstrap'),
          NULL, NULL, clock_timestamp())
  ON CONFLICT (pid) DO UPDATE SET xid = EXCLUDED.xid, kind = EXCLUDED.kind, tenant = EXCLUDED.tenant,
    actor = EXCLUDED.actor, jti = NULL, exp_at = NULL, set_at = EXCLUDED.set_at;
END $$;

-- =============================================================================================
-- 6) Einmal-Ticket für verbindliche Aktionen (atomar, parallel-fest über den Primärschlüssel)
-- =============================================================================================
CREATE OR REPLACE FUNCTION vv_ticket_once(p_action text) RETURNS void
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE c public.vv_ctx;
BEGIN
  SELECT * INTO c FROM public.vv_ctx x
   WHERE x.pid = pg_backend_pid() AND x.xid = pg_current_xact_id_if_assigned()
     AND (x.exp_at IS NULL OR x.exp_at >= statement_timestamp());
  IF NOT FOUND THEN
    RAISE EXCEPTION 'deny-by-default: verbindliche Aktion ohne geprüften Kontext' USING ERRCODE = '42501';
  END IF;
  IF c.kind = 'bootstrap' THEN RETURN; END IF;                -- Betreiber-Onboarding/Tests (Superuser)
  IF c.kind <> 'ticket' THEN
    RAISE EXCEPTION 'deny-by-default: verbindliche Aktion nur mit Nutzer-Ticket' USING ERRCODE = '42501';
  END IF;
  INSERT INTO public.ticket_used (jti, exp_at, action) VALUES (c.jti, c.exp_at, p_action)
  ON CONFLICT (jti) DO NOTHING;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'deny-by-default: Einmal-Ticket bereits für eine verbindliche Aktion verbraucht' USING ERRCODE = '42501';
  END IF;
END $$;

-- Aufräumen (Tagesjob des Workers): abgelaufene Einmal-Kennungen (Sicherheitsabstand > Uhrversatz)
-- und Kontexte beendeter Backends.
CREATE OR REPLACE FUNCTION vv_ticket_housekeeping() RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE n_used int; n_ctx int;
BEGIN
  DELETE FROM public.ticket_used WHERE exp_at < now() - interval '10 minutes';
  GET DIAGNOSTICS n_used = ROW_COUNT;
  DELETE FROM public.vv_ctx c WHERE NOT EXISTS (SELECT 1 FROM pg_stat_activity a WHERE a.pid = c.pid);
  GET DIAGNOSTICS n_ctx = ROW_COUNT;
  RETURN jsonb_build_object('ticket_used_deleted', n_used, 'ctx_deleted', n_ctx);
END $$;

-- =============================================================================================
-- 7) Schlüsselverwaltung (nur Betreiber/Superuser, per scripts/rotate_ticket_key.sh) + Audit
-- =============================================================================================
-- Jeder Schritt wird in die Audit-Kette JEDES Mandanten geschrieben (nur Kennung/Ereignis, nie das Geheimnis).
CREATE OR REPLACE FUNCTION vv_ticket_key_event(p_kid text, p_event text, p_detail jsonb DEFAULT '{}'::jsonb)
RETURNS integer LANGUAGE plpgsql VOLATILE SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE n int;
BEGIN
  IF NOT coalesce((SELECT rolsuper FROM pg_roles WHERE rolname = session_user), false) THEN
    RAISE EXCEPTION 'Schlüsselverwaltung nur für den Betreiber' USING ERRCODE = '42501';
  END IF;
  IF p_event !~ '^[a-z_]{3,30}$' THEN RAISE EXCEPTION 'ungültiges Ereignis %', p_event; END IF;
  INSERT INTO public.audit_log (tenant_id, actor, action, subject_ref, payload)
  SELECT t.id, 'system:operator', 'platform.ticket_key.' || p_event, 'ticket_key:' || p_kid,
         jsonb_build_object('kid', p_kid, 'event', p_event) || coalesce(p_detail, '{}'::jsonb)
    FROM public.tenant t ORDER BY t.id;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;

CREATE OR REPLACE FUNCTION vv_ticket_key_add(p_kid text, p_secret bytea) RETURNS void
LANGUAGE plpgsql VOLATILE SET search_path = pg_catalog, public, pg_temp AS $$
BEGIN
  IF NOT coalesce((SELECT rolsuper FROM pg_roles WHERE rolname = session_user), false) THEN
    RAISE EXCEPTION 'Schlüsselverwaltung nur für den Betreiber' USING ERRCODE = '42501';
  END IF;
  INSERT INTO public.ticket_key (kid, secret, status) VALUES (p_kid, p_secret, 'active');
  PERFORM vv_ticket_key_event(p_kid, 'added', jsonb_build_object('bytes', octet_length(p_secret)));
END $$;

-- Übergangszeit: alter Schlüssel gilt bis p_until (danach von vv_set_context verweigert).
CREATE OR REPLACE FUNCTION vv_ticket_key_expire(p_kid text, p_until timestamptz) RETURNS void
LANGUAGE plpgsql VOLATILE SET search_path = pg_catalog, public, pg_temp AS $$
BEGIN
  IF NOT coalesce((SELECT rolsuper FROM pg_roles WHERE rolname = session_user), false) THEN
    RAISE EXCEPTION 'Schlüsselverwaltung nur für den Betreiber' USING ERRCODE = '42501';
  END IF;
  UPDATE public.ticket_key SET valid_until = p_until WHERE kid = p_kid AND status = 'active';
  IF NOT FOUND THEN RAISE EXCEPTION 'kein aktiver Schlüssel %', p_kid; END IF;
  PERFORM vv_ticket_key_event(p_kid, 'transition', jsonb_build_object('valid_until', p_until));
END $$;

-- Deaktivieren: Status disabled, Geheimnis gelöscht (Krypto-Hygiene), protokolliert.
CREATE OR REPLACE FUNCTION vv_ticket_key_disable(p_kid text) RETURNS void
LANGUAGE plpgsql VOLATILE SET search_path = pg_catalog, public, pg_temp AS $$
BEGIN
  IF NOT coalesce((SELECT rolsuper FROM pg_roles WHERE rolname = session_user), false) THEN
    RAISE EXCEPTION 'Schlüsselverwaltung nur für den Betreiber' USING ERRCODE = '42501';
  END IF;
  UPDATE public.ticket_key SET status = 'disabled', secret = NULL, disabled_at = now() WHERE kid = p_kid AND status = 'active';
  IF NOT FOUND THEN RAISE EXCEPTION 'kein aktiver Schlüssel %', p_kid; END IF;
  PERFORM vv_ticket_key_event(p_kid, 'disabled', '{}'::jsonb);
END $$;

-- =============================================================================================
-- 8) Bestehende Funktionen auf den geprüften Kontext umstellen (keine GUC app.* mehr)
-- =============================================================================================
-- 0009: Freigabe-INSERT-Normalisierung — Antragsteller aus geprüftem Kontext.
CREATE OR REPLACE FUNCTION vv_approval_insert_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_actor text := vv_actor();
BEGIN
  NEW.status         := 'pending';
  NEW.approved_by    := NULL;
  NEW.reviewer_model := NULL;
  NEW.decided_at     := NULL;
  NEW.consumed_at    := NULL;
  NEW.created_at     := now();
  NEW.token          := gen_random_uuid();
  IF NEW.expires_at IS NULL OR NEW.expires_at > now() + interval '90 days' THEN
    NEW.expires_at := now() + interval '30 days';
  END IF;
  IF session_user = 'vv_app' OR current_user = 'vv_app' THEN
    IF v_actor IS NULL OR NEW.requested_by IS DISTINCT FROM v_actor THEN
      RAISE EXCEPTION 'approval: requested_by muss dem geprüften Akteur entsprechen (Antragsteller-Spoofing verweigert)'
        USING ERRCODE = '42501';
    END IF;
  END IF;
  RETURN NEW;
END $$;

-- 0011: Entscheidung — Freigeber = geprüfter Akteur (Ticket), nicht mehr GUC app.actor.
CREATE OR REPLACE FUNCTION vv_decide_approval(p_id uuid, p_decision text, p_reviewer_model text DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_actor text; a approval; m approval_effect_permission; v_scopes uuid[];
BEGIN
  v_actor := vv_actor();
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'kein geprüfter Akteur — Freigeber-Identität unbekannt (deny-by-default)' USING ERRCODE = '42501';
  END IF;
  IF v_actor LIKE 'system:%' THEN
    RAISE EXCEPTION 'Systemakteure entscheiden keine Freigaben (deny-by-default)' USING ERRCODE = '42501';
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

-- 0006: SoD-Trigger — ohne passenden geprüften Kontext NICHT still durchlassen (vorher: fehlender
-- Kontext => vv_sod_conflict sah keine Zuweisungen => kein Konflikt = fail-open für Direkt-Inserts).
CREATE OR REPLACE FUNCTION vv_role_assignment_guard() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_conflict text;
BEGIN
  IF vv_current_tenant() IS DISTINCT FROM NEW.tenant_id THEN
    RAISE EXCEPTION 'role_assignment: kein passender geprüfter Mandantenkontext (fail-closed)' USING ERRCODE = '42501';
  END IF;
  IF TG_OP = 'UPDATE' THEN
    IF NEW.person_id <> OLD.person_id OR NEW.role_type <> OLD.role_type
       OR NEW.scope_node_id IS DISTINCT FROM OLD.scope_node_id OR NEW.valid_from <> OLD.valid_from
       OR NEW.tenant_id <> OLD.tenant_id THEN
      RAISE EXCEPTION 'role_assignment: nur Widerruf/Befristung änderbar (keine Umdeutung)';
    END IF;
    IF NEW.revoked_at IS NOT NULL THEN RETURN NEW; END IF;
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(NEW.tenant_id::text || '/' || NEW.person_id::text, 7));
  v_conflict := vv_sod_conflict(NEW.person_id, NEW.role_type, NEW.valid_from, NEW.valid_to, NEW.id);
  IF v_conflict IS NOT NULL THEN
    RAISE EXCEPTION 'SoD-Kern verletzt: % ist mit % unvereinbar (B02-1, kein Override)', NEW.role_type, v_conflict
      USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END $$;

-- 0006: Onboarding-Pfade (nur Betreiber) — Bootstrap-Kontext statt GUC.
CREATE OR REPLACE FUNCTION rbac_onboard_root(p_tenant uuid, p_name text) RETURNS uuid
LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
DECLARE v_id uuid;
BEGIN
  PERFORM vv_bootstrap_context(p_tenant, 'system:onboarding');
  SELECT id INTO v_id FROM scope_node WHERE tenant_id = p_tenant AND parent_id IS NULL;
  IF v_id IS NULL THEN
    INSERT INTO scope_node (tenant_id, parent_id, kind, name) VALUES (p_tenant, NULL, 'verein', p_name)
    RETURNING id INTO v_id;
  END IF;
  RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION rbac_link_principal(p_tenant uuid, p_subject text, p_person uuid) RETURNS void
LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
BEGIN
  PERFORM vv_bootstrap_context(p_tenant, 'system:onboarding');
  INSERT INTO principal_link (tenant_id, subject, person_id) VALUES (p_tenant, p_subject, p_person)
  ON CONFLICT (tenant_id, subject) DO NOTHING;
  INSERT INTO audit_log (tenant_id, actor, action, subject_ref, payload)
  VALUES (p_tenant, 'system:onboarding', 'rbac.principal.link', p_person::text, jsonb_build_object('subject_ref', md5(p_subject)));
END $$;

-- =============================================================================================
-- 9) Stage-0-Demo-Lesepfade (person / role_assignment) nur noch über geprüfte Funktionen
-- =============================================================================================
CREATE OR REPLACE FUNCTION basis01_list_persons()
RETURNS TABLE (id uuid, last_name text, first_name text, status text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE n int;
BEGIN
  IF NOT vv_authorize('person', 'read', 'S') THEN
    RAISE EXCEPTION 'deny-by-default: keine Berechtigung person.read' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY SELECT p.id, p.last_name, p.first_name, p.status FROM person p
                WHERE p.tenant_id = vv_current_tenant() ORDER BY p.last_name, p.first_name;
  GET DIAGNOSTICS n = ROW_COUNT;
  PERFORM vv_audit_write('basis01.person.list', NULL, jsonb_build_object('rows', n));
END $$;

CREATE OR REPLACE FUNCTION basis02_list_role_assignments()
RETURNS TABLE (id uuid, person_id uuid, role_type text, scope_node_id uuid, valid_to timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE n int;
BEGIN
  IF NOT vv_authorize('role_assignment', 'read', 'Oe') THEN
    RAISE EXCEPTION 'deny-by-default: keine Berechtigung role_assignment.read' USING ERRCODE = '42501';
  END IF;
  RETURN QUERY SELECT r.id, r.person_id, r.role_type, r.scope_node_id, r.valid_to FROM role_assignment r
                WHERE r.tenant_id = vv_current_tenant() AND r.revoked_at IS NULL ORDER BY r.created_at;
  GET DIAGNOSTICS n = ROW_COUNT;
  PERFORM vv_audit_write('basis02.role.list', NULL, jsonb_build_object('rows', n));
END $$;

-- =============================================================================================
-- 10) Verbindliche Aktionen: Einmal-Ticket VOR dem fachlichen Kern (Kern umbenannt, nur Definer)
-- =============================================================================================
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT * FROM (VALUES
      ('m05_decide',              'uuid, text'),
      ('m05_import_decide',       'text, text'),
      ('m05_request_termination', 'uuid, text, date, text, text, text, date, integer'),
      ('m05_import_request',      'text, text, integer'),
      ('m05_export_members',      'text, boolean'),
      ('m05_list_members',        'boolean, text'),
      ('rbac_assign_role',        'uuid, text, uuid, timestamptz, timestamptz'),
      ('rbac_revoke_role',        'uuid')) AS v(fn, args)
  LOOP
    IF to_regprocedure(format('%s__kern(%s)', r.fn, r.args)) IS NULL THEN
      EXECUTE format('ALTER FUNCTION %s(%s) RENAME TO %s__kern', r.fn, r.args, r.fn);
    END IF;
  END LOOP;
END $$;

CREATE OR REPLACE FUNCTION m05_decide(p_approval uuid, p_decision text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  PERFORM vv_ticket_once('m05.decide');
  RETURN m05_decide__kern(p_approval, p_decision);
END $$;

CREATE OR REPLACE FUNCTION m05_import_decide(p_batch_ref text, p_decision text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  PERFORM vv_ticket_once('m05.import.decide');
  RETURN m05_import_decide__kern(p_batch_ref, p_decision);
END $$;

CREATE OR REPLACE FUNCTION m05_request_termination(p_period uuid, p_end_kind text, p_notice_received_on date,
    p_reason_code text, p_exclusion_code text, p_resolution_ref text, p_effective_date date, p_expected_version integer)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  PERFORM vv_ticket_once('m05.request_termination');
  RETURN m05_request_termination__kern(p_period, p_end_kind, p_notice_received_on, p_reason_code,
                                       p_exclusion_code, p_resolution_ref, p_effective_date, p_expected_version);
END $$;

CREATE OR REPLACE FUNCTION m05_import_request(p_batch_ref text, p_rows_sha256 text, p_row_count integer)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  PERFORM vv_ticket_once('m05.import.request');
  RETURN m05_import_request__kern(p_batch_ref, p_rows_sha256, p_row_count);
END $$;

CREATE OR REPLACE FUNCTION m05_export_members(p_purpose text, p_include_locked boolean DEFAULT false)
RETURNS TABLE (member_id uuid, period_id uuid, person_id uuid, last_name text, first_name text,
               type_code text, type_name text, category text, member_no text, status text,
               entry_date date, exit_effective_date date, end_kind text, end_reason_code text,
               exclusion_reason_code text, resolution_ref text, period_version integer, visible_classes text[])
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  PERFORM vv_ticket_once('m05.export');
  RETURN QUERY SELECT * FROM m05_export_members__kern(p_purpose, p_include_locked);
END $$;

-- Lesen bleibt mehrfach möglich; nur der Zugriff auf GESPERRTE Daten (Art. 18, mit Zweck) ist einmalig.
CREATE OR REPLACE FUNCTION m05_list_members(p_include_locked boolean DEFAULT false, p_purpose text DEFAULT NULL)
RETURNS TABLE (member_id uuid, period_id uuid, person_id uuid, last_name text, first_name text,
               type_code text, type_name text, category text, member_no text, status text,
               entry_date date, exit_effective_date date, end_kind text, end_reason_code text,
               exclusion_reason_code text, resolution_ref text, period_version integer, visible_classes text[])
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF p_include_locked THEN PERFORM vv_ticket_once('m05.list_locked'); END IF;
  RETURN QUERY SELECT * FROM m05_list_members__kern(p_include_locked, p_purpose);
END $$;

CREATE OR REPLACE FUNCTION rbac_assign_role(p_person uuid, p_role text, p_scope uuid,
                                            p_valid_from timestamptz DEFAULT now(),
                                            p_valid_to timestamptz DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  PERFORM vv_ticket_once('rbac.assign');
  RETURN rbac_assign_role__kern(p_person, p_role, p_scope, p_valid_from, p_valid_to);
END $$;

CREATE OR REPLACE FUNCTION rbac_revoke_role(p_assignment uuid) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  PERFORM vv_ticket_once('rbac.revoke');
  RETURN rbac_revoke_role__kern(p_assignment);
END $$;

-- =============================================================================================
-- 11) RLS-Leistung: Kontext EINMAL je Abfrage auswerten (InitPlan statt je Zeile)
-- =============================================================================================
DO $$
DECLARE p record;
BEGIN
  FOR p IN SELECT tablename, policyname FROM pg_policies
            WHERE schemaname = 'public' AND cmd = 'ALL'
              AND qual = '(tenant_id = vv_current_tenant())'
              AND with_check = '(tenant_id = vv_current_tenant())'
  LOOP
    EXECUTE format('ALTER POLICY %I ON public.%I USING (tenant_id = (SELECT vv_current_tenant())) '
                   'WITH CHECK (tenant_id = (SELECT vv_current_tenant()))', p.policyname, p.tablename);
  END LOOP;
END $$;

-- =============================================================================================
-- 12) Eigentümer + Rechte (Positivlisten)
-- =============================================================================================
ALTER FUNCTION vv_b64url_decode(text)         OWNER TO vv_ticketcheck;
ALTER FUNCTION vv_current_tenant()            OWNER TO vv_ticketcheck;
ALTER FUNCTION vv_actor()                     OWNER TO vv_ticketcheck;
ALTER FUNCTION vv_ctx_kind()                  OWNER TO vv_ticketcheck;
ALTER FUNCTION vv_set_context(text)           OWNER TO vv_ticketcheck;
ALTER FUNCTION vv_worker_context(uuid)        OWNER TO vv_ticketcheck;
ALTER FUNCTION vv_worker_tenants()            OWNER TO vv_ticketcheck;
ALTER FUNCTION vv_ticket_once(text)           OWNER TO vv_ticketcheck;
ALTER FUNCTION vv_ticket_housekeeping()       OWNER TO vv_ticketcheck;
ALTER FUNCTION basis01_list_persons()         OWNER TO vv_definer;
ALTER FUNCTION basis02_list_role_assignments() OWNER TO vv_definer;
DO $$
DECLARE f record;
BEGIN
  FOR f IN SELECT p.oid::regprocedure AS sig FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'public' AND p.proname IN ('m05_decide','m05_import_decide','m05_request_termination',
                  'm05_import_request','m05_export_members','m05_list_members','rbac_assign_role','rbac_revoke_role')
  LOOP
    EXECUTE format('ALTER FUNCTION %s OWNER TO vv_definer', f.sig);
  END LOOP;
END $$;

-- (a) Tabellen/Sequenzen: vv_app hat KEINE direkten Rechte mehr (Bau-Auftrag §2.2); Worker auch nicht.
REVOKE ALL ON ALL TABLES    IN SCHEMA public FROM vv_app, vv_worker, PUBLIC;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM vv_app, vv_worker, PUBLIC;
-- Kein von der App anlegbares Objekt gleichen Namens: TEMP für alle entziehen (CREATE hat vv_app nirgends).
DO $$ BEGIN EXECUTE format('REVOKE TEMPORARY ON DATABASE %I FROM PUBLIC', current_database()); END $$;

-- (b) Funktionen: PUBLIC-Default und alle bisherigen App-/Worker-Rechte entziehen …
DO $$
DECLARE f record;
BEGIN
  FOR f IN SELECT p.oid::regprocedure AS sig FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'public'
              AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e')
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, vv_app, vv_worker', f.sig);
  END LOOP;
END $$;

-- pg-boss-Schema (Eigentümer vv_worker): Funktionen nicht für PUBLIC (die App hat dort ohnehin keine USAGE).
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA pgboss FROM PUBLIC;
REVOKE ALL ON SCHEMA pgboss FROM PUBLIC, vv_app;

-- … dann Positivliste Web-App (vv_app): Kontext, Audit, Policy, geprüfte Fachbefehle/Lesesichten.
GRANT EXECUTE ON FUNCTION
  vv_set_context(text), vv_current_tenant(), vv_actor(),
  vv_audit_log(text, text, jsonb),
  vv_policy_any(text, text, text), vv_authorize(text, text, text, uuid[], uuid),
  rbac_assign_role(uuid, text, uuid, timestamptz, timestamptz), rbac_revoke_role(uuid),
  rbac_create_scope_node(uuid, text, text),
  basis01_list_persons(), basis02_list_role_assignments(),
  m05_type_create(text, text, text, integer, text, integer, uuid),
  m05_type_new_version(uuid, date, integer, text, integer, uuid),
  m05_settings_update(integer, integer, integer, integer),
  m05_apply(uuid, text, uuid, date),
  m05_admit(uuid, date, integer), m05_reject(uuid, integer),
  m05_suspend(uuid, date, integer), m05_resume(uuid, date, integer),
  m05_change_type(uuid, uuid, date, integer), m05_withdraw_notice(uuid, integer),
  m05_request_termination(uuid, text, date, text, text, text, date, integer),
  m05_pending_approvals(), m05_decide(uuid, text), m05_decide_proposal(uuid, text),
  m05_import_request(text, text, integer), m05_import_decide(text, text),
  m05_list_members(boolean, text), m05_export_members(text, boolean), m05_get_member(uuid),
  m05_notice_date(date, integer, text), m05_today()
TO vv_app;

-- … und feste, kurze Positivliste Worker (vv_worker): Systemkontext + Systemfunktionen.
GRANT EXECUTE ON FUNCTION
  vv_worker_context(uuid), vv_worker_tenants(), vv_ticket_housekeeping(),
  vv_outbox_claim(integer, text[]), vv_outbox_done(uuid, uuid),
  vv_outbox_fail(uuid, uuid, text, integer), vv_outbox_renew(uuid, uuid, integer),
  vv_consume_approval(text, text),
  m05_execute(uuid), m05_job_daily(), m05_import_apply(text, jsonb)
TO vv_worker;

-- Definer-Rolle (Fachfunktionen): Kontext lesen, Einmal-Ticket, reine Helfer; Kerne der Wrapper.
GRANT EXECUTE ON FUNCTION vv_current_tenant(), vv_actor(), vv_ctx_kind(), vv_ticket_once(text),
  vv_model_family(text), vv_attestation_ok(text, text) TO vv_definer;
-- Prüf-Rolle: eigene Helfer.
GRANT EXECUTE ON FUNCTION vv_b64url_decode(text) TO vv_ticketcheck;

COMMIT;
