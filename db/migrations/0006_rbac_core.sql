-- VV Migration 0006 — BASIS-02-Kern: Rollen × Scope × Datenklasse (mit M05 gebaut, Register P50-8)
-- Ersetzt die statische Stage-0-Allowlist durch eine DATENGETRIEBENE, DB-seitig erzwungene
-- Rechteprüfung (deny-by-default, ADR-04). Idempotent (mehrfach ausführbar), atomar (BEGIN/COMMIT).
--
-- Sicherheitsarchitektur:
--  * vv_definer = NOLOGIN, NOSUPERUSER, NOBYPASSRLS. Besitzt die SECURITY-DEFINER-Fachfunktionen.
--    Weil vv_definer RLS NICHT umgehen kann (und die Tabellen FORCE RLS tragen), gilt die
--    Mandantentrennung auch INNERHALB der Definer-Funktionen (kein Superuser-Definer für Fachlogik).
--  * vv_app verliert direktes DML auf role_assignment (sonst könnte eine kompromittierte Web-Schicht
--    sich selbst jede Rolle geben). Zuweisungen laufen nur über rbac_* -Funktionen mit Prüfung.
--  * Die Identität (app.actor = OIDC-sub) wird über principal_link an eine Person gebunden; diese
--    Bindung darf nur der Betreiber-Onboarding-Pfad (Bootstrap) setzen, nicht die App.

BEGIN;
SET LOCAL client_min_messages = warning;

-- ---------------------------------------------------------------------------------------------
-- Definer-Rolle
-- ---------------------------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'vv_definer') THEN
    CREATE ROLE vv_definer NOLOGIN NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE NOREPLICATION;
  ELSE
    ALTER ROLE vv_definer NOLOGIN NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE NOREPLICATION;
  END IF;
END $$;
GRANT USAGE ON SCHEMA public TO vv_definer;

-- ---------------------------------------------------------------------------------------------
-- Globale System-Kataloge (seed, versioniert, NICHT mandantenbezogen, für die App nur lesbar)
-- ---------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS role_type (
    code          text PRIMARY KEY CHECK (code ~ '^[a-z_]{3,40}$'),
    name          text NOT NULL,
    mfa_required  boolean NOT NULL DEFAULT true,     -- B10-2
    is_system     boolean NOT NULL DEFAULT true,
    version       integer NOT NULL DEFAULT 1
);

CREATE TABLE IF NOT EXISTS role_permission (
    role_code   text NOT NULL REFERENCES role_type(code),
    resource    text NOT NULL,
    action      text NOT NULL CHECK (action IN ('read','create','update','deactivate','export','approve')),
    data_class  text NOT NULL CHECK (data_class IN ('Oe','S','Se','F-Buch','F-Bank','A9')),
    scope_mode  text NOT NULL CHECK (scope_mode IN ('scope','self')),
    PRIMARY KEY (role_code, resource, action, data_class, scope_mode)
);

-- SoD-Kern-Katalog (B02-1) — EINE Quelle, nicht abwählbar.
CREATE TABLE IF NOT EXISTS sod_rule (
    role_a  text NOT NULL REFERENCES role_type(code),
    role_b  text NOT NULL REFERENCES role_type(code),
    reason  text NOT NULL,
    PRIMARY KEY (role_a, role_b),
    CONSTRAINT sod_rule_order_ck CHECK (role_a < role_b)
);

-- ---------------------------------------------------------------------------------------------
-- Mandantenbezogen: Scope-Baum, Principal-Bindung
-- ---------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS scope_node (
    id          uuid NOT NULL DEFAULT gen_random_uuid(),
    tenant_id   uuid NOT NULL REFERENCES tenant(id),
    parent_id   uuid,
    kind        text NOT NULL CHECK (kind IN ('verein','abteilung','mannschaft')),
    name        text NOT NULL CHECK (length(name) BETWEEN 1 AND 120),
    created_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (id),
    CONSTRAINT scope_node_tenant_uk UNIQUE (tenant_id, id),
    CONSTRAINT scope_node_parent_fk FOREIGN KEY (tenant_id, parent_id) REFERENCES scope_node (tenant_id, id),
    CONSTRAINT scope_node_root_ck CHECK ((parent_id IS NULL) = (kind = 'verein'))
);
CREATE UNIQUE INDEX IF NOT EXISTS scope_node_one_root ON scope_node (tenant_id) WHERE parent_id IS NULL;
ALTER TABLE scope_node ENABLE ROW LEVEL SECURITY;
ALTER TABLE scope_node FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS scope_node_tenant_isolation ON scope_node;
CREATE POLICY scope_node_tenant_isolation ON scope_node
    USING (tenant_id = vv_current_tenant())
    WITH CHECK (tenant_id = vv_current_tenant());

