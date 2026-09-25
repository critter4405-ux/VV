-- VV Migration 0008 — Modul M05 „Mitglieder": Fachfunktionen (einziger Schreibpfad)
-- Jede Funktion: (1) prüft das Recht DB-seitig über vv_authorize (app.actor, deny-by-default,
-- Defense-in-Depth zum App-Prüfpunkt, ADR-04), (2) setzt den Fachkontext für den Zustandsautomaten,
-- (3) schreibt Audit-Kette + Outbox in DERSELBEN Transaktion (ADR-05). Eigentümer = vv_definer
-- (NOBYPASSRLS) -> RLS gilt auch hier. Idempotent (CREATE OR REPLACE), atomar.

BEGIN;
SET LOCAL client_min_messages = warning;

-- ---------------------------------------------------------------------------------------------
-- Interne Helfer
-- ---------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION m05_ctx(p_ctx text, p_actor text, p_effective date, p_approval uuid DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  PERFORM set_config('m05.ctx', p_ctx, true);
  PERFORM set_config('m05.actor', coalesce(p_actor, ''), true);
  PERFORM set_config('m05.effective', coalesce(p_effective::text, ''), true);
  PERFORM set_config('m05.approval_id', coalesce(p_approval::text, ''), true);
END $$;

CREATE OR REPLACE FUNCTION m05_deny(p_what text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'deny-by-default: keine Berechtigung %', p_what USING ERRCODE = '42501';
END $$;

-- „Heute" im Kalender des Vereins (tenant.tz, IANA; B08-1) — nicht in der Server-Zeitzone.
-- Sonst kippen Stichtage zwischen 22:00 und 24:00 UTC auf den falschen Tag.
CREATE OR REPLACE FUNCTION m05_today() RETURNS date
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT (now() AT TIME ZONE coalesce((SELECT tz FROM tenant WHERE id = vv_current_tenant()), 'Europe/Vienna'))::date
$$;

-- Kündigungsstichtag: Eingang + Frist (Monate), dann auf den Stichtag der Art gerundet (AK-05).
CREATE OR REPLACE FUNCTION m05_notice_date(p_received date, p_months integer, p_cutoff text)
RETURNS date LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_cutoff
    WHEN 'sofort'         THEN d
    WHEN 'monatsende'     THEN (date_trunc('month', d) + interval '1 month - 1 day')::date
    WHEN 'quartalsende'   THEN (date_trunc('quarter', d) + interval '3 months - 1 day')::date
    WHEN 'halbjahresende' THEN (make_date(extract(year FROM d)::int, CASE WHEN extract(month FROM d) <= 6 THEN 6 ELSE 12 END, 1)
                                + interval '1 month - 1 day')::date
    WHEN 'jahresende'     THEN make_date(extract(year FROM d)::int, 12, 31)
  END
  FROM (SELECT (p_received + make_interval(months => p_months))::date AS d) x
$$;

-- Gültige Regel-Version einer Art zu einem Datum (sonst die früheste Version).
CREATE OR REPLACE FUNCTION m05_type_rule(p_type uuid, p_on date) RETURNS membership_type_version
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT v.* FROM membership_type_version v
   WHERE v.tenant_id = vv_current_tenant() AND v.type_id = p_type AND v.valid_from <= p_on
   ORDER BY v.version DESC
   LIMIT 1                                  -- Version 1 gilt ab 1900-01-01 -> immer vorhanden
$$;

-- Aktuelle Art-Zuordnung einer Periode zu einem Datum.
CREATE OR REPLACE FUNCTION m05_current_type(p_period uuid, p_on date DEFAULT m05_today())
RETURNS membership_type_assignment
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT a.* FROM membership_type_assignment a
   WHERE a.tenant_id = vv_current_tenant() AND a.period_id = p_period
   ORDER BY (a.effective_from <= p_on) DESC,
            CASE WHEN a.effective_from <= p_on THEN a.effective_from END DESC NULLS LAST,
            a.effective_from ASC, a.id DESC
   LIMIT 1
$$;

CREATE OR REPLACE FUNCTION m05_settings_get() RETURNS m05_settings
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE s m05_settings;
BEGIN
  SELECT * INTO s FROM m05_settings WHERE tenant_id = vv_current_tenant();
  IF NOT FOUND THEN
    s.tenant_id := vv_current_tenant(); s.lock_after_days := 0; s.retention_years := 7; s.aging_up_lead_days := 30;
    s.hold_extension_months := 12;
  END IF;
  RETURN s;
END $$;

-- Scopes der Person hinter einer Periode (für die Feldsicht-/Rechteprüfung am Objekt).
CREATE OR REPLACE FUNCTION m05_period_person(p_period uuid) RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT m.person_id FROM membership_period p JOIN member m ON m.tenant_id = p.tenant_id AND m.id = p.member_id
   WHERE p.tenant_id = vv_current_tenant() AND p.id = p_period
$$;

CREATE OR REPLACE FUNCTION m05_require(p_action text, p_class text, p_period uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_person uuid := m05_period_person(p_period);
BEGIN
  IF v_person IS NULL OR NOT vv_authorize('membership', p_action, p_class, vv_person_scopes(v_person), v_person) THEN
    PERFORM m05_deny('membership.' || p_action || '/' || p_class);
  END IF;
END $$;

-- Periode sperren + optimistische Nebenläufigkeit (BS-1): veraltete Version -> Ablehnung.
CREATE OR REPLACE FUNCTION m05_lock_period(p_period uuid, p_expected_version integer)
RETURNS membership_period LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE r membership_period;
BEGIN
  SELECT * INTO r FROM membership_period WHERE tenant_id = vv_current_tenant() AND id = p_period FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'M05: Periode % nicht gefunden', p_period USING ERRCODE = 'P0002'; END IF;
  IF p_expected_version IS NULL OR r.version <> p_expected_version THEN
    RAISE EXCEPTION 'M05: veraltete Version (erwartet %, aktuell %) — bitte neu laden', p_expected_version, r.version
      USING ERRCODE = '40001';
  END IF;
  RETURN r;
END $$;

CREATE OR REPLACE FUNCTION m05_emit(p_topic text, p_period uuid, p_extra jsonb DEFAULT '{}'::jsonb, p_key_suffix text DEFAULT '')
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_ver integer;
BEGIN
  SELECT version INTO v_ver FROM membership_period WHERE tenant_id = vv_current_tenant() AND id = p_period;
  PERFORM vv_outbox_emit(p_topic, jsonb_build_object('period_id', p_period) || coalesce(p_extra, '{}'::jsonb),
                         p_topic || ':' || p_period || ':' || coalesce(v_ver, 0) || p_key_suffix);
END $$;

-- ---------------------------------------------------------------------------------------------
-- Mitgliedsarten (Mandanten-Admin)
-- ---------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION m05_type_create(p_code text, p_name text, p_category text,
    p_notice_months integer DEFAULT 0, p_cutoff text DEFAULT 'sofort',
    p_youth_age_limit integer DEFAULT NULL, p_successor uuid DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_id uuid; v_succ_cat text;
BEGIN
  IF NOT vv_authorize('membership_type', 'create', 'Oe') THEN PERFORM m05_deny('membership_type.create'); END IF;
  IF (p_youth_age_limit IS NOT NULL OR p_successor IS NOT NULL) THEN
    IF p_category <> 'jugend' THEN RAISE EXCEPTION 'M05: Aging-up-Regel nur für Kategorie jugend'; END IF;
    SELECT category_code INTO v_succ_cat FROM membership_type WHERE tenant_id = vv_current_tenant() AND id = p_successor;
    IF v_succ_cat IS NULL OR v_succ_cat = 'jugend' THEN
      RAISE EXCEPTION 'M05: Folgeart muss eine Nicht-Jugend-Art dieses Vereins sein';
    END IF;
  END IF;
  INSERT INTO membership_type (tenant_id, code, name, category_code)
  VALUES (vv_current_tenant(), p_code, p_name, p_category) RETURNING id INTO v_id;
  INSERT INTO membership_type_version (tenant_id, type_id, version, valid_from, notice_months, notice_cutoff,
                                       youth_age_limit, successor_type_id, created_by)
  VALUES (vv_current_tenant(), v_id, 1, DATE '1900-01-01', p_notice_months, p_cutoff, p_youth_age_limit, p_successor, vv_actor());
  PERFORM vv_audit_write('m05.type.create', v_id::text, jsonb_build_object('code', p_code, 'category', p_category));
  PERFORM vv_outbox_emit('m05.type.created', jsonb_build_object('type_id', v_id), 'm05.type.created:' || v_id);
  RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION m05_type_new_version(p_type uuid, p_valid_from date,
    p_notice_months integer, p_cutoff text, p_youth_age_limit integer DEFAULT NULL, p_successor uuid DEFAULT NULL)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_cat text; v_ver integer; v_last date; v_succ_cat text;
BEGIN
  IF NOT vv_authorize('membership_type', 'update', 'Oe') THEN PERFORM m05_deny('membership_type.update'); END IF;
  SELECT category_code INTO v_cat FROM membership_type WHERE tenant_id = vv_current_tenant() AND id = p_type FOR UPDATE;
  IF v_cat IS NULL THEN RAISE EXCEPTION 'M05: Mitgliedsart % nicht gefunden', p_type; END IF;
  IF (p_youth_age_limit IS NOT NULL OR p_successor IS NOT NULL) THEN
    IF v_cat <> 'jugend' THEN RAISE EXCEPTION 'M05: Aging-up-Regel nur für Kategorie jugend'; END IF;
    SELECT category_code INTO v_succ_cat FROM membership_type WHERE tenant_id = vv_current_tenant() AND id = p_successor;
    IF v_succ_cat IS NULL OR v_succ_cat = 'jugend' THEN
      RAISE EXCEPTION 'M05: Folgeart muss eine Nicht-Jugend-Art dieses Vereins sein';
    END IF;
  END IF;
  SELECT max(version), max(valid_from) INTO v_ver, v_last FROM membership_type_version
   WHERE tenant_id = vv_current_tenant() AND type_id = p_type;
  IF p_valid_from < m05_today() OR p_valid_from <= v_last THEN
    RAISE EXCEPTION 'M05: neue Regel-Version gilt nur ab heute/Zukunft und nach der letzten Version (keine Rückwirkung)';
  END IF;
  INSERT INTO membership_type_version (tenant_id, type_id, version, valid_from, notice_months, notice_cutoff,
                                       youth_age_limit, successor_type_id, created_by)
  VALUES (vv_current_tenant(), p_type, v_ver + 1, p_valid_from, p_notice_months, p_cutoff, p_youth_age_limit, p_successor, vv_actor());
  PERFORM vv_audit_write('m05.type.version', p_type::text, jsonb_build_object('version', v_ver + 1, 'valid_from', p_valid_from));
  RETURN v_ver + 1;
END $$;

-- Alte 3-Parameter-Signatur (vor Reparaturrunde 1) entfernen, damit genau EIN Einstieg existiert.
DROP FUNCTION IF EXISTS m05_settings_update(integer, integer, integer);
CREATE OR REPLACE FUNCTION m05_settings_update(p_lock_after_days integer, p_retention_years integer,
                                               p_aging_up_lead_days integer, p_hold_extension_months integer DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_hold integer;
BEGIN
  IF NOT vv_authorize('membership_type', 'update', 'Oe') THEN PERFORM m05_deny('m05_settings.update'); END IF;
  v_hold := coalesce(p_hold_extension_months, (m05_settings_get()).hold_extension_months, 12);
  INSERT INTO m05_settings (tenant_id, lock_after_days, retention_years, aging_up_lead_days, hold_extension_months)
  VALUES (vv_current_tenant(), p_lock_after_days, p_retention_years, p_aging_up_lead_days, v_hold)
  ON CONFLICT (tenant_id) DO UPDATE SET lock_after_days = EXCLUDED.lock_after_days,
    retention_years = EXCLUDED.retention_years, aging_up_lead_days = EXCLUDED.aging_up_lead_days,
    hold_extension_months = EXCLUDED.hold_extension_months, updated_at = now();
  PERFORM vv_audit_write('m05.settings.update', vv_current_tenant()::text,
    jsonb_build_object('lock_after_days', p_lock_after_days, 'retention_years', p_retention_years,
                       'aging_up_lead_days', p_aging_up_lead_days, 'hold_extension_months', v_hold));
END $$;

-- ---------------------------------------------------------------------------------------------
-- Lebenszyklus — einfache Aktionen (berechtigte Rolle, kein Vier-Augen)
-- ---------------------------------------------------------------------------------------------
-- Antrag (UC: Aufnahme beantragen). Legt Mitglied (Person × Verein, Mitgliedsnummer) bei Bedarf an.
CREATE OR REPLACE FUNCTION m05_apply(p_person uuid, p_member_no text, p_type uuid, p_applied_on date)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_member member; v_period uuid; v_rule membership_type_version; v_status text;
BEGIN
  IF NOT vv_authorize('membership', 'create', 'S', vv_person_scopes(p_person), p_person) THEN
    PERFORM m05_deny('membership.create');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM person WHERE tenant_id = vv_current_tenant() AND id = p_person) THEN
    RAISE EXCEPTION 'M05: Person % nicht gefunden', p_person;
  END IF;
  IF p_applied_on IS NULL OR p_applied_on > m05_today() THEN
    RAISE EXCEPTION 'M05: Antragsdatum fehlt oder liegt in der Zukunft';
  END IF;
  SELECT status INTO v_status FROM membership_type WHERE tenant_id = vv_current_tenant() AND id = p_type;
  IF v_status IS DISTINCT FROM 'aktiv' THEN RAISE EXCEPTION 'M05: Mitgliedsart nicht aktiv/gefunden'; END IF;

  SELECT * INTO v_member FROM member WHERE tenant_id = vv_current_tenant() AND person_id = p_person FOR UPDATE;
  IF NOT FOUND THEN
    IF p_member_no IS NULL THEN RAISE EXCEPTION 'M05: Mitgliedsnummer für neues Mitglied erforderlich'; END IF;
    INSERT INTO member (tenant_id, person_id, member_no) VALUES (vv_current_tenant(), p_person, p_member_no)
    RETURNING * INTO v_member;
  ELSIF p_member_no IS NOT NULL AND p_member_no <> v_member.member_no THEN
    RAISE EXCEPTION 'M05: Mitgliedsnummer weicht vom Bestand ab (keine stille Änderung)';
  END IF;
  IF EXISTS (SELECT 1 FROM membership_period WHERE tenant_id = vv_current_tenant() AND member_id = v_member.id
               AND status IN ('beantragt','aktiv','ruhend','gekuendigt')) THEN
    RAISE EXCEPTION 'M05: es besteht bereits eine offene Mitgliedschaftsperiode' USING ERRCODE = '23505';
  END IF;

  PERFORM m05_ctx('cmd', vv_actor(), p_applied_on);
  INSERT INTO membership_period (tenant_id, member_id, status, applied_on)
  VALUES (vv_current_tenant(), v_member.id, 'beantragt', p_applied_on) RETURNING id INTO v_period;
  v_rule := m05_type_rule(p_type, p_applied_on);
  INSERT INTO membership_type_assignment (tenant_id, period_id, type_id, type_version, effective_from, actor, source)
  VALUES (vv_current_tenant(), v_period, p_type, v_rule.version, p_applied_on, vv_actor(), 'manuell');
  PERFORM vv_audit_write('m05.period.apply', v_period::text, jsonb_build_object('member_id', v_member.id, 'type_id', p_type));
  PERFORM m05_emit('m05.membership.applied', v_period, jsonb_build_object('member_id', v_member.id));
  RETURN v_period;
END $$;

-- Generische Statusaktion (Aufnahme, Ablehnung, Ruhen, Wiederaufnahme).
CREATE OR REPLACE FUNCTION m05_simple_transition(p_period uuid, p_expected_version integer, p_from text[],
                                                 p_to text, p_effective date, p_action text, p_topic text)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE r membership_period;
BEGIN
  PERFORM m05_require('update', 'S', p_period);
  r := m05_lock_period(p_period, p_expected_version);
  IF NOT (r.status = ANY (p_from)) THEN
    RAISE EXCEPTION 'M05: Aktion % im Status % nicht möglich', p_action, r.status;
  END IF;
  IF p_effective IS NULL OR p_effective > m05_today() + 366 THEN RAISE EXCEPTION 'M05: ungültiges Wirksamkeitsdatum'; END IF;
  PERFORM m05_ctx('cmd', vv_actor(), p_effective);
  IF p_to = 'aktiv' AND r.status = 'beantragt' THEN
    IF p_effective < r.applied_on THEN RAISE EXCEPTION 'M05: Eintritt vor Antragsdatum'; END IF;
    UPDATE membership_period SET status = 'aktiv', entry_date = p_effective WHERE id = p_period;
  ELSE
    UPDATE membership_period SET status = p_to WHERE id = p_period;   -- Übergang prüft der DB-Automat
  END IF;
  PERFORM vv_audit_write(p_action, p_period::text, jsonb_build_object('from', r.status, 'to', p_to, 'effective', p_effective));
  PERFORM m05_emit(p_topic, p_period, jsonb_build_object('effective', p_effective));
  RETURN r.version + 1;
END $$;

CREATE OR REPLACE FUNCTION m05_admit(p_period uuid, p_entry_date date, p_expected_version integer) RETURNS integer
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT m05_simple_transition(p_period, p_expected_version, ARRAY['beantragt'], 'aktiv', p_entry_date,
                               'm05.period.admit', 'm05.membership.admitted')
$$;
CREATE OR REPLACE FUNCTION m05_reject(p_period uuid, p_expected_version integer) RETURNS integer
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT m05_simple_transition(p_period, p_expected_version, ARRAY['beantragt'], 'abgelehnt', m05_today(),
                               'm05.period.reject', 'm05.membership.rejected')
$$;
CREATE OR REPLACE FUNCTION m05_suspend(p_period uuid, p_effective date, p_expected_version integer) RETURNS integer
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT m05_simple_transition(p_period, p_expected_version, ARRAY['aktiv'], 'ruhend', p_effective,
                               'm05.period.suspend', 'm05.membership.suspended')
$$;
CREATE OR REPLACE FUNCTION m05_resume(p_period uuid, p_effective date, p_expected_version integer) RETURNS integer
LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT m05_simple_transition(p_period, p_expected_version, ARRAY['ruhend'], 'aktiv', p_effective,
                               'm05.period.resume', 'm05.membership.resumed')
$$;

-- Artwechsel (manuell). Erhöht die Perioden-Version -> offene Kündigungsanträge werden „stale".
CREATE OR REPLACE FUNCTION m05_change_type(p_period uuid, p_type uuid, p_effective_from date, p_expected_version integer)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE r membership_period; v_cur membership_type_assignment; v_rule membership_type_version; v_status text;
BEGIN
  PERFORM m05_require('update', 'S', p_period);
  r := m05_lock_period(p_period, p_expected_version);
  IF r.status NOT IN ('beantragt','aktiv','ruhend','gekuendigt') THEN RAISE EXCEPTION 'M05: Artwechsel nur bei offener Periode'; END IF;
  SELECT status INTO v_status FROM membership_type WHERE tenant_id = vv_current_tenant() AND id = p_type;
  IF v_status IS DISTINCT FROM 'aktiv' THEN RAISE EXCEPTION 'M05: Mitgliedsart nicht aktiv/gefunden'; END IF;
  v_cur := m05_current_type(p_period, m05_today());
  IF p_effective_from IS NULL OR p_effective_from < v_cur.effective_from THEN
    RAISE EXCEPTION 'M05: Artwechsel darf nicht vor der letzten Zuordnung wirken';
  END IF;
  IF v_cur.type_id = p_type THEN RAISE EXCEPTION 'M05: Art unverändert'; END IF;
  v_rule := m05_type_rule(p_type, p_effective_from);
  PERFORM m05_ctx('cmd', vv_actor(), p_effective_from);
  INSERT INTO membership_type_assignment (tenant_id, period_id, type_id, type_version, effective_from, actor, source)
  VALUES (vv_current_tenant(), p_period, p_type, v_rule.version, p_effective_from, vv_actor(), 'manuell');
  UPDATE membership_period SET updated_at = now() WHERE id = p_period;   -- Version++ (Guard)
  PERFORM vv_audit_write('m05.period.change_type', p_period::text,
    jsonb_build_object('from_type', v_cur.type_id, 'to_type', p_type, 'effective', p_effective_from));
  PERFORM m05_emit('m05.membership.type_changed', p_period, jsonb_build_object('type_id', p_type, 'effective', p_effective_from));
  RETURN r.version + 1;
END $$;

-- Kündigung zurücknehmen (vor dem Stichtag) — stellt den Ausgangszustand wieder her.
CREATE OR REPLACE FUNCTION m05_withdraw_notice(p_period uuid, p_expected_version integer)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE r membership_period;
BEGIN
  PERFORM m05_require('deactivate', 'S', p_period);
  r := m05_lock_period(p_period, p_expected_version);
  IF r.status <> 'gekuendigt' OR r.end_kind <> 'ausgetreten' OR r.exit_effective_date <= m05_today() THEN
    RAISE EXCEPTION 'M05: Rücknahme nur bei vorgemerkter Kündigung vor dem Stichtag';
  END IF;
  PERFORM m05_ctx('cmd', vv_actor(), m05_today());
  UPDATE membership_period SET status = 'aktiv', end_kind = NULL, exit_effective_date = NULL,
         notice_received_on = NULL, end_reason_code = NULL WHERE id = p_period;
  PERFORM vv_audit_write('m05.period.withdraw_notice', p_period::text, '{}'::jsonb);
  PERFORM m05_emit('m05.membership.notice_withdrawn', p_period);
  RETURN r.version + 1;
END $$;

-- ---------------------------------------------------------------------------------------------
-- Harte Grenzen — Antrag -> Vier-Augen-Entscheidung -> Ausführung (Worker)
-- ---------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION m05_open_request(p_period uuid, p_effect text, p_payload jsonb,
                                            p_period_version integer, p_requested_by text, p_kind text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_app uuid; v_hash text; o record;
BEGIN
  -- Abgelaufene/abgelehnte offene Anträge schließen, bevor ein neuer entsteht.
  FOR o IN SELECT r.approval_id, a.status, a.expires_at FROM m05_approval_request r JOIN approval a ON a.id = r.approval_id
            WHERE r.tenant_id = vv_current_tenant() AND r.period_id = p_period AND r.effect_id = p_effect
              AND r.closed_at IS NULL FOR UPDATE OF r LOOP
    IF o.status = 'rejected' THEN
      UPDATE m05_approval_request SET closed_at = now(), outcome = 'rejected' WHERE approval_id = o.approval_id;
    ELSIF o.expires_at IS NOT NULL AND o.expires_at <= now() THEN
      UPDATE m05_approval_request SET closed_at = now(), outcome = 'expired' WHERE approval_id = o.approval_id;
    ELSE
      RAISE EXCEPTION 'M05: für diese Periode ist bereits ein Antrag offen' USING ERRCODE = '23505';
    END IF;
  END LOOP;
  v_hash := encode(digest(convert_to(p_payload::text, 'UTF8'), 'sha256'), 'hex');
  -- Im (für vv_app lesbaren) Freigabe-Objekt steht NUR der Hash — die Parameter (ggf. Se, z. B.
  -- Ausschlussgrund) liegen im geschützten Antrag (m05_approval_request), Sicht nur feldgefiltert.
  INSERT INTO approval (tenant_id, kind, effect_id, subject_ref, requested_by, builder_model, context, expires_at)
  VALUES (vv_current_tenant(), p_kind, p_effect, p_period::text, p_requested_by,
          CASE WHEN p_requested_by LIKE 'system:%' THEN 'system:m05-job' ELSE 'human:manuell' END,
          jsonb_build_object('payload_sha256', v_hash, 'effect', p_effect), now() + interval '30 days')
  RETURNING id INTO v_app;
  INSERT INTO m05_approval_request (approval_id, tenant_id, period_id, effect_id, requested_by, payload, payload_hash, period_version)
  VALUES (v_app, vv_current_tenant(), p_period, p_effect, p_requested_by, p_payload, v_hash, p_period_version);
  PERFORM vv_audit_write('m05.approval.request', v_app::text,
    jsonb_build_object('effect', p_effect, 'period_id', p_period, 'payload_sha256', v_hash), p_requested_by);
  PERFORM vv_outbox_emit('m05.approval.requested', jsonb_build_object('approval_id', v_app, 'period_id', p_period, 'effect', p_effect),
                         'm05.approval.requested:' || v_app);
  RETURN v_app;
END $$;

-- Beendigung beantragen (Austritt / Ausschluss / Todesfall) — erzeugt NUR ein Freigabe-Objekt.
CREATE OR REPLACE FUNCTION m05_request_termination(p_period uuid, p_end_kind text, p_notice_received_on date,
    p_reason_code text, p_exclusion_code text, p_resolution_ref text, p_effective_date date, p_expected_version integer)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE r membership_period; v_type membership_type_assignment; v_rule membership_type_version;
        v_eff date; v_min date; v_kind text; v_payload jsonb;
BEGIN
  PERFORM m05_require('deactivate', 'S', p_period);
  IF p_end_kind = 'ausgeschlossen' THEN PERFORM m05_require('deactivate', 'Se', p_period); END IF;
  r := m05_lock_period(p_period, p_expected_version);
  IF r.status NOT IN ('aktiv','ruhend') THEN RAISE EXCEPTION 'M05: Beendigung nur aus aktiv/ruhend'; END IF;

  IF p_end_kind = 'ausgetreten' THEN
    IF p_notice_received_on IS NULL OR p_notice_received_on > m05_today() THEN
      RAISE EXCEPTION 'M05: Eingangsdatum der Kündigung fehlt oder liegt in der Zukunft';
    END IF;
    IF p_exclusion_code IS NOT NULL OR p_resolution_ref IS NOT NULL THEN
      RAISE EXCEPTION 'M05: Ausschluss-Angaben bei Austritt unzulässig';
    END IF;
    IF p_reason_code IS NOT NULL THEN
      SELECT kind INTO v_kind FROM membership_end_reason WHERE code = p_reason_code;
      IF v_kind IS DISTINCT FROM 'austritt' THEN RAISE EXCEPTION 'M05: unbekannter Austrittsgrund'; END IF;
    END IF;
    v_type := m05_current_type(p_period, p_notice_received_on);
    v_rule := m05_type_rule(v_type.type_id, p_notice_received_on);
    v_min := m05_notice_date(p_notice_received_on, v_rule.notice_months, v_rule.notice_cutoff);
    v_eff := coalesce(p_effective_date, v_min);
    IF v_eff < v_min THEN
      RAISE EXCEPTION 'M05: Austritt frühestens zum % (Kündigungsregel der Mitgliedsart)', v_min;
    END IF;
  ELSIF p_end_kind = 'ausgeschlossen' THEN
    SELECT kind INTO v_kind FROM membership_end_reason WHERE code = p_exclusion_code;
    IF v_kind IS DISTINCT FROM 'ausschluss' THEN RAISE EXCEPTION 'M05: Ausschluss braucht eine gültige Grundkategorie'; END IF;
    IF p_resolution_ref IS NULL THEN RAISE EXCEPTION 'M05: Ausschluss braucht eine Beschluss-Referenz'; END IF;
    IF p_reason_code IS NOT NULL OR p_notice_received_on IS NOT NULL THEN
      RAISE EXCEPTION 'M05: Austrittsangaben bei Ausschluss unzulässig';
    END IF;
    IF p_effective_date IS NULL OR p_effective_date > m05_today() THEN
      RAISE EXCEPTION 'M05: Ausschluss wirkt zum Beschlussdatum (nicht in der Zukunft)';
    END IF;
    v_eff := p_effective_date;
  ELSIF p_end_kind = 'verstorben' THEN
    IF p_reason_code IS NOT NULL OR p_exclusion_code IS NOT NULL OR p_resolution_ref IS NOT NULL OR p_notice_received_on IS NOT NULL THEN
      RAISE EXCEPTION 'M05: bei Todesfall keine Gründe/Kündigungsangaben';
    END IF;
    IF p_effective_date IS NULL OR p_effective_date > m05_today() THEN
      RAISE EXCEPTION 'M05: Sterbedatum fehlt oder liegt in der Zukunft';
    END IF;
    v_eff := p_effective_date;
  ELSE
    RAISE EXCEPTION 'M05: unbekannte Beendigungsart %', p_end_kind;
  END IF;
  IF v_eff < r.entry_date THEN RAISE EXCEPTION 'M05: Beendigung vor dem Eintritt'; END IF;

  v_payload := jsonb_build_object('period_id', p_period, 'end_kind', p_end_kind,
    'notice_received_on', p_notice_received_on, 'effective_date', v_eff, 'reason_code', p_reason_code,
    'exclusion_code', p_exclusion_code, 'resolution_ref', p_resolution_ref);
  RETURN m05_open_request(p_period, 'm05.membership.terminate', v_payload, r.version, vv_actor(), 'legal');
END $$;

-- Offene M05-Freigaben für Freigeber (Se-Angaben nur mit Se-Sicht).
CREATE OR REPLACE FUNCTION m05_pending_approvals()
RETURNS TABLE (approval_id uuid, period_id uuid, effect_id text, requested_by text, created_at timestamptz,
               expires_at timestamptz, status text, payload jsonb)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE x record; v_person uuid; v_scopes uuid[];
BEGIN
  FOR x IN SELECT r.*, a.status AS a_status, a.expires_at AS a_exp FROM m05_approval_request r
             JOIN approval a ON a.id = r.approval_id
            WHERE r.tenant_id = vv_current_tenant() AND r.closed_at IS NULL ORDER BY r.created_at LOOP
    v_person := m05_period_person(x.period_id);
    v_scopes := CASE WHEN v_person IS NULL THEN NULL ELSE vv_person_scopes(v_person) END;
    CONTINUE WHEN NOT vv_authorize('membership', 'approve', 'S', v_scopes);
    approval_id := x.approval_id; period_id := x.period_id; effect_id := x.effect_id;
    requested_by := x.requested_by; created_at := x.created_at; expires_at := x.a_exp; status := x.a_status;
    payload := CASE WHEN vv_authorize('membership', 'read', 'Se', v_scopes) THEN x.payload
                    ELSE x.payload - 'exclusion_code' - 'resolution_ref' END;
    RETURN NEXT;
  END LOOP;
  PERFORM vv_audit_write('m05.approval.list', NULL, '{}'::jsonb);
END $$;

-- Reparaturrunde 1 (Gemini G-3): abgelehnte Anonymisierung = Aufbewahrung verlängert (Legal Hold),
-- statt täglich neuer Antrag. Verlängerung ab Entscheidungsdatum um hold_extension_months, protokolliert.
CREATE OR REPLACE FUNCTION m05_apply_hold(p_period uuid, p_approval uuid, p_decided date)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE s m05_settings := m05_settings_get(); v_until date;
BEGIN
  -- Review R2 (Codex M-2): idempotent — nur wer den offenen Antrag schließt, setzt den Hold
  -- (ein paralleler Tageslauf, der denselben Antrag noch sah, endet hier ohne Wirkung).
  UPDATE m05_approval_request SET closed_at = now(), outcome = 'rejected'
   WHERE tenant_id = vv_current_tenant() AND approval_id = p_approval AND closed_at IS NULL;
  IF NOT FOUND THEN RETURN; END IF;
  v_until := (greatest(coalesce(p_decided, m05_today()), m05_today()) + make_interval(months => s.hold_extension_months))::date;
  PERFORM m05_ctx('job', 'system:m05-hold', m05_today(), p_approval);
  UPDATE membership_period SET retention_until = greatest(retention_until, v_until)
   WHERE tenant_id = vv_current_tenant() AND id = p_period AND status = 'gesperrt';
  PERFORM vv_audit_write('m05.retention.hold', p_period::text,
    jsonb_build_object('approval_id', p_approval, 'retention_until', v_until, 'months', s.hold_extension_months),
    coalesce(vv_actor(), 'system:m05-hold'));
  -- Review R2 (Codex M-1): Zustandsänderung => Outbox-Ereignis in derselben Transaktion (ADR-05),
  -- nur IDs + Datum (kein Personenbezug).
  PERFORM m05_emit('m05.retention.hold', p_period,
    jsonb_build_object('approval_id', p_approval, 'retention_until', v_until), ':' || p_approval);
END $$;

-- Entscheidung (Vorstand/Obmann). Freigeber = app.actor (vv_decide_approval), nie der Antragsteller.
CREATE OR REPLACE FUNCTION m05_decide(p_approval uuid, p_decision text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE x m05_approval_request; v_person uuid; v_scopes uuid[];
BEGIN
  SELECT * INTO x FROM m05_approval_request WHERE tenant_id = vv_current_tenant() AND approval_id = p_approval
     AND closed_at IS NULL FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'M05: kein offener M05-Antrag %', p_approval; END IF;
  v_person := m05_period_person(x.period_id);
  v_scopes := CASE WHEN v_person IS NULL THEN NULL ELSE vv_person_scopes(v_person) END;
  IF NOT vv_authorize('membership', 'approve', 'S', v_scopes) THEN PERFORM m05_deny('membership.approve'); END IF;
  PERFORM vv_decide_approval(p_approval, p_decision, NULL);     -- SoD + Freigeber aus app.actor (DB)
  IF p_decision = 'approved' THEN
    PERFORM vv_outbox_emit('m05.execute', jsonb_build_object('approval_id', p_approval), 'm05.execute:' || p_approval);
  ELSIF x.effect_id = 'm05.membership.anonymize' THEN
    PERFORM m05_apply_hold(x.period_id, p_approval, m05_today());       -- G-3: Legal Hold
  ELSE
    UPDATE m05_approval_request SET closed_at = now(), outcome = 'rejected' WHERE approval_id = p_approval;
  END IF;
  PERFORM vv_audit_write('m05.approval.decide', p_approval::text,
    jsonb_build_object('decision', p_decision, 'effect', x.effect_id, 'period_id', x.period_id));
  RETURN jsonb_build_object('ok', true, 'decision', p_decision);
END $$;

-- AUSFÜHRUNG (nur Worker/Executor). Consume + Wirkung ATOMAR in einer Transaktion. Parameter
-- kommen ausschließlich aus dem gebundenen Antrag (Hash-geprüft), nie vom Aufrufer.
CREATE OR REPLACE FUNCTION m05_execute(p_approval uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE x m05_approval_request; a approval; r membership_period; s m05_settings;
        v_consumed uuid; v_person uuid; v_scopes uuid[]; v_eff date; v_to text; p jsonb;
BEGIN
  SELECT * INTO x FROM m05_approval_request WHERE tenant_id = vv_current_tenant() AND approval_id = p_approval FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'M05: Freigabe % ist kein geprüfter M05-Antrag (verweigert)', p_approval; END IF;
  IF x.closed_at IS NOT NULL THEN
    RETURN jsonb_build_object('ok', true, 'noop', true, 'outcome', x.outcome);   -- idempotent (Retry)
  END IF;
  SELECT * INTO a FROM approval WHERE tenant_id = vv_current_tenant() AND id = p_approval;
  -- Bindung Antrag <-> Freigabe (gegen direkt eingefügte/umgeschriebene approval-Zeilen)
  IF a.effect_id <> x.effect_id OR a.subject_ref <> x.period_id::text OR a.requested_by <> x.requested_by
     OR a.context->>'payload_sha256' IS DISTINCT FROM x.payload_hash
     OR encode(digest(convert_to(x.payload::text, 'UTF8'), 'sha256'), 'hex') <> x.payload_hash THEN
    RAISE EXCEPTION 'M05: Freigabe passt nicht zum gebundenen Antrag (Manipulation) — verweigert';
  END IF;
  IF a.status = 'rejected' THEN
    IF x.effect_id = 'm05.membership.anonymize' THEN
      PERFORM m05_apply_hold(x.period_id, p_approval, a.decided_at::date);
    ELSE
      UPDATE m05_approval_request SET closed_at = now(), outcome = 'rejected' WHERE approval_id = p_approval;
    END IF;
    RETURN jsonb_build_object('ok', false, 'outcome', 'rejected');
  END IF;
  IF a.status <> 'approved' THEN RAISE EXCEPTION 'M05: Freigabe % noch nicht erteilt', p_approval; END IF;
  IF a.expires_at IS NOT NULL AND a.expires_at <= now() THEN
    UPDATE m05_approval_request SET closed_at = now(), outcome = 'expired' WHERE approval_id = p_approval;
    PERFORM vv_audit_write('m05.execute.expired', p_approval::text, '{}'::jsonb, 'system:m05-executor');
    RETURN jsonb_build_object('ok', false, 'outcome', 'expired');
  END IF;
  -- Freigeber muss (weiterhin) freigabeberechtigt sein; Systemakteure nie.
  v_person := m05_period_person(x.period_id);
  v_scopes := CASE WHEN v_person IS NULL THEN NULL ELSE vv_person_scopes(v_person) END;
  IF a.approved_by IS NULL OR a.approved_by = a.requested_by
     OR NOT vv_authorize_subject(a.approved_by, 'membership', 'approve', 'S', v_scopes) THEN
    RAISE EXCEPTION 'M05: Freigeber nicht berechtigt/gleich Antragsteller — verweigert';
  END IF;

  SELECT * INTO r FROM membership_period WHERE tenant_id = vv_current_tenant() AND id = x.period_id FOR UPDATE;
  IF r.version <> x.period_version THEN
    UPDATE m05_approval_request SET closed_at = now(), outcome = 'stale' WHERE approval_id = p_approval;
    PERFORM vv_audit_write('m05.execute.stale', p_approval::text,
      jsonb_build_object('period_id', x.period_id), 'system:m05-executor');
    RETURN jsonb_build_object('ok', false, 'outcome', 'stale');
  END IF;

  -- Atomarer Einmal-Consume (Stage-0-Funktion): muss GENAU diese Freigabe liefern.
  v_consumed := vv_consume_approval(x.effect_id, x.period_id::text);
  IF v_consumed IS DISTINCT FROM p_approval THEN
    RAISE EXCEPTION 'M05: Consume lieferte % statt % — verweigert', v_consumed, p_approval;
  END IF;

  s := m05_settings_get();
  p := x.payload;
  IF x.effect_id = 'm05.membership.terminate' THEN
    IF r.status NOT IN ('aktiv','ruhend') THEN RAISE EXCEPTION 'M05: Periode nicht mehr beendbar (%)', r.status; END IF;
    v_eff := (p->>'effective_date')::date;
    v_to := CASE WHEN v_eff > m05_today() THEN 'gekuendigt' ELSE 'beendet' END;
    PERFORM m05_ctx('exec', 'system:m05-executor', v_eff, p_approval);
    UPDATE membership_period SET status = v_to,
           end_kind = p->>'end_kind', exit_effective_date = v_eff,
           notice_received_on = (p->>'notice_received_on')::date,
           end_reason_code = p->>'reason_code', exclusion_reason_code = p->>'exclusion_code',
           resolution_ref = p->>'resolution_ref',
           retention_until = CASE WHEN v_to = 'beendet' THEN (v_eff + make_interval(years => s.retention_years))::date END
     WHERE id = x.period_id;
    PERFORM m05_emit(CASE WHEN v_to = 'beendet' THEN 'm05.membership.ended' ELSE 'm05.membership.notice_recorded' END,
                     x.period_id, jsonb_build_object('end_kind', p->>'end_kind', 'effective', v_eff));
  ELSE  -- m05.membership.anonymize
    IF r.status <> 'gesperrt' OR r.retention_until IS NULL OR r.retention_until > m05_today() THEN
      RAISE EXCEPTION 'M05: Anonymisierung erst nach Ablauf der Aufbewahrung (Status gesperrt)';
    END IF;
    PERFORM m05_ctx('exec', 'system:m05-executor', m05_today(), p_approval);
    UPDATE membership_period SET status = 'anonymisiert', anonymized_at = now(),
           end_reason_code = NULL, exclusion_reason_code = NULL, resolution_ref = NULL,
           notice_received_on = NULL, import_batch = NULL,
           entry_date = date_trunc('year', entry_date)::date,
           exit_effective_date = date_trunc('year', exit_effective_date)::date
     WHERE id = x.period_id;
    UPDATE membership_proposal SET status = 'hinfaellig', decided_at = now(), decided_by = 'system:m05-executor'
     WHERE tenant_id = vv_current_tenant() AND period_id = x.period_id AND status = 'offen';
    -- Mitglied selbst erst, wenn KEINE nicht-anonymisierte Periode mehr existiert.
    UPDATE member m SET person_id = NULL, member_no = NULL, anonymized_at = now()
     WHERE m.tenant_id = vv_current_tenant() AND m.id = r.member_id AND m.anonymized_at IS NULL
       AND NOT EXISTS (SELECT 1 FROM membership_period q WHERE q.tenant_id = m.tenant_id
                         AND q.member_id = m.id AND q.status <> 'anonymisiert');
    PERFORM m05_emit('m05.membership.anonymized', x.period_id);
  END IF;
  UPDATE m05_approval_request SET closed_at = now(), outcome = 'executed' WHERE approval_id = p_approval;
  PERFORM vv_audit_write('m05.execute', p_approval::text,
    jsonb_build_object('effect', x.effect_id, 'period_id', x.period_id, 'requested_by', a.requested_by,
                       'approved_by', a.approved_by, 'payload_sha256', x.payload_hash), 'system:m05-executor');
  RETURN jsonb_build_object('ok', true, 'outcome', 'executed', 'effect', x.effect_id);
END $$;

-- ---------------------------------------------------------------------------------------------
-- Aging-up-Vorschlag entscheiden (nie still, P50-4)
-- ---------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION m05_decide_proposal(p_proposal uuid, p_decision text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE pr membership_proposal; r membership_period; v_rule membership_type_version;
BEGIN
  SELECT * INTO pr FROM membership_proposal WHERE tenant_id = vv_current_tenant() AND id = p_proposal FOR UPDATE;
  IF NOT FOUND OR pr.status <> 'offen' THEN RAISE EXCEPTION 'M05: kein offener Vorschlag %', p_proposal; END IF;
  PERFORM m05_require('update', 'S', pr.period_id);
  IF p_decision NOT IN ('bestaetigt','abgelehnt') THEN RAISE EXCEPTION 'M05: ungültige Entscheidung'; END IF;
  SELECT * INTO r FROM membership_period WHERE tenant_id = vv_current_tenant() AND id = pr.period_id FOR UPDATE;
  IF p_decision = 'bestaetigt' THEN
    IF r.status NOT IN ('aktiv','ruhend','gekuendigt') THEN RAISE EXCEPTION 'M05: Periode nicht mehr offen'; END IF;
    v_rule := m05_type_rule(pr.to_type_id, pr.due_date);
    PERFORM m05_ctx('cmd', vv_actor(), pr.due_date);
    INSERT INTO membership_type_assignment (tenant_id, period_id, type_id, type_version, effective_from, actor, source)
    VALUES (vv_current_tenant(), pr.period_id, pr.to_type_id, v_rule.version, pr.due_date, vv_actor(), 'aging_up');
    UPDATE membership_period SET updated_at = now() WHERE id = pr.period_id;
    PERFORM m05_emit('m05.membership.type_changed', pr.period_id,
                     jsonb_build_object('type_id', pr.to_type_id, 'effective', pr.due_date, 'source', 'aging_up'));
  END IF;
  UPDATE membership_proposal SET status = p_decision, decided_at = now(), decided_by = vv_actor() WHERE id = p_proposal;
  PERFORM vv_audit_write('m05.proposal.decide', p_proposal::text, jsonb_build_object('decision', p_decision));
  RETURN jsonb_build_object('ok', true);
END $$;

-- ---------------------------------------------------------------------------------------------
-- Tagesjob (Worker, je Mandant): Stichtag, Sperre, Aging-up, Aufbewahrungsfrist. Idempotent.
-- Nutzt ausschließlich m05_today() (Vereins-Zeitzone; kein vom Aufrufer gelieferter „heute"-Wert).
-- ---------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION m05_job_daily()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE s m05_settings := m05_settings_get(); r record; v_app uuid;
        n_end int := 0; n_lock int := 0; n_prop int := 0; n_ret int := 0; n_miss int := 0; n_hold int := 0;
        v_type membership_type_assignment; v_rule membership_type_version; v_birth date; v_due date; v_new uuid;
BEGIN
  IF vv_current_tenant() IS NULL THEN RAISE EXCEPTION 'm05_job_daily: kein Mandantenkontext'; END IF;
  -- (1) Stichtag erreicht: gekündigt -> beendet (bereits freigegeben)
  FOR r IN SELECT * FROM membership_period WHERE tenant_id = vv_current_tenant() AND status = 'gekuendigt'
              AND exit_effective_date <= m05_today() FOR UPDATE SKIP LOCKED LOOP
    SELECT approval_id INTO v_app FROM m05_approval_request WHERE tenant_id = vv_current_tenant()
       AND period_id = r.id AND effect_id = 'm05.membership.terminate' AND outcome = 'executed'
     ORDER BY closed_at DESC LIMIT 1;
    PERFORM m05_ctx('job', 'system:m05-job', r.exit_effective_date, v_app);
    UPDATE membership_period SET status = 'beendet',
           retention_until = (r.exit_effective_date + make_interval(years => s.retention_years))::date
     WHERE id = r.id;
    PERFORM vv_audit_write('m05.job.end', r.id::text, jsonb_build_object('approval_id', v_app), 'system:m05-job');
    PERFORM m05_emit('m05.membership.ended', r.id, jsonb_build_object('end_kind', r.end_kind, 'effective', r.exit_effective_date));
    n_end := n_end + 1;
  END LOOP;
  -- (2) Sperre (Art. 18) nach Nachlauf
  FOR r IN SELECT * FROM membership_period WHERE tenant_id = vv_current_tenant() AND status = 'beendet'
              AND exit_effective_date + s.lock_after_days <= m05_today() FOR UPDATE SKIP LOCKED LOOP
    PERFORM m05_ctx('job', 'system:m05-job', m05_today(), NULL);
    UPDATE membership_period SET status = 'gesperrt', locked_at = now() WHERE id = r.id;
    PERFORM vv_audit_write('m05.job.lock', r.id::text, '{}'::jsonb, 'system:m05-job');
    PERFORM m05_emit('m05.membership.locked', r.id);
    n_lock := n_lock + 1;
  END LOOP;
  -- (3) Aging-up: Vorschlag je Periode × Stichtag (idempotent), fehlendes Geburtsdatum -> Hinweis
  FOR r IN SELECT p.*, m.person_id FROM membership_period p JOIN member m ON m.tenant_id = p.tenant_id AND m.id = p.member_id
            WHERE p.tenant_id = vv_current_tenant() AND p.status IN ('aktiv','ruhend') LOOP
    v_type := m05_current_type(r.id, m05_today());
    CONTINUE WHEN v_type.type_id IS NULL;
    v_rule := m05_type_rule(v_type.type_id, m05_today());
    CONTINUE WHEN v_rule.youth_age_limit IS NULL
               OR (SELECT category_code FROM membership_type WHERE tenant_id = vv_current_tenant() AND id = v_type.type_id) <> 'jugend';
    SELECT birth_date INTO v_birth FROM person WHERE tenant_id = vv_current_tenant() AND id = r.person_id;
    IF v_birth IS NULL THEN
      PERFORM vv_outbox_emit('m05.aging_up.data_missing', jsonb_build_object('period_id', r.id),
                             'm05.aging_up.data_missing:' || r.id);
      n_miss := n_miss + 1;
      CONTINUE;
    END IF;
    v_due := (v_birth + make_interval(years => v_rule.youth_age_limit))::date;
    CONTINUE WHEN v_due > m05_today() + s.aging_up_lead_days;
    v_new := NULL;
    INSERT INTO membership_proposal (tenant_id, period_id, kind, from_type_id, to_type_id, due_date)
    VALUES (vv_current_tenant(), r.id, 'aging_up', v_type.type_id, v_rule.successor_type_id, v_due)
    ON CONFLICT (tenant_id, period_id, kind, due_date) DO NOTHING
    RETURNING id INTO v_new;
    IF v_new IS NOT NULL THEN
      PERFORM vv_audit_write('m05.job.aging_up', v_new::text, jsonb_build_object('period_id', r.id, 'due', v_due), 'system:m05-job');
      PERFORM vv_outbox_emit('m05.aging_up.proposed', jsonb_build_object('proposal_id', v_new, 'period_id', r.id),
                             'm05.aging_up.proposed:' || v_new);
      n_prop := n_prop + 1;
    END IF;
  END LOOP;
  -- (4a) G-3: direkt (z. B. über vv_decide_approval) abgelehnte Anonymisierungsanträge -> Legal Hold
  FOR r IN SELECT q.period_id, q.approval_id, a.decided_at FROM m05_approval_request q JOIN approval a ON a.id = q.approval_id
            WHERE q.tenant_id = vv_current_tenant() AND q.effect_id = 'm05.membership.anonymize'
              AND q.closed_at IS NULL AND a.status = 'rejected'
            FOR UPDATE OF q SKIP LOCKED LOOP                              -- Review R2 (M-2): parallelfest
    PERFORM m05_apply_hold(r.period_id, r.approval_id, r.decided_at::date);
    n_hold := n_hold + 1;
  END LOOP;
  -- (4) Aufbewahrung abgelaufen -> Anonymisierungs-ANTRAG (Ausführung nur mit Vier-Augen)
  FOR r IN SELECT * FROM membership_period p WHERE p.tenant_id = vv_current_tenant() AND p.status = 'gesperrt'
              AND p.retention_until <= m05_today()
              AND NOT EXISTS (SELECT 1 FROM m05_approval_request q JOIN approval a ON a.id = q.approval_id
                               WHERE q.tenant_id = p.tenant_id AND q.period_id = p.id
                                 AND q.effect_id = 'm05.membership.anonymize' AND q.closed_at IS NULL
                                 AND a.status <> 'rejected' AND (a.expires_at IS NULL OR a.expires_at > now()))
            FOR UPDATE OF p SKIP LOCKED LOOP                              -- Review R2 (M-2): parallelfest
    -- Nachprüfung mit frischem Snapshot unter der Zeilensperre: hat ein paralleler Lauf den Antrag
    -- inzwischen angelegt (committet), wird übersprungen statt den ganzen Tageslauf abzubrechen.
    CONTINUE WHEN EXISTS (SELECT 1 FROM m05_approval_request q JOIN approval a ON a.id = q.approval_id
                           WHERE q.tenant_id = r.tenant_id AND q.period_id = r.id
                             AND q.effect_id = 'm05.membership.anonymize' AND q.closed_at IS NULL
                             AND a.status <> 'rejected' AND (a.expires_at IS NULL OR a.expires_at > now()));
    PERFORM m05_open_request(r.id, 'm05.membership.anonymize',
      jsonb_build_object('period_id', r.id, 'retention_until', r.retention_until), r.version, 'system:m05-retention', 'deletion');
    n_ret := n_ret + 1;
  END LOOP;
  RETURN jsonb_build_object('ended', n_end, 'locked', n_lock, 'aging_up_proposed', n_prop,
                            'aging_up_data_missing', n_miss, 'anonymize_requested', n_ret, 'retention_hold', n_hold);
END $$;

-- ---------------------------------------------------------------------------------------------
-- Import-Schnittstelle (P50-7) — Antrag (Web) + Anwendung (Worker, eingelöste Batch-Freigabe)
-- ---------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION m05_import_request(p_batch_ref text, p_rows_sha256 text, p_row_count integer)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_app uuid;
BEGIN
  IF NOT vv_authorize('membership', 'create', 'S') THEN PERFORM m05_deny('membership.create (import)'); END IF;
  INSERT INTO approval (tenant_id, kind, effect_id, subject_ref, requested_by, builder_model, context, expires_at)
  VALUES (vv_current_tenant(), 'external_pii', 'q05.import.commit', p_batch_ref, vv_actor(), 'human:manuell',
          jsonb_build_object('rows_sha256', p_rows_sha256, 'row_count', p_row_count), now() + interval '7 days')
  RETURNING id INTO v_app;
  INSERT INTO m05_import_batch (tenant_id, batch_ref, approval_id, requested_by, rows_sha256, row_count)
  VALUES (vv_current_tenant(), p_batch_ref, v_app, vv_actor(), p_rows_sha256, p_row_count);
  PERFORM vv_audit_write('m05.import.request', p_batch_ref,
    jsonb_build_object('approval_id', v_app, 'rows_sha256', p_rows_sha256, 'row_count', p_row_count));
  RETURN v_app;
END $$;

-- Import-Freigabe entscheiden (Vorstand/Obmann) — gleicher Pfad wie m05_decide, ohne Perioden-Bezug.
CREATE OR REPLACE FUNCTION m05_import_decide(p_batch_ref text, p_decision text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE b m05_import_batch;
BEGIN
  SELECT * INTO b FROM m05_import_batch WHERE tenant_id = vv_current_tenant() AND batch_ref = p_batch_ref
     AND applied_at IS NULL FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'M05: kein offener Import-Batch %', p_batch_ref; END IF;
  IF NOT vv_authorize('membership', 'approve', 'S') THEN PERFORM m05_deny('membership.approve (import)'); END IF;
  PERFORM vv_decide_approval(b.approval_id, p_decision, NULL);
  -- Reparaturrunde 1 (Gemini G-1): freigegebener Import bleibt nicht still liegen — Ereignis für den
  -- Worker-Consumer (wendet an, sobald die Q05-Engine die freigegebenen Zeilen liefert; sonst sichtbar DLQ).
  IF p_decision = 'approved' THEN
    PERFORM vv_outbox_emit('m05.import.approved', jsonb_build_object('batch_ref', p_batch_ref, 'approval_id', b.approval_id),
                           'm05.import.approved:' || p_batch_ref);
  END IF;
  PERFORM vv_audit_write('m05.import.decide', p_batch_ref, jsonb_build_object('decision', p_decision));
  RETURN jsonb_build_object('ok', true);
END $$;

CREATE OR REPLACE FUNCTION m05_import_apply(p_batch_ref text, p_rows jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE b m05_import_batch; a approval; s m05_settings := m05_settings_get(); v_consumed uuid;
        v_row jsonb; i int := 0; n_new int := 0; n_same int := 0; n_nogrund int := 0;
        conflicts jsonb := '[]'::jsonb; v_member member; v_period membership_period; v_type uuid;
        v_status text; v_entry date; v_exit date; v_kind text; v_reason text; v_pid uuid; v_rule membership_type_version;
        v_cur_type uuid; v_new_period uuid; v_err text; v_applied date;
BEGIN
  SELECT * INTO b FROM m05_import_batch WHERE tenant_id = vv_current_tenant() AND batch_ref = p_batch_ref FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'M05-Import: Batch % unbekannt (nur über m05_import_request)', p_batch_ref; END IF;
  IF b.applied_at IS NOT NULL THEN RETURN jsonb_build_object('ok', true, 'noop', true, 'report', b.report); END IF;
  SELECT * INTO a FROM approval WHERE tenant_id = vv_current_tenant() AND id = b.approval_id;
  IF a.requested_by <> b.requested_by OR a.effect_id <> 'q05.import.commit' OR a.subject_ref <> p_batch_ref
     OR a.context->>'rows_sha256' <> b.rows_sha256 THEN
    RAISE EXCEPTION 'M05-Import: Freigabe passt nicht zum Batch (Manipulation) — verweigert';
  END IF;
  IF encode(digest(convert_to(p_rows::text, 'UTF8'), 'sha256'), 'hex') <> b.rows_sha256
     OR jsonb_typeof(p_rows) <> 'array' OR jsonb_array_length(p_rows) <> b.row_count THEN
    RAISE EXCEPTION 'M05-Import: Zeilen weichen von den freigegebenen ab (Hash/Anzahl) — verweigert';
  END IF;
  IF a.approved_by IS NULL OR NOT vv_authorize_subject(a.approved_by, 'membership', 'approve', 'S') THEN
    RAISE EXCEPTION 'M05-Import: Freigeber nicht berechtigt — verweigert';
  END IF;
  v_consumed := vv_consume_approval('q05.import.commit', p_batch_ref);
  IF v_consumed IS DISTINCT FROM b.approval_id THEN
    RAISE EXCEPTION 'M05-Import: keine gültige, fremd-genehmigte Batch-Freigabe — verweigert';
  END IF;

  -- Reparaturrunde 1 (Gemini G-2): KEIN EXCEPTION-Block je Zeile mehr (1 Savepoint/Subtransaktion je
  -- Zeile belastete pg_subtrans bei bis zu 20.000 Zeilen). Fachliche Fehler werden per IF VOR dem
  -- Schreiben erkannt und als Konflikt gemeldet; ein UNERWARTETER DB-Fehler bricht den ganzen Batch
  -- ab (Rollback inkl. Freigabe-Consume -> nichts halb importiert, Freigabe bleibt unverbraucht).
  FOR v_row IN SELECT value FROM jsonb_array_elements(p_rows) LOOP
    i := i + 1;
    v_err := NULL;
    IF jsonb_typeof(v_row) <> 'object' THEN
      v_err := 'zeile_kein_objekt';
    ELSIF v_row->>'member_no' IS NULL OR (v_row->>'member_no') !~ '^[A-Za-z0-9._-]{1,32}$' THEN
      v_err := 'mitgliedsnummer_fehlt_oder_ungueltig';
    ELSIF NOT coalesce(pg_input_is_valid(v_row->>'person_id', 'uuid'), false) THEN
      v_err := 'person_id_ungueltig';
    ELSIF NOT coalesce(pg_input_is_valid(v_row->>'entry_date', 'date'), false) THEN
      v_err := 'eintrittsdatum_ungueltig';
    ELSIF nullif(v_row->>'exit_effective_date', '') IS NOT NULL
          AND NOT pg_input_is_valid(v_row->>'exit_effective_date', 'date') THEN
      v_err := 'austrittsdatum_ungueltig';
    ELSIF nullif(v_row->>'applied_on', '') IS NOT NULL AND NOT pg_input_is_valid(v_row->>'applied_on', 'date') THEN
      v_err := 'antragsdatum_ungueltig';
    ELSIF coalesce(v_row->>'status', '') NOT IN ('aktiv','ruhend','beendet') THEN
      v_err := 'pflichtfeld';
    END IF;
    IF v_err IS NULL THEN
      v_status := v_row->>'status';
      v_entry  := (v_row->>'entry_date')::date;
      v_exit   := nullif(v_row->>'exit_effective_date', '')::date;
      v_kind   := nullif(v_row->>'end_kind', '');
      v_reason := nullif(v_row->>'end_reason_code', '');
      v_pid    := (v_row->>'person_id')::uuid;
      v_applied := coalesce(nullif(v_row->>'applied_on', '')::date, v_entry);
      IF v_status = 'beendet' AND (v_exit IS NULL OR v_kind IS NULL OR v_kind NOT IN ('ausgetreten','verstorben')) THEN
        v_err := 'beendigung_unvollstaendig_oder_ausschluss';
      ELSIF v_status <> 'beendet' AND (v_exit IS NOT NULL OR v_kind IS NOT NULL) THEN
        v_err := 'austritt_bei_offener_mitgliedschaft';
      ELSIF v_exit IS NOT NULL AND v_exit < v_entry THEN
        v_err := 'austritt_vor_eintritt';
      ELSIF v_applied > v_entry THEN
        v_err := 'antrag_nach_eintritt';
      ELSIF v_reason IS NOT NULL AND (v_kind IS DISTINCT FROM 'ausgetreten' OR NOT EXISTS (
              SELECT 1 FROM membership_end_reason WHERE code = v_reason AND kind = 'austritt')) THEN
        v_err := 'austrittsgrund_ungueltig';
      ELSIF NOT EXISTS (SELECT 1 FROM person WHERE tenant_id = vv_current_tenant() AND id = v_pid) THEN
        v_err := 'person_unbekannt';
      END IF;
    END IF;
    IF v_err IS NULL THEN
      SELECT id INTO v_type FROM membership_type WHERE tenant_id = vv_current_tenant() AND code = v_row->>'type_code';
      IF v_type IS NULL THEN v_err := 'unbekannte_mitgliedsart'; END IF;
    END IF;
    IF v_err IS NULL THEN
      v_member := NULL;
      SELECT * INTO v_member FROM member WHERE tenant_id = vv_current_tenant() AND member_no = v_row->>'member_no' FOR UPDATE;
      IF v_member.id IS NOT NULL AND v_member.person_id IS DISTINCT FROM v_pid THEN
        v_err := 'mitgliedsnummer_andere_person';
      ELSIF v_member.id IS NULL AND EXISTS (SELECT 1 FROM member WHERE tenant_id = vv_current_tenant() AND person_id = v_pid) THEN
        v_err := 'person_andere_mitgliedsnummer';
      END IF;
    END IF;
    IF v_err IS NULL AND v_member.id IS NOT NULL THEN
      v_period := NULL;
      SELECT * INTO v_period FROM membership_period WHERE tenant_id = vv_current_tenant()
         AND member_id = v_member.id AND entry_date = v_entry;
      IF v_period.id IS NOT NULL THEN
        v_cur_type := (m05_current_type(v_period.id, m05_today())).type_id;
        IF v_period.status IN (v_status, CASE WHEN v_status = 'beendet' THEN 'gesperrt' END)
           AND v_period.exit_effective_date IS NOT DISTINCT FROM v_exit
           AND v_period.end_kind IS NOT DISTINCT FROM v_kind
           AND v_cur_type = v_type THEN
          n_same := n_same + 1;                                 -- idempotent: unverändert
          CONTINUE;
        END IF;
        v_err := 'abweichender_bestand';                        -- nie überschreiben
      ELSIF v_status <> 'beendet' AND EXISTS (SELECT 1 FROM membership_period WHERE tenant_id = vv_current_tenant()
              AND member_id = v_member.id AND status IN ('beantragt','aktiv','ruhend','gekuendigt')) THEN
        v_err := 'offene_periode_vorhanden';
      END IF;
    END IF;
    IF v_err IS NOT NULL THEN
      -- Konflikt/ungültige Zeile: gemeldet, NICHT übernommen (Zeilennummer + Code, kein Klartext).
      conflicts := conflicts || jsonb_build_object('zeile', i, 'code', v_err);
      CONTINUE;
    END IF;

    IF v_member.id IS NULL THEN
      INSERT INTO member (tenant_id, person_id, member_no) VALUES (vv_current_tenant(), v_pid, v_row->>'member_no')
      RETURNING * INTO v_member;
    END IF;
    PERFORM m05_ctx('import', 'system:m05-import', v_entry, b.approval_id);
    INSERT INTO membership_period (tenant_id, member_id, status, applied_on, entry_date, exit_effective_date,
                                   end_kind, end_reason_code, retention_until, source, import_batch)
    VALUES (vv_current_tenant(), v_member.id, v_status, v_applied, v_entry, v_exit, v_kind, v_reason,
            CASE WHEN v_status = 'beendet' THEN (v_exit + make_interval(years => s.retention_years))::date END,
            'import', p_batch_ref)
    RETURNING id INTO v_new_period;
    v_rule := m05_type_rule(v_type, v_entry);
    INSERT INTO membership_type_assignment (tenant_id, period_id, type_id, type_version, effective_from, actor, source)
    VALUES (vv_current_tenant(), v_new_period, v_type, v_rule.version, v_entry, 'system:m05-import', 'import');
    PERFORM m05_emit('m05.membership.imported', v_new_period, jsonb_build_object('status', v_status, 'batch', p_batch_ref));
    IF v_status = 'beendet' AND v_reason IS NULL AND v_kind = 'ausgetreten' THEN n_nogrund := n_nogrund + 1; END IF;
    n_new := n_new + 1;
  END LOOP;

  UPDATE m05_import_batch SET applied_at = now(),
         report = jsonb_build_object('neu', n_new, 'unveraendert', n_same, 'ohne_grund', n_nogrund,
                                     'konflikte', conflicts)
   WHERE tenant_id = vv_current_tenant() AND batch_ref = p_batch_ref;
  PERFORM vv_audit_write('m05.import.apply', p_batch_ref,
    jsonb_build_object('neu', n_new, 'unveraendert', n_same, 'konflikte', jsonb_array_length(conflicts),
                       'approval_id', b.approval_id, 'approved_by', a.approved_by), 'system:m05-import');
  RETURN jsonb_build_object('ok', true, 'neu', n_new, 'unveraendert', n_same, 'ohne_grund', n_nogrund, 'konflikte', conflicts);
END $$;

-- ---------------------------------------------------------------------------------------------
-- Lesen: datenklassen- und scope-gefilterte Sicht (Feldsicht, P50-5/13) — Spalten ohne Recht = NULL
-- ---------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION m05_member_rows(p_include_locked boolean, p_mode text)
RETURNS TABLE (member_id uuid, period_id uuid, person_id uuid, last_name text, first_name text,
               type_code text, type_name text, category text, member_no text, status text,
               entry_date date, exit_effective_date date, end_kind text, end_reason_code text,
               exclusion_reason_code text, resolution_ref text, period_version integer, visible_classes text[])
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE x record; v_scopes uuid[]; oe boolean; s boolean; se boolean; v_t membership_type_assignment;
        v_act text := CASE WHEN p_mode = 'export' THEN 'export' ELSE 'read' END;
BEGIN
  FOR x IN SELECT DISTINCT ON (m.id) m.id AS mid, m.person_id AS pid, m.member_no AS mno,
                  per.last_name, per.first_name, p.*
             FROM member m
             JOIN person per ON per.tenant_id = m.tenant_id AND per.id = m.person_id
             JOIN membership_period p ON p.tenant_id = m.tenant_id AND p.member_id = m.id
            WHERE m.tenant_id = vv_current_tenant() AND m.anonymized_at IS NULL
              AND p.status <> 'anonymisiert'
            ORDER BY m.id, p.applied_on DESC, p.updated_at DESC LOOP
    CONTINUE WHEN x.status = 'gesperrt' AND NOT p_include_locked;
    v_scopes := vv_person_scopes(x.pid);
    oe := vv_authorize('membership', v_act, 'Oe', v_scopes, x.pid);
    CONTINUE WHEN NOT oe;
    s  := vv_authorize('membership', v_act, 'S', v_scopes, x.pid);
    se := p_mode = 'read' AND vv_authorize('membership', 'read', 'Se', v_scopes, x.pid);
    -- gesperrte Perioden (Art. 18) nur mit S-Recht sichtbar
    CONTINUE WHEN x.status = 'gesperrt' AND NOT s;
    v_t := m05_current_type(x.id, m05_today());
    member_id := x.mid; period_id := x.id; person_id := x.pid;
    last_name := x.last_name; first_name := x.first_name;
    SELECT t.code, t.name, t.category_code INTO type_code, type_name, category
      FROM membership_type t WHERE t.tenant_id = vv_current_tenant() AND t.id = v_t.type_id;
    member_no := CASE WHEN s THEN x.mno END;
    status := CASE WHEN s THEN x.status END;
    entry_date := CASE WHEN s THEN x.entry_date END;
    exit_effective_date := CASE WHEN s THEN x.exit_effective_date END;
    end_kind := CASE WHEN s THEN x.end_kind END;
    end_reason_code := CASE WHEN s THEN x.end_reason_code END;
    exclusion_reason_code := CASE WHEN se THEN x.exclusion_reason_code END;
    resolution_ref := CASE WHEN se THEN x.resolution_ref END;
    period_version := CASE WHEN s THEN x.version END;
    visible_classes := array_remove(ARRAY[CASE WHEN oe THEN 'Oe' END, CASE WHEN s THEN 'S' END,
                                          CASE WHEN se THEN 'Se' END], NULL);
    RETURN NEXT;
  END LOOP;
END $$;

CREATE OR REPLACE FUNCTION m05_list_members(p_include_locked boolean DEFAULT false, p_purpose text DEFAULT NULL)
RETURNS TABLE (member_id uuid, period_id uuid, person_id uuid, last_name text, first_name text,
               type_code text, type_name text, category text, member_no text, status text,
               entry_date date, exit_effective_date date, end_kind text, end_reason_code text,
               exclusion_reason_code text, resolution_ref text, period_version integer, visible_classes text[])
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE n int;
BEGIN
  IF NOT vv_policy_any('membership', 'read', 'Oe') THEN PERFORM m05_deny('membership.read'); END IF;
  IF p_include_locked THEN
    IF p_purpose IS NULL OR length(trim(p_purpose)) < 10 THEN
      RAISE EXCEPTION 'M05: gesperrte Daten nur mit Zweckangabe (mind. 10 Zeichen)';
    END IF;
    IF NOT vv_policy_any('membership', 'export', 'S') THEN PERFORM m05_deny('membership.read (gesperrt)'); END IF;
  END IF;
  RETURN QUERY SELECT * FROM m05_member_rows(p_include_locked, 'read');
  GET DIAGNOSTICS n = ROW_COUNT;
  PERFORM vv_audit_write('m05.list', NULL, jsonb_build_object('rows', n, 'include_locked', p_include_locked,
                                                              'purpose', p_purpose));
END $$;

-- Export: eigene Aktion (P50-5) — Pflicht-Zweck, nie Se, protokolliert.
CREATE OR REPLACE FUNCTION m05_export_members(p_purpose text, p_include_locked boolean DEFAULT false)
RETURNS TABLE (member_id uuid, period_id uuid, person_id uuid, last_name text, first_name text,
               type_code text, type_name text, category text, member_no text, status text,
               entry_date date, exit_effective_date date, end_kind text, end_reason_code text,
               exclusion_reason_code text, resolution_ref text, period_version integer, visible_classes text[])
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE n int;
BEGIN
  IF NOT vv_policy_any('membership', 'export', 'Oe') THEN PERFORM m05_deny('membership.export'); END IF;
  IF p_purpose IS NULL OR length(trim(p_purpose)) < 10 THEN
    RAISE EXCEPTION 'M05: Export nur mit Zweckangabe (mind. 10 Zeichen)';
  END IF;
  RETURN QUERY SELECT * FROM m05_member_rows(p_include_locked, 'export');
  GET DIAGNOSTICS n = ROW_COUNT;
  PERFORM vv_audit_write('m05.export', NULL, jsonb_build_object('rows', n, 'purpose', p_purpose,
                                                                'include_locked', p_include_locked));
  PERFORM vv_outbox_emit('m05.export.done', jsonb_build_object('rows', n), 'm05.export:' || gen_random_uuid());
END $$;

-- Detail eines Mitglieds inkl. Verlauf (Feldsicht wie Liste).
CREATE OR REPLACE FUNCTION m05_get_member(p_member uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_person uuid; v_scopes uuid[]; s boolean; se boolean; v jsonb;
BEGIN
  SELECT person_id INTO v_person FROM member WHERE tenant_id = vv_current_tenant() AND id = p_member AND anonymized_at IS NULL;
  IF v_person IS NULL THEN RAISE EXCEPTION 'M05: Mitglied nicht gefunden' USING ERRCODE = 'P0002'; END IF;
  v_scopes := vv_person_scopes(v_person);
  IF NOT vv_authorize('membership', 'read', 'Oe', v_scopes, v_person) THEN PERFORM m05_deny('membership.read'); END IF;
  s  := vv_authorize('membership', 'read', 'S', v_scopes, v_person);
  se := vv_authorize('membership', 'read', 'Se', v_scopes, v_person);
  SELECT jsonb_build_object(
    'member_id', p_member,
    'member_no', CASE WHEN s THEN (SELECT member_no FROM member WHERE tenant_id = vv_current_tenant() AND id = p_member) END,
    'periods', coalesce(jsonb_agg(jsonb_build_object(
        'period_id', p.id,
        'status', CASE WHEN s THEN p.status END,
        'entry_date', CASE WHEN s THEN p.entry_date END,
        'exit_effective_date', CASE WHEN s THEN p.exit_effective_date END,
        'end_kind', CASE WHEN s THEN p.end_kind END,
        'end_reason_code', CASE WHEN s THEN p.end_reason_code END,
        'exclusion_reason_code', CASE WHEN se THEN p.exclusion_reason_code END,
        'resolution_ref', CASE WHEN se THEN p.resolution_ref END,
        'version', CASE WHEN s THEN p.version END,
        'status_history', CASE WHEN s THEN (SELECT jsonb_agg(jsonb_build_object('from', h.from_status, 'to', h.to_status,
                 'effective', h.effective_date, 'recorded_at', h.recorded_at) ORDER BY h.id)
                 FROM membership_status_history h WHERE h.tenant_id = p.tenant_id AND h.period_id = p.id) END,
        'type_history', (SELECT jsonb_agg(jsonb_build_object('type_id', a.type_id, 'version', a.type_version,
                 'effective_from', a.effective_from, 'source', a.source) ORDER BY a.id)
                 FROM membership_type_assignment a WHERE a.tenant_id = p.tenant_id AND a.period_id = p.id),
        'open_proposals', CASE WHEN s THEN (SELECT jsonb_agg(jsonb_build_object('proposal_id', pr.id,
                 'to_type_id', pr.to_type_id, 'due_date', pr.due_date))
                 FROM membership_proposal pr WHERE pr.tenant_id = p.tenant_id AND pr.period_id = p.id AND pr.status = 'offen') END
      ) ORDER BY p.applied_on), '[]'::jsonb),
    'visible_classes', to_jsonb(array_remove(ARRAY['Oe', CASE WHEN s THEN 'S' END, CASE WHEN se THEN 'Se' END], NULL)))
  INTO v
  FROM membership_period p
  WHERE p.tenant_id = vv_current_tenant() AND p.member_id = p_member
    AND p.status NOT IN ('anonymisiert', 'gesperrt');   -- Art. 18: gesperrt nur mit Zweck (Liste/Export)
  PERFORM vv_audit_write('m05.member.read', p_member::text, '{}'::jsonb);
  RETURN v;
END $$;

-- ---------------------------------------------------------------------------------------------
-- Eigentümer + Grants. Neue Funktionen: PUBLIC entziehen, Eigentümer vv_definer, gezielt vergeben.
-- ---------------------------------------------------------------------------------------------
DO $$
DECLARE f record;
BEGIN
  FOR f IN SELECT p.oid::regprocedure AS sig, p.proname FROM pg_proc p
             JOIN pg_namespace n ON n.oid = p.pronamespace AND n.nspname = 'public'
            WHERE p.proname LIKE 'm05\_%' AND p.proname NOT IN ('m05_append_only','m05_period_guard','m05_period_history')
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', f.sig);
    EXECUTE format('ALTER FUNCTION %s OWNER TO vv_definer', f.sig);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO vv_definer', f.sig);
  END LOOP;
END $$;

-- Stage-0-Freigabefunktionen, die die Fachschicht (als vv_definer) aufruft.
GRANT EXECUTE ON FUNCTION vv_decide_approval(uuid, text, text) TO vv_definer;
GRANT EXECUTE ON FUNCTION vv_consume_approval(text, text) TO vv_definer;

-- Web (vv_app): geprüfte Befehle + gefilterte Lesesicht.
GRANT EXECUTE ON FUNCTION
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

-- Worker (vv_worker): NUR Ausführung eingelöster Freigaben, Tagesjob, Import-Anwendung.
GRANT EXECUTE ON FUNCTION m05_execute(uuid), m05_job_daily(), m05_import_apply(text, jsonb) TO vv_worker;
GRANT SELECT (id) ON tenant TO vv_worker;

COMMIT;