-- OIDC-Subjekt -> Person (je Mandant). Setzt NUR der Betreiber-Onboarding-Pfad (BASIS-10-Anker).
CREATE TABLE IF NOT EXISTS principal_link (
    tenant_id   uuid NOT NULL REFERENCES tenant(id),
    subject     text NOT NULL CHECK (length(subject) BETWEEN 1 AND 255 AND subject !~ '^system:'),
    person_id   uuid NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, subject),
    CONSTRAINT principal_link_person_uk UNIQUE (tenant_id, person_id),
    CONSTRAINT principal_link_person_fk FOREIGN KEY (tenant_id, person_id) REFERENCES person (tenant_id, id)
);
ALTER TABLE principal_link ENABLE ROW LEVEL SECURITY;
ALTER TABLE principal_link FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS principal_link_tenant_isolation ON principal_link;
CREATE POLICY principal_link_tenant_isolation ON principal_link
    USING (tenant_id = vv_current_tenant())
    WITH CHECK (tenant_id = vv_current_tenant());

-- role_assignment (Stage 0) um echten Scope-Knoten, Rollentyp-FK und Widerruf erweitern.
ALTER TABLE role_assignment ADD COLUMN IF NOT EXISTS scope_node_id uuid;
ALTER TABLE role_assignment ADD COLUMN IF NOT EXISTS assigned_by  text;
ALTER TABLE role_assignment ADD COLUMN IF NOT EXISTS revoked_at   timestamptz;
ALTER TABLE role_assignment ADD COLUMN IF NOT EXISTS revoked_by   text;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'role_assignment_scope_fk') THEN
    ALTER TABLE role_assignment ADD CONSTRAINT role_assignment_scope_fk
      FOREIGN KEY (tenant_id, scope_node_id) REFERENCES scope_node (tenant_id, id);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'role_assignment_role_fk') THEN
    ALTER TABLE role_assignment ADD CONSTRAINT role_assignment_role_fk
      FOREIGN KEY (role_type) REFERENCES role_type (code);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'role_assignment_validity_ck') THEN
    ALTER TABLE role_assignment ADD CONSTRAINT role_assignment_validity_ck
      CHECK (valid_to IS NULL OR valid_to > valid_from);
  END IF;
  -- Neue Zuweisungen brauchen einen echten Scope-Knoten (Stage-0-Textspalte ist nur Altlast).
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'role_assignment_scope_req_ck') THEN
    ALTER TABLE role_assignment ADD CONSTRAINT role_assignment_scope_req_ck
      CHECK (scope_node_id IS NOT NULL) NOT VALID;
  END IF;
END $$;
CREATE UNIQUE INDEX IF NOT EXISTS role_assignment_tenant_uk ON role_assignment (tenant_id, id);

-- ---------------------------------------------------------------------------------------------
-- Seed: Systemrollen + Rechteprofile (BASIS-02-Default-Matrix, M05-Ausschnitt, P50-5/12/13)
-- ---------------------------------------------------------------------------------------------
INSERT INTO role_type (code, name, mfa_required) VALUES
  ('mandanten_admin',      'Mandanten-Admin',               true),
  ('vorstand',             'Vorstand',                      true),
  ('obmann',               'Obmann/Obfrau',                 true),
  ('kassier',              'Kassier',                       true),
  ('kassapruefer',         'Kassaprüfer',                   true),
  ('schriftfuehrer',       'Schriftführer',                 true),
  ('kinderschutz',         'Kinderschutzbeauftragte/r',     true),
  ('trainer',              'Trainer',                       true),
  ('betreuer',             'Betreuer',                      true),
  ('spieler',              'Spieler/Sportler',              false),
  ('mitglied',             'Mitglied',                      false),
  ('erziehungsberechtigt', 'Erziehungsberechtigte/r',       false)
ON CONFLICT (code) DO NOTHING;

INSERT INTO sod_rule (role_a, role_b, reason) VALUES
  ('kassapruefer', 'kassier',         'B02-1 (1): Kassier ≠ Kassaprüfer'),
  ('kassapruefer', 'vorstand',        'B02-1 (2): Kassaprüfer ≠ Vorstand'),
  ('kassapruefer', 'obmann',          'B02-1 (2): Kassaprüfer ≠ Obmann'),
  ('kassapruefer', 'mandanten_admin', 'B02-1 (3): Kassaprüfer ≠ Mandanten-Admin')
ON CONFLICT (role_a, role_b) DO NOTHING;

-- Rechteprofile: (Rolle, Ressource, Aktion, Datenklasse, scope|self). Leer = kein Zugriff.
INSERT INTO role_permission (role_code, resource, action, data_class, scope_mode)
SELECT r, res, a, dc, sm FROM (VALUES
  -- Mitgliedschaft lesen (Feldsicht)
  ('mandanten_admin','membership','read','Oe','scope'), ('mandanten_admin','membership','read','S','scope'),
  ('vorstand','membership','read','Oe','scope'),        ('vorstand','membership','read','S','scope'),
  ('vorstand','membership','read','Se','scope'),
  ('obmann','membership','read','Oe','scope'),          ('obmann','membership','read','S','scope'),
  ('obmann','membership','read','Se','scope'),
  ('kassier','membership','read','Oe','scope'),         ('kassier','membership','read','S','scope'),
  ('kassapruefer','membership','read','Oe','scope'),    ('kassapruefer','membership','read','S','scope'),
  ('schriftfuehrer','membership','read','Oe','scope'),  ('schriftfuehrer','membership','read','S','scope'),
  ('kinderschutz','membership','read','Oe','scope'),    ('kinderschutz','membership','read','S','scope'),
  ('kinderschutz','membership','read','Se','scope'),
  ('trainer','membership','read','Oe','scope'),         ('trainer','membership','read','S','scope'),
  ('betreuer','membership','read','Oe','scope'),
  ('betreuer','membership','read','Oe','self'),         ('betreuer','membership','read','S','self'),
  ('spieler','membership','read','Oe','scope'),
  ('spieler','membership','read','Oe','self'),          ('spieler','membership','read','S','self'),
  ('mitglied','membership','read','Oe','scope'),
  ('mitglied','membership','read','Oe','self'),         ('mitglied','membership','read','S','self'),
  -- Mitgliederverwaltung (P50-12): Schriftführer, Obmann, Mandanten-Admin
  ('schriftfuehrer','membership','create','S','scope'), ('schriftfuehrer','membership','update','S','scope'),
  ('schriftfuehrer','membership','deactivate','S','scope'),
  ('obmann','membership','create','S','scope'),         ('obmann','membership','update','S','scope'),
  ('obmann','membership','deactivate','S','scope'),     ('obmann','membership','deactivate','Se','scope'),
  ('mandanten_admin','membership','create','S','scope'),('mandanten_admin','membership','update','S','scope'),
  ('mandanten_admin','membership','deactivate','S','scope'),
  -- Freigabe (Beendigung/Anonymisierung): Vorstand, Obmann — nie der eigene Antrag (DB-SoD)
  ('vorstand','membership','approve','S','scope'),      ('obmann','membership','approve','S','scope'),
  -- Export (P50-5): Vorstand, Obmann, Schriftführer, Kassaprüfer (lesend) — nie Se
  ('vorstand','membership','export','Oe','scope'),      ('vorstand','membership','export','S','scope'),
  ('obmann','membership','export','Oe','scope'),        ('obmann','membership','export','S','scope'),
  ('schriftfuehrer','membership','export','Oe','scope'),('schriftfuehrer','membership','export','S','scope'),
  ('kassapruefer','membership','export','Oe','scope'),  ('kassapruefer','membership','export','S','scope'),
  -- Mitgliedsarten-Konfiguration (Ö): Mandanten-Admin; lesen alle Verwaltungs-/Leserollen
  ('mandanten_admin','membership_type','create','Oe','scope'), ('mandanten_admin','membership_type','update','Oe','scope'),
  ('mandanten_admin','membership_type','read','Oe','scope'),   ('schriftfuehrer','membership_type','read','Oe','scope'),
  ('obmann','membership_type','read','Oe','scope'),            ('vorstand','membership_type','read','Oe','scope'),
  ('kassier','membership_type','read','Oe','scope'),           ('kassapruefer','membership_type','read','Oe','scope'),
  -- BASIS-02-Verwaltung: Rollen & Zuweisungen, Scope-Baum (Mandanten-Admin)
  ('mandanten_admin','role_assignment','read','Oe','scope'),   ('mandanten_admin','role_assignment','create','Oe','scope'),
  ('mandanten_admin','role_assignment','deactivate','Oe','scope'),
  ('mandanten_admin','scope_node','create','Oe','scope'),      ('mandanten_admin','scope_node','read','Oe','scope'),
  ('kassapruefer','role_assignment','read','Oe','scope'),
  -- Stage-0-Demo-Aktionen (person.read) bleiben für Verwaltungsrollen erreichbar
  ('mandanten_admin','person','read','S','scope'), ('schriftfuehrer','person','read','S','scope'),
  ('obmann','person','read','S','scope'),          ('vorstand','person','read','S','scope')
) AS v(r, res, a, dc, sm)
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------------------------------
-- Plattform-Helfer (Actor, Audit, Outbox) — von der Fachschicht genutzt
-- ---------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION vv_actor() RETURNS text
LANGUAGE sql STABLE AS $$
  SELECT nullif(current_setting('app.actor', true), '')
$$;

-- Audit-Eintrag in derselben Transaktion (Hash-Kette setzt der Trigger aus 0003).
CREATE OR REPLACE FUNCTION vv_audit_write(p_action text, p_subject text, p_payload jsonb, p_actor text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_actor text := coalesce(p_actor, vv_actor());
BEGIN
  IF vv_current_tenant() IS NULL THEN RAISE EXCEPTION 'vv_audit_write: kein Mandantenkontext (deny-by-default)'; END IF;
  IF v_actor IS NULL THEN RAISE EXCEPTION 'vv_audit_write: kein Actor (deny-by-default)'; END IF;
  INSERT INTO audit_log (tenant_id, actor, action, subject_ref, payload)
  VALUES (vv_current_tenant(), v_actor, p_action, p_subject, coalesce(p_payload, '{}'::jsonb));
END $$;

-- Outbox-Event in derselben Transaktion (idempotent je Schlüssel).
CREATE OR REPLACE FUNCTION vv_outbox_emit(p_topic text, p_payload jsonb, p_key text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  IF vv_current_tenant() IS NULL THEN RAISE EXCEPTION 'vv_outbox_emit: kein Mandantenkontext'; END IF;
  INSERT INTO outbox (tenant_id, topic, payload, idempotency_key)
  VALUES (vv_current_tenant(), p_topic, p_payload, p_key)
  ON CONFLICT (tenant_id, idempotency_key) DO NOTHING;
END $$;

-- ---------------------------------------------------------------------------------------------
-- Autorisierung (DB-seitig, deny-by-default)
-- ---------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION vv_subject_person(p_subject text) RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT person_id FROM principal_link
   WHERE tenant_id = vv_current_tenant() AND subject = p_subject
$$;

CREATE OR REPLACE FUNCTION vv_actor_person() RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT vv_subject_person(vv_actor())
$$;

CREATE OR REPLACE FUNCTION vv_scope_root() RETURNS uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT id FROM scope_node WHERE tenant_id = vv_current_tenant() AND parent_id IS NULL
$$;

-- Vorfahren inkl. Knoten selbst (Tiefe begrenzt -> kein Endlos-Rekursions-DoS).
CREATE OR REPLACE FUNCTION vv_scope_ancestors(p_node uuid) RETURNS SETOF uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  WITH RECURSIVE a(id, parent_id, depth) AS (
    SELECT id, parent_id, 0 FROM scope_node WHERE id = p_node AND tenant_id = vv_current_tenant()
    UNION ALL
    SELECT s.id, s.parent_id, a.depth + 1
      FROM scope_node s JOIN a ON s.id = a.parent_id
     WHERE s.tenant_id = vv_current_tenant() AND a.depth < 32
  )
  SELECT id FROM a
$$;

-- Aktive Zuweisung?
CREATE OR REPLACE FUNCTION vv_assignment_active(p_from timestamptz, p_to timestamptz, p_revoked timestamptz)
RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT p_revoked IS NULL AND p_from <= now() AND (p_to IS NULL OR p_to > now())
$$;

-- Kern: Hat SUBJEKT das Recht (resource, action, data_class) an EINEM der Ziel-Scopes
-- (Rolle am Vorfahren-oder-selbst-Knoten wirkt nach unten) bzw. 'self' auf die Ziel-Person?
CREATE OR REPLACE FUNCTION vv_authorize_subject(
    p_subject text, p_resource text, p_action text, p_data_class text,
    p_target_scopes uuid[] DEFAULT NULL, p_target_person uuid DEFAULT NULL)
RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_person uuid; v_scopes uuid[];
BEGIN
  IF vv_current_tenant() IS NULL OR p_subject IS NULL OR p_subject LIKE 'system:%' THEN
    RETURN false;                                   -- deny-by-default; Systemakteure haben keine Rollen
  END IF;
  v_person := vv_subject_person(p_subject);
  IF v_person IS NULL THEN RETURN false; END IF;
  -- 'self': eigene Daten
  IF p_target_person IS NOT NULL AND p_target_person = v_person AND EXISTS (
       SELECT 1 FROM role_assignment ra
         JOIN role_permission rp ON rp.role_code = ra.role_type
        WHERE ra.tenant_id = vv_current_tenant() AND ra.person_id = v_person
          AND vv_assignment_active(ra.valid_from, ra.valid_to, ra.revoked_at)
          AND rp.resource = p_resource AND rp.action = p_action
          AND rp.data_class = p_data_class AND rp.scope_mode = 'self') THEN
    RETURN true;
  END IF;
  v_scopes := coalesce(p_target_scopes, ARRAY[vv_scope_root()]);
  RETURN EXISTS (
    SELECT 1 FROM role_assignment ra
      JOIN role_permission rp ON rp.role_code = ra.role_type
     WHERE ra.tenant_id = vv_current_tenant() AND ra.person_id = v_person
       AND vv_assignment_active(ra.valid_from, ra.valid_to, ra.revoked_at)
       AND rp.resource = p_resource AND rp.action = p_action
       AND rp.data_class = p_data_class AND rp.scope_mode = 'scope'
       AND EXISTS (SELECT 1 FROM unnest(v_scopes) t(scope)
                    WHERE ra.scope_node_id IN (SELECT vv_scope_ancestors(t.scope))));
END $$;

CREATE OR REPLACE FUNCTION vv_authorize(
    p_resource text, p_action text, p_data_class text,
    p_target_scopes uuid[] DEFAULT NULL, p_target_person uuid DEFAULT NULL)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT vv_authorize_subject(vv_actor(), p_resource, p_action, p_data_class, p_target_scopes, p_target_person)
$$;

-- Grober App-Prüfpunkt (checkPolicy): hält der Actor das Recht IRGENDWO (Scope oder self)?
-- Die feingranulare Entscheidung je Objekt trifft die Fachfunktion (Defense-in-Depth).
CREATE OR REPLACE FUNCTION vv_policy_any(p_resource text, p_action text, p_data_class text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT vv_current_tenant() IS NOT NULL AND vv_actor() IS NOT NULL AND vv_actor() NOT LIKE 'system:%'
     AND EXISTS (
       SELECT 1 FROM role_assignment ra
         JOIN role_permission rp ON rp.role_code = ra.role_type
        WHERE ra.tenant_id = vv_current_tenant() AND ra.person_id = vv_actor_person()
          AND vv_assignment_active(ra.valid_from, ra.valid_to, ra.revoked_at)
          AND rp.resource = p_resource AND rp.action = p_action AND rp.data_class = p_data_class)
$$;

-- Scopes, zu denen eine Person gehört: Vereins-Wurzel + Knoten ihrer aktiven Zuweisungen
-- (z. B. Spieler in Mannschaft X) -> Trainer von X sieht sie, Trainer von Y nicht.
CREATE OR REPLACE FUNCTION vv_person_scopes(p_person uuid) RETURNS uuid[]
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT array_remove(ARRAY[vv_scope_root()] || coalesce(array_agg(DISTINCT ra.scope_node_id), '{}'), NULL)
    FROM role_assignment ra
   WHERE ra.tenant_id = vv_current_tenant() AND ra.person_id = p_person
     AND vv_assignment_active(ra.valid_from, ra.valid_to, ra.revoked_at)
$$;

-- ---------------------------------------------------------------------------------------------
-- SoD-Kern bei Zuweisung (B02-1) — harter DB-Backstop (Trigger) + serialisiert je Person
-- ---------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION vv_sod_conflict(p_person uuid, p_role text, p_from timestamptz,
                                           p_to timestamptz, p_exclude uuid)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT ra.role_type FROM role_assignment ra
    JOIN sod_rule s ON (s.role_a = p_role AND s.role_b = ra.role_type)
                    OR (s.role_b = p_role AND s.role_a = ra.role_type)
   WHERE ra.tenant_id = vv_current_tenant() AND ra.person_id = p_person
     AND ra.revoked_at IS NULL
     AND ra.id IS DISTINCT FROM p_exclude
     AND tstzrange(ra.valid_from, coalesce(ra.valid_to, 'infinity'))
         && tstzrange(p_from, coalesce(p_to, 'infinity'))
   LIMIT 1
$$;

CREATE OR REPLACE FUNCTION vv_role_assignment_guard() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_conflict text;
BEGIN
  IF TG_OP = 'UPDATE' THEN
    -- Nur Widerruf ist als Änderung erlaubt (keine Umdeutung bestehender Zuweisungen).
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
DROP TRIGGER IF EXISTS role_assignment_sod ON role_assignment;
CREATE TRIGGER role_assignment_sod BEFORE INSERT OR UPDATE ON role_assignment
  FOR EACH ROW EXECUTE FUNCTION vv_role_assignment_guard();

-- ---------------------------------------------------------------------------------------------
-- BASIS-02-Befehle (App ruft nur diese; kein direktes DML)
-- ---------------------------------------------------------------------------------------------
-- Rolle zuweisen. Prüft: Recht des Actors, keine Selbst-Zuweisung, SoD (versuchte Verletzung wird
-- AUDITIERT und als Ergebnis zurückgegeben statt geworfen -> der Audit-Eintrag bleibt bestehen).
CREATE OR REPLACE FUNCTION rbac_assign_role(p_person uuid, p_role text, p_scope uuid,
                                            p_valid_from timestamptz DEFAULT now(),
                                            p_valid_to timestamptz DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_id uuid; v_conflict text; v_actor_person uuid := vv_actor_person();
BEGIN
  IF NOT vv_authorize('role_assignment', 'create', 'Oe', ARRAY[p_scope]) THEN
    RAISE EXCEPTION 'deny-by-default: keine Berechtigung role_assignment.create' USING ERRCODE = '42501';
  END IF;
  IF v_actor_person IS NOT NULL AND v_actor_person = p_person THEN
    PERFORM vv_audit_write('rbac.assign.denied', p_person::text,
      jsonb_build_object('role', p_role, 'grund', 'selbst_zuweisung'));
    RETURN jsonb_build_object('ok', false, 'reason', 'selbst_zuweisung_verboten');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM role_type WHERE code = p_role) THEN
    RAISE EXCEPTION 'unbekannter Rollentyp %', p_role;
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(vv_current_tenant()::text || '/' || p_person::text, 7));
  v_conflict := vv_sod_conflict(p_person, p_role, p_valid_from, p_valid_to, NULL);
  IF v_conflict IS NOT NULL THEN
    PERFORM vv_audit_write('rbac.assign.sod_blocked', p_person::text,
      jsonb_build_object('role', p_role, 'konflikt', v_conflict));
    RETURN jsonb_build_object('ok', false, 'reason', 'sod_kern', 'conflict', v_conflict);
  END IF;
  INSERT INTO role_assignment (tenant_id, person_id, role_type, scope_node, scope_node_id,
                               valid_from, valid_to, assigned_by)
  VALUES (vv_current_tenant(), p_person, p_role, p_scope::text, p_scope, p_valid_from, p_valid_to, vv_actor())
  RETURNING id INTO v_id;
  PERFORM vv_audit_write('rbac.assign', v_id::text,
    jsonb_build_object('person', p_person, 'role', p_role, 'scope', p_scope));
  PERFORM vv_outbox_emit('basis02.role.assigned', jsonb_build_object('assignment', v_id), 'rbac.assign:' || v_id);
  RETURN jsonb_build_object('ok', true, 'id', v_id);
END $$;

CREATE OR REPLACE FUNCTION rbac_revoke_role(p_assignment uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_scope uuid; v_person uuid;
BEGIN
  SELECT scope_node_id, person_id INTO v_scope, v_person FROM role_assignment
   WHERE id = p_assignment AND tenant_id = vv_current_tenant() AND revoked_at IS NULL FOR UPDATE;
  IF v_scope IS NULL THEN RAISE EXCEPTION 'keine aktive Zuweisung %', p_assignment; END IF;
  IF NOT vv_authorize('role_assignment', 'deactivate', 'Oe', ARRAY[v_scope]) THEN
    RAISE EXCEPTION 'deny-by-default: keine Berechtigung role_assignment.deactivate' USING ERRCODE = '42501';
  END IF;
  UPDATE role_assignment SET revoked_at = now(), revoked_by = vv_actor() WHERE id = p_assignment;
  PERFORM vv_audit_write('rbac.revoke', p_assignment::text, jsonb_build_object('person', v_person));
  PERFORM vv_outbox_emit('basis02.role.revoked', jsonb_build_object('assignment', p_assignment), 'rbac.revoke:' || p_assignment);
  RETURN jsonb_build_object('ok', true);
END $$;

CREATE OR REPLACE FUNCTION rbac_create_scope_node(p_parent uuid, p_kind text, p_name text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_id uuid;
BEGIN
  IF p_parent IS NULL OR p_kind = 'verein' THEN
    RAISE EXCEPTION 'Wurzelknoten (Verein) legt nur das Betreiber-Onboarding an';
  END IF;
  IF NOT vv_authorize('scope_node', 'create', 'Oe', ARRAY[p_parent]) THEN
    RAISE EXCEPTION 'deny-by-default: keine Berechtigung scope_node.create' USING ERRCODE = '42501';
  END IF;
  INSERT INTO scope_node (tenant_id, parent_id, kind, name)
  VALUES (vv_current_tenant(), p_parent, p_kind, p_name) RETURNING id INTO v_id;
  PERFORM vv_audit_write('rbac.scope.create', v_id::text, jsonb_build_object('parent', p_parent, 'kind', p_kind));
  RETURN v_id;
END $$;

-- Betreiber-Onboarding (NUR Bootstrap, keine Grants): Vereins-Wurzel + Principal-Bindung.
-- Bewusst nicht für vv_app: sonst könnte ein Admin sein OIDC-Subjekt an die Person des Obmanns
-- binden und dessen Rechte übernehmen. Später: Einladungs-/Registrierungsfluss (BASIS-10).
CREATE OR REPLACE FUNCTION rbac_onboard_root(p_tenant uuid, p_name text) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE v_id uuid;
BEGIN
  PERFORM set_config('app.tenant_id', p_tenant::text, true);
  SELECT id INTO v_id FROM scope_node WHERE tenant_id = p_tenant AND parent_id IS NULL;
  IF v_id IS NULL THEN
    INSERT INTO scope_node (tenant_id, parent_id, kind, name) VALUES (p_tenant, NULL, 'verein', p_name)
    RETURNING id INTO v_id;
  END IF;
  RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION rbac_link_principal(p_tenant uuid, p_subject text, p_person uuid) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('app.tenant_id', p_tenant::text, true);
  INSERT INTO principal_link (tenant_id, subject, person_id) VALUES (p_tenant, p_subject, p_person)
  ON CONFLICT (tenant_id, subject) DO NOTHING;
  INSERT INTO audit_log (tenant_id, actor, action, subject_ref, payload)
  VALUES (p_tenant, 'system:onboarding', 'rbac.principal.link', p_person::text, jsonb_build_object('subject_ref', md5(p_subject)));
END $$;

-- ---------------------------------------------------------------------------------------------
-- Eigentümer + Grants (least privilege). Neue Funktionen sind per Default für PUBLIC ausführbar
-- -> ALLE hier angelegten Funktionen zuerst PUBLIC entziehen, dann gezielt vergeben.
-- ---------------------------------------------------------------------------------------------
GRANT SELECT ON tenant TO vv_definer;
GRANT SELECT ON role_type, role_permission, sod_rule TO vv_definer;
GRANT SELECT, INSERT ON scope_node TO vv_definer;
GRANT SELECT ON principal_link TO vv_definer;
GRANT SELECT, INSERT, UPDATE ON role_assignment TO vv_definer;
GRANT SELECT ON person TO vv_definer;
GRANT SELECT, INSERT ON audit_log TO vv_definer;
GRANT SELECT, INSERT ON outbox TO vv_definer;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO vv_definer;

DO $$
DECLARE f record;
BEGIN
  FOR f IN SELECT p.oid::regprocedure AS sig, p.proname FROM pg_proc p
             JOIN pg_namespace n ON n.oid = p.pronamespace AND n.nspname = 'public'
            WHERE p.proname IN ('vv_actor','vv_audit_write','vv_outbox_emit','vv_subject_person',
                  'vv_actor_person','vv_scope_root','vv_scope_ancestors','vv_assignment_active',
                  'vv_authorize_subject','vv_authorize','vv_policy_any','vv_person_scopes',
                  'vv_sod_conflict','vv_role_assignment_guard','rbac_assign_role','rbac_revoke_role',
                  'rbac_create_scope_node','rbac_onboard_root','rbac_link_principal')
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', f.sig);
    IF f.proname NOT IN ('rbac_onboard_root','rbac_link_principal','vv_actor','vv_assignment_active') THEN
      EXECUTE format('ALTER FUNCTION %s OWNER TO vv_definer', f.sig);
    END IF;
  END LOOP;
END $$;
-- Hilfsfunktionen ohne Datenzugriff: für die Definer-Rolle + App ausführbar.
GRANT EXECUTE ON FUNCTION vv_actor() TO vv_definer, vv_app, vv_worker;
GRANT EXECUTE ON FUNCTION vv_assignment_active(timestamptz, timestamptz, timestamptz) TO vv_definer;

-- App (Web): nur lesen, was Ö-Konfiguration ist, und die geprüften Befehle aufrufen.
GRANT SELECT ON role_type, role_permission, sod_rule, scope_node TO vv_app;
REVOKE INSERT, UPDATE, DELETE ON role_assignment FROM vv_app;
GRANT EXECUTE ON FUNCTION vv_policy_any(text, text, text) TO vv_app;
GRANT EXECUTE ON FUNCTION vv_authorize(text, text, text, uuid[], uuid) TO vv_app;
GRANT EXECUTE ON FUNCTION rbac_assign_role(uuid, text, uuid, timestamptz, timestamptz) TO vv_app;
GRANT EXECUTE ON FUNCTION rbac_revoke_role(uuid) TO vv_app;
GRANT EXECUTE ON FUNCTION rbac_create_scope_node(uuid, text, text) TO vv_app;
-- Definer-interne Aufrufkette (Funktionen rufen einander als vv_definer auf)
GRANT EXECUTE ON FUNCTION vv_audit_write(text, text, jsonb, text), vv_outbox_emit(text, jsonb, text),
  vv_subject_person(text), vv_actor_person(), vv_scope_root(), vv_scope_ancestors(uuid),
  vv_authorize_subject(text, text, text, text, uuid[], uuid), vv_authorize(text, text, text, uuid[], uuid),
  vv_policy_any(text, text, text), vv_person_scopes(uuid),
  vv_sod_conflict(uuid, text, timestamptz, timestamptz, uuid) TO vv_definer;
-- Trigger-Funktion: ausgeführt im Kontext der schreibenden Rolle (vv_definer).
GRANT EXECUTE ON FUNCTION vv_role_assignment_guard() TO vv_definer;

COMMIT;
