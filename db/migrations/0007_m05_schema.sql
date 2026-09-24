-- VV Migration 0007 — Modul M05 „Mitglieder": Datenmodell (Steckbrief Baubuch v0.20, Register P50)
-- Idempotent + atomar. Alle mandantenbezogenen Tabellen: tenant_id + ENABLE/FORCE RLS + Policy
-- (ADR-01), zusammengesetzte FKs (kein Cross-Tenant-Bezug). vv_app erhält KEIN direktes DML auf
-- die Mitgliedschaftsdaten; geschrieben wird nur über die geprüften Funktionen aus 0008.

BEGIN;
SET LOCAL client_min_messages = warning;

-- ---------------------------------------------------------------------------------------------
-- Globale System-Kataloge (seed, nicht mandantenbezogen)
-- ---------------------------------------------------------------------------------------------
-- Zwei-Schichten (P50-1): feste System-Kategorien; Vereins-Mitgliedsarten tragen genau eine.
CREATE TABLE IF NOT EXISTS membership_category (
    code     text PRIMARY KEY CHECK (code IN ('aktiv','unterstuetzend','foerdernd','ehren','jugend')),
    name     text NOT NULL,
    version  integer NOT NULL DEFAULT 1
);
INSERT INTO membership_category (code, name) VALUES
  ('aktiv',          'Aktives Mitglied'),
  ('unterstuetzend', 'Unterstützendes/passives Mitglied'),
  ('foerdernd',      'Förderndes Mitglied'),
  ('ehren',          'Ehrenmitglied'),
  ('jugend',         'Jugend-/Nachwuchsmitglied')
ON CONFLICT (code) DO NOTHING;

-- Beendigungsgründe als Katalog — KEIN Freitext (P50-3). Austritt = S, Ausschluss = Se (P50-13).
CREATE TABLE IF NOT EXISTS membership_end_reason (
    code        text PRIMARY KEY CHECK (code ~ '^[a-z_]{3,40}$'),
    kind        text NOT NULL CHECK (kind IN ('austritt','ausschluss')),
    data_class  text NOT NULL,
    name        text NOT NULL,
    CONSTRAINT mer_class_ck CHECK ((kind = 'austritt' AND data_class = 'S')
                                OR (kind = 'ausschluss' AND data_class = 'Se'))
);
INSERT INTO membership_end_reason (code, kind, data_class, name) VALUES
  ('umzug',                  'austritt',   'S',  'Umzug'),
  ('zeitmangel',             'austritt',   'S',  'Zeitmangel'),
  ('kosten',                 'austritt',   'S',  'Kosten'),
  ('vereinswechsel',         'austritt',   'S',  'Vereinswechsel'),
  ('sportende',              'austritt',   'S',  'Ende der sportlichen Tätigkeit'),
  ('keine_angabe',           'austritt',   'S',  'Keine Angabe'),
  ('satzungsverstoss',       'ausschluss', 'Se', 'Verstoß gegen die Statuten'),
  ('beitragsrueckstand',     'ausschluss', 'Se', 'Beitragsrückstand trotz Mahnung'),
  ('vereinsschaedigend',     'ausschluss', 'Se', 'Vereinsschädigendes Verhalten'),
  ('sonstiger_wichtiger_grund','ausschluss','Se','Sonstiger wichtiger Grund (lt. Beschluss)')
ON CONFLICT (code) DO NOTHING;

-- ---------------------------------------------------------------------------------------------
-- Vereins-Mitgliedsarten (tenant) + append-only Regel-Versionen
-- ---------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS membership_type (
    id             uuid NOT NULL DEFAULT gen_random_uuid(),
    tenant_id      uuid NOT NULL REFERENCES tenant(id),
    code           text NOT NULL CHECK (code ~ '^[a-z0-9_]{2,40}$'),
    name           text NOT NULL CHECK (length(name) BETWEEN 1 AND 80),
    category_code  text NOT NULL REFERENCES membership_category(code),
    status         text NOT NULL DEFAULT 'aktiv' CHECK (status IN ('aktiv','abgeloest')),
    created_at     timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (id),
    CONSTRAINT membership_type_tenant_uk UNIQUE (tenant_id, id),
    CONSTRAINT membership_type_code_uk UNIQUE (tenant_id, code)
);
ALTER TABLE membership_type ENABLE ROW LEVEL SECURITY;
ALTER TABLE membership_type FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS membership_type_tenant_isolation ON membership_type;
CREATE POLICY membership_type_tenant_isolation ON membership_type
    USING (tenant_id = vv_current_tenant())
    WITH CHECK (tenant_id = vv_current_tenant());

CREATE TABLE IF NOT EXISTS membership_type_version (
    id                 uuid NOT NULL DEFAULT gen_random_uuid(),
    tenant_id          uuid NOT NULL REFERENCES tenant(id),
    type_id            uuid NOT NULL,
    version            integer NOT NULL CHECK (version >= 1),
    valid_from         date NOT NULL,
    notice_months      integer NOT NULL DEFAULT 0 CHECK (notice_months BETWEEN 0 AND 24),
    notice_cutoff      text NOT NULL DEFAULT 'sofort'
                       CHECK (notice_cutoff IN ('sofort','monatsende','quartalsende','halbjahresende','jahresende')),
    youth_age_limit    integer CHECK (youth_age_limit BETWEEN 6 AND 30),
    successor_type_id  uuid,
    created_at         timestamptz NOT NULL DEFAULT now(),
    created_by         text NOT NULL,
    PRIMARY KEY (id),
    CONSTRAINT mtv_tenant_uk UNIQUE (tenant_id, id),
    CONSTRAINT mtv_version_uk UNIQUE (tenant_id, type_id, version),
    CONSTRAINT mtv_type_fk FOREIGN KEY (tenant_id, type_id) REFERENCES membership_type (tenant_id, id),
    CONSTRAINT mtv_successor_fk FOREIGN KEY (tenant_id, successor_type_id) REFERENCES membership_type (tenant_id, id),
    CONSTRAINT mtv_youth_ck CHECK ((youth_age_limit IS NULL) = (successor_type_id IS NULL)),
    CONSTRAINT mtv_successor_self_ck CHECK (successor_type_id IS DISTINCT FROM type_id)
);
ALTER TABLE membership_type_version ENABLE ROW LEVEL SECURITY;
ALTER TABLE membership_type_version FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS membership_type_version_tenant_isolation ON membership_type_version;
CREATE POLICY membership_type_version_tenant_isolation ON membership_type_version
    USING (tenant_id = vv_current_tenant())
    WITH CHECK (tenant_id = vv_current_tenant());

-- ---------------------------------------------------------------------------------------------
-- Mitglied (Person × Verein) + Mitgliedschaftsperioden
-- ---------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS member (
    id             uuid NOT NULL DEFAULT gen_random_uuid(),
    tenant_id      uuid NOT NULL REFERENCES tenant(id),
    person_id      uuid,                  -- NULL nur nach Anonymisierung
    member_no      text,                  -- Mitgliedsnummer (Import-Schlüssel); NULL nur nach Anonymisierung
    created_at     timestamptz NOT NULL DEFAULT now(),
    anonymized_at  timestamptz,
    PRIMARY KEY (id),
    CONSTRAINT member_tenant_uk UNIQUE (tenant_id, id),
    CONSTRAINT member_person_uk UNIQUE (tenant_id, person_id),
    CONSTRAINT member_no_uk UNIQUE (tenant_id, member_no),
    CONSTRAINT member_person_fk FOREIGN KEY (tenant_id, person_id) REFERENCES person (tenant_id, id),
    CONSTRAINT member_anon_ck CHECK ((anonymized_at IS NULL) = (person_id IS NOT NULL AND member_no IS NOT NULL)),
    CONSTRAINT member_no_fmt_ck CHECK (member_no IS NULL OR member_no ~ '^[A-Za-z0-9._-]{1,32}$')
);
ALTER TABLE member ENABLE ROW LEVEL SECURITY;
ALTER TABLE member FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS member_tenant_isolation ON member;
CREATE POLICY member_tenant_isolation ON member
    USING (tenant_id = vv_current_tenant())
    WITH CHECK (tenant_id = vv_current_tenant());

CREATE TABLE IF NOT EXISTS membership_period (
    id                     uuid NOT NULL DEFAULT gen_random_uuid(),
    tenant_id              uuid NOT NULL REFERENCES tenant(id),
    member_id              uuid NOT NULL,
    status                 text NOT NULL CHECK (status IN ('beantragt','abgelehnt','aktiv','ruhend',
                                    'gekuendigt','beendet','gesperrt','anonymisiert')),
    applied_on             date NOT NULL,
    entry_date             date,
    notice_received_on     date,
    exit_effective_date    date,
    end_kind               text CHECK (end_kind IN ('ausgetreten','ausgeschlossen','verstorben')),
    end_reason_code        text REFERENCES membership_end_reason(code),      -- Datenklasse S
    exclusion_reason_code  text REFERENCES membership_end_reason(code),      -- Datenklasse Se
    resolution_ref         text CHECK (resolution_ref IS NULL OR resolution_ref ~ '^[A-Za-z0-9./_-]{1,64}$'),
    retention_until        date,
    locked_at              timestamptz,
    anonymized_at          timestamptz,
    source                 text NOT NULL DEFAULT 'manuell' CHECK (source IN ('manuell','import')),
    import_batch           text,
    version                integer NOT NULL DEFAULT 1,
    updated_at             timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (id),
    CONSTRAINT mp_tenant_uk UNIQUE (tenant_id, id),
    CONSTRAINT mp_member_fk FOREIGN KEY (tenant_id, member_id) REFERENCES member (tenant_id, id),
    CONSTRAINT mp_entry_ck CHECK (status IN ('beantragt','abgelehnt') OR entry_date IS NOT NULL),
    CONSTRAINT mp_end_ck CHECK (status NOT IN ('gekuendigt','beendet','gesperrt','anonymisiert')
                                OR (end_kind IS NOT NULL AND exit_effective_date IS NOT NULL)),
    CONSTRAINT mp_excl_kind_ck CHECK (exclusion_reason_code IS NULL OR end_kind = 'ausgeschlossen'),
    CONSTRAINT mp_excl_req_ck CHECK (end_kind IS DISTINCT FROM 'ausgeschlossen' OR status = 'anonymisiert'
                                     OR exclusion_reason_code IS NOT NULL),
    CONSTRAINT mp_reason_kind_ck CHECK (end_reason_code IS NULL OR end_kind = 'ausgetreten'),
    CONSTRAINT mp_dates_ck CHECK (exit_effective_date IS NULL OR entry_date IS NULL OR exit_effective_date >= entry_date),
    CONSTRAINT mp_anon_ck CHECK ((status = 'anonymisiert') = (anonymized_at IS NOT NULL)),
    CONSTRAINT mp_anon_clean_ck CHECK (status <> 'anonymisiert' OR (end_reason_code IS NULL
                                       AND exclusion_reason_code IS NULL AND resolution_ref IS NULL
                                       AND notice_received_on IS NULL AND import_batch IS NULL))
);
-- AK-01: höchstens EINE offene Periode je Mitglied.
CREATE UNIQUE INDEX IF NOT EXISTS mp_one_open ON membership_period (tenant_id, member_id)
    WHERE status IN ('beantragt','aktiv','ruhend','gekuendigt');
CREATE INDEX IF NOT EXISTS mp_status_idx ON membership_period (tenant_id, status);
ALTER TABLE membership_period ENABLE ROW LEVEL SECURITY;
ALTER TABLE membership_period FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS membership_period_tenant_isolation ON membership_period;
CREATE POLICY membership_period_tenant_isolation ON membership_period
    USING (tenant_id = vv_current_tenant())
    WITH CHECK (tenant_id = vv_current_tenant());

-- ---------------------------------------------------------------------------------------------
-- Append-only Verlauf (P50-4): Status und Mitgliedsart — Wirksam-ab + Erfasst-am + Actor
-- ---------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS membership_status_history (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id       uuid NOT NULL REFERENCES tenant(id),
    period_id       uuid NOT NULL,
    from_status     text,
    to_status       text NOT NULL,
    effective_date  date NOT NULL,
    recorded_at     timestamptz NOT NULL DEFAULT now(),
    actor           text NOT NULL,
    approval_id     uuid,
    CONSTRAINT msh_period_fk FOREIGN KEY (tenant_id, period_id) REFERENCES membership_period (tenant_id, id)
);
ALTER TABLE membership_status_history ENABLE ROW LEVEL SECURITY;
ALTER TABLE membership_status_history FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS membership_status_history_tenant_isolation ON membership_status_history;
CREATE POLICY membership_status_history_tenant_isolation ON membership_status_history
    USING (tenant_id = vv_current_tenant())
    WITH CHECK (tenant_id = vv_current_tenant());

CREATE TABLE IF NOT EXISTS membership_type_assignment (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id       uuid NOT NULL REFERENCES tenant(id),
    period_id       uuid NOT NULL,
    type_id         uuid NOT NULL,
    type_version    integer NOT NULL,
    effective_from  date NOT NULL,
    recorded_at     timestamptz NOT NULL DEFAULT now(),
    actor           text NOT NULL,
    source          text NOT NULL CHECK (source IN ('manuell','aging_up','import')),
    CONSTRAINT mta_period_fk FOREIGN KEY (tenant_id, period_id) REFERENCES membership_period (tenant_id, id),
    CONSTRAINT mta_type_fk FOREIGN KEY (tenant_id, type_id) REFERENCES membership_type (tenant_id, id),
    CONSTRAINT mta_version_fk FOREIGN KEY (tenant_id, type_id, type_version)
        REFERENCES membership_type_version (tenant_id, type_id, version)
);
ALTER TABLE membership_type_assignment ENABLE ROW LEVEL SECURITY;
ALTER TABLE membership_type_assignment FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS membership_type_assignment_tenant_isolation ON membership_type_assignment;
CREATE POLICY membership_type_assignment_tenant_isolation ON membership_type_assignment
    USING (tenant_id = vv_current_tenant())
    WITH CHECK (tenant_id = vv_current_tenant());

-- ---------------------------------------------------------------------------------------------
-- Aging-up-Vorschläge (idempotent je Periode × Art × Stichtag), Vereins-Config, Freigabe-Bindung
-- ---------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS membership_proposal (
    id            uuid NOT NULL DEFAULT gen_random_uuid(),
    tenant_id     uuid NOT NULL REFERENCES tenant(id),
    period_id     uuid NOT NULL,
    kind          text NOT NULL CHECK (kind IN ('aging_up')),
    from_type_id  uuid NOT NULL,
    to_type_id    uuid NOT NULL,
    due_date      date NOT NULL,
    status        text NOT NULL DEFAULT 'offen' CHECK (status IN ('offen','bestaetigt','abgelehnt','hinfaellig')),
    created_at    timestamptz NOT NULL DEFAULT now(),
    decided_at    timestamptz,
    decided_by    text,
    PRIMARY KEY (id),
    CONSTRAINT mprop_tenant_uk UNIQUE (tenant_id, id),
    CONSTRAINT mprop_idem_uk UNIQUE (tenant_id, period_id, kind, due_date),
    CONSTRAINT mprop_period_fk FOREIGN KEY (tenant_id, period_id) REFERENCES membership_period (tenant_id, id),
    CONSTRAINT mprop_from_fk FOREIGN KEY (tenant_id, from_type_id) REFERENCES membership_type (tenant_id, id),
    CONSTRAINT mprop_to_fk FOREIGN KEY (tenant_id, to_type_id) REFERENCES membership_type (tenant_id, id),
    CONSTRAINT mprop_decided_ck CHECK ((status = 'offen') = (decided_at IS NULL))
);
ALTER TABLE membership_proposal ENABLE ROW LEVEL SECURITY;
ALTER TABLE membership_proposal FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS membership_proposal_tenant_isolation ON membership_proposal;
CREATE POLICY membership_proposal_tenant_isolation ON membership_proposal
    USING (tenant_id = vv_current_tenant())
    WITH CHECK (tenant_id = vv_current_tenant());

-- Vereins-Config M05. Aufbewahrung NIE unter 7 J., solange BASIS-07 den Finanzbezug nicht liefert
-- (P50-9: „finanz-verknüpft" konservativ, längste Frist gewinnt, Q01).
CREATE TABLE IF NOT EXISTS m05_settings (
    tenant_id           uuid PRIMARY KEY REFERENCES tenant(id),
    lock_after_days     integer NOT NULL DEFAULT 0  CHECK (lock_after_days BETWEEN 0 AND 365),
    retention_years     integer NOT NULL DEFAULT 7  CHECK (retention_years BETWEEN 7 AND 30),
    aging_up_lead_days  integer NOT NULL DEFAULT 30 CHECK (aging_up_lead_days BETWEEN 0 AND 180),
    updated_at          timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE m05_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE m05_settings FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS m05_settings_tenant_isolation ON m05_settings;
CREATE POLICY m05_settings_tenant_isolation ON m05_settings
    USING (tenant_id = vv_current_tenant())
    WITH CHECK (tenant_id = vv_current_tenant());

-- Bindung jeder M05-Freigabe an ihren geprüften Antrag: nur Anträge, die über m05_request_*
-- entstanden sind (requested_by = app.actor, Parameter-Hash, Perioden-Version), sind ausführbar.
-- Schützt gegen direkt eingefügte approval-Zeilen mit fremdem requested_by (Stage-0-Residuum).
CREATE TABLE IF NOT EXISTS m05_approval_request (
    approval_id     uuid PRIMARY KEY REFERENCES approval(id),
    tenant_id       uuid NOT NULL REFERENCES tenant(id),
    period_id       uuid NOT NULL,
    effect_id       text NOT NULL CHECK (effect_id IN ('m05.membership.terminate','m05.membership.anonymize')),
    requested_by    text NOT NULL,
    payload         jsonb NOT NULL,
    payload_hash    text NOT NULL,
    period_version  integer NOT NULL,
    created_at      timestamptz NOT NULL DEFAULT now(),
    closed_at       timestamptz,
    outcome         text CHECK (outcome IN ('executed','rejected','expired','stale')),
    CONSTRAINT mar_period_fk FOREIGN KEY (tenant_id, period_id) REFERENCES membership_period (tenant_id, id),
    CONSTRAINT mar_closed_ck CHECK ((closed_at IS NULL) = (outcome IS NULL))
);
-- Höchstens EIN offener Antrag je Periode × Effekt (kein Parallel-Antrag, kein Payload-Tausch).
CREATE UNIQUE INDEX IF NOT EXISTS mar_one_open ON m05_approval_request (tenant_id, period_id, effect_id)
    WHERE closed_at IS NULL;
ALTER TABLE m05_approval_request ENABLE ROW LEVEL SECURITY;
ALTER TABLE m05_approval_request FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS m05_approval_request_tenant_isolation ON m05_approval_request;
CREATE POLICY m05_approval_request_tenant_isolation ON m05_approval_request
    USING (tenant_id = vv_current_tenant())
    WITH CHECK (tenant_id = vv_current_tenant());

-- Import-Batch (P50-7): Anker für die Q05-Import-Freigabe. Nur über m05_import_request angelegt
-- (requested_by = app.actor, Zeilen-Hash) -> die eingelöste Freigabe deckt GENAU diese Zeilen.
CREATE TABLE IF NOT EXISTS m05_import_batch (
    tenant_id     uuid NOT NULL REFERENCES tenant(id),
    batch_ref     text NOT NULL CHECK (batch_ref ~ '^[A-Za-z0-9._-]{3,64}$'),
    approval_id   uuid NOT NULL REFERENCES approval(id),
    requested_by  text NOT NULL,
    rows_sha256   text NOT NULL CHECK (rows_sha256 ~ '^[0-9a-f]{64}$'),
    row_count     integer NOT NULL CHECK (row_count BETWEEN 1 AND 20000),
    created_at    timestamptz NOT NULL DEFAULT now(),
    applied_at    timestamptz,
    report        jsonb,
    PRIMARY KEY (tenant_id, batch_ref)
);
ALTER TABLE m05_import_batch ENABLE ROW LEVEL SECURITY;
ALTER TABLE m05_import_batch FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS m05_import_batch_tenant_isolation ON m05_import_batch;
CREATE POLICY m05_import_batch_tenant_isolation ON m05_import_batch
    USING (tenant_id = vv_current_tenant())
    WITH CHECK (tenant_id = vv_current_tenant());

-- ---------------------------------------------------------------------------------------------
-- DB-seitige Invarianten (Backstop, unabhängig vom Aufrufer)
-- ---------------------------------------------------------------------------------------------
-- Append-only: Verlauf ist unveränderbar (auch für Eigentümer, inkl. TRUNCATE).
CREATE OR REPLACE FUNCTION m05_append_only() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION '% ist append-only (Operation % nicht erlaubt)', TG_TABLE_NAME, TG_OP;
END $$;
DROP TRIGGER IF EXISTS msh_no_change ON membership_status_history;
CREATE TRIGGER msh_no_change BEFORE UPDATE OR DELETE ON membership_status_history
  FOR EACH ROW EXECUTE FUNCTION m05_append_only();
DROP TRIGGER IF EXISTS msh_no_truncate ON membership_status_history;
CREATE TRIGGER msh_no_truncate BEFORE TRUNCATE ON membership_status_history
  FOR EACH STATEMENT EXECUTE FUNCTION m05_append_only();
DROP TRIGGER IF EXISTS mta_no_change ON membership_type_assignment;
CREATE TRIGGER mta_no_change BEFORE UPDATE OR DELETE ON membership_type_assignment
  FOR EACH ROW EXECUTE FUNCTION m05_append_only();
DROP TRIGGER IF EXISTS mta_no_truncate ON membership_type_assignment;
CREATE TRIGGER mta_no_truncate BEFORE TRUNCATE ON membership_type_assignment
  FOR EACH STATEMENT EXECUTE FUNCTION m05_append_only();
DROP TRIGGER IF EXISTS mtv_no_change ON membership_type_version;
CREATE TRIGGER mtv_no_change BEFORE UPDATE OR DELETE ON membership_type_version
  FOR EACH ROW EXECUTE FUNCTION m05_append_only();
DROP TRIGGER IF EXISTS mtv_no_truncate ON membership_type_version;
CREATE TRIGGER mtv_no_truncate BEFORE TRUNCATE ON membership_type_version
  FOR EACH STATEMENT EXECUTE FUNCTION m05_append_only();
-- Mitgliedschaftsdaten nie physisch löschen (Löschung = Anonymisierung mit Freigabe, Q01).
DROP TRIGGER IF EXISTS mp_no_delete ON membership_period;
CREATE TRIGGER mp_no_delete BEFORE DELETE ON membership_period
  FOR EACH ROW EXECUTE FUNCTION m05_append_only();
DROP TRIGGER IF EXISTS mp_no_truncate ON membership_period;
CREATE TRIGGER mp_no_truncate BEFORE TRUNCATE ON membership_period
  FOR EACH STATEMENT EXECUTE FUNCTION m05_append_only();
DROP TRIGGER IF EXISTS member_no_delete ON member;
CREATE TRIGGER member_no_delete BEFORE DELETE ON member
  FOR EACH ROW EXECUTE FUNCTION m05_append_only();
DROP TRIGGER IF EXISTS member_no_truncate ON member;
CREATE TRIGGER member_no_truncate BEFORE TRUNCATE ON member
  FOR EACH STATEMENT EXECUTE FUNCTION m05_append_only();

-- Zustandsautomat als DB-Invariante (AK-02/03): erlaubte Übergänge + Pflicht-Kontext.
-- m05.ctx wird ausschließlich von den Fachfunktionen transaktionslokal gesetzt:
--   cmd = einfache Aktion · exec = Ausführung einer eingelösten Vier-Augen-Freigabe
--   job = Stichtag/Sperre (bereits freigegeben) · import = eingelöste Import-Batch-Freigabe
CREATE OR REPLACE FUNCTION m05_period_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE ctx text := coalesce(nullif(current_setting('m05.ctx', true), ''), '-');
        ok  boolean;
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NOT ((NEW.status = 'beantragt' AND ctx IN ('cmd','import'))
         OR (NEW.status IN ('aktiv','ruhend','beendet') AND ctx = 'import')) THEN
      RAISE EXCEPTION 'M05: Neuanlage im Status % mit Kontext % nicht erlaubt', NEW.status, ctx;
    END IF;
    RETURN NEW;
  END IF;
  -- Identität unveränderbar
  IF NEW.member_id <> OLD.member_id OR NEW.tenant_id <> OLD.tenant_id OR NEW.applied_on <> OLD.applied_on THEN
    RAISE EXCEPTION 'M05: Identität der Periode ist unveränderbar';
  END IF;
  IF OLD.status = 'anonymisiert' THEN
    RAISE EXCEPTION 'M05: anonymisierte Periode ist endgültig';
  END IF;
  IF NEW.status <> OLD.status THEN
    ok := CASE
      WHEN OLD.status = 'beantragt'  AND NEW.status IN ('aktiv','abgelehnt') THEN ctx = 'cmd'
      WHEN OLD.status = 'aktiv'      AND NEW.status = 'ruhend'               THEN ctx = 'cmd'
      WHEN OLD.status = 'ruhend'     AND NEW.status = 'aktiv'                THEN ctx = 'cmd'
      WHEN OLD.status IN ('aktiv','ruhend') AND NEW.status IN ('gekuendigt','beendet') THEN ctx = 'exec'
      WHEN OLD.status = 'gekuendigt' AND NEW.status = 'aktiv'                THEN ctx = 'cmd'
      WHEN OLD.status = 'gekuendigt' AND NEW.status = 'beendet'              THEN ctx = 'job'
      WHEN OLD.status = 'beendet'    AND NEW.status = 'gesperrt'             THEN ctx = 'job'
      WHEN OLD.status = 'gesperrt'   AND NEW.status = 'anonymisiert'         THEN ctx = 'exec'
      ELSE false END;
    IF NOT ok THEN
      RAISE EXCEPTION 'M05: Übergang % -> % im Kontext % nicht erlaubt', OLD.status, NEW.status, ctx;
    END IF;
  ELSIF ctx NOT IN ('cmd','exec','job','import') THEN
    RAISE EXCEPTION 'M05: Änderung ohne Fachkontext nicht erlaubt';
  END IF;
  -- Beendigungsdaten nur im Freigabe-/Import-Pfad setzbar
  IF (NEW.end_kind IS DISTINCT FROM OLD.end_kind OR NEW.exit_effective_date IS DISTINCT FROM OLD.exit_effective_date
      OR NEW.exclusion_reason_code IS DISTINCT FROM OLD.exclusion_reason_code)
     AND ctx NOT IN ('exec','import') AND NOT (ctx = 'cmd' AND OLD.status = 'gekuendigt' AND NEW.status = 'aktiv') THEN
    RAISE EXCEPTION 'M05: Beendigungsdaten nur über eingelöste Freigabe änderbar';
  END IF;
  NEW.version := OLD.version + 1;
  NEW.updated_at := now();
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS mp_guard ON membership_period;
CREATE TRIGGER mp_guard BEFORE INSERT OR UPDATE ON membership_period
  FOR EACH ROW EXECUTE FUNCTION m05_period_guard();

-- Statusverlauf automatisch (kein Statuswechsel ohne Verlaufseintrag möglich).
CREATE OR REPLACE FUNCTION m05_period_history() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_eff date;
BEGIN
  IF TG_OP = 'INSERT' OR NEW.status <> OLD.status THEN
    v_eff := coalesce(nullif(current_setting('m05.effective', true), '')::date, current_date);
    INSERT INTO membership_status_history (tenant_id, period_id, from_status, to_status,
                                           effective_date, actor, approval_id)
    VALUES (NEW.tenant_id, NEW.id, CASE WHEN TG_OP = 'UPDATE' THEN OLD.status END, NEW.status, v_eff,
            coalesce(nullif(current_setting('m05.actor', true), ''), vv_actor(), 'system:unbekannt'),
            nullif(current_setting('m05.approval_id', true), '')::uuid);
  END IF;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS mp_history ON membership_period;
CREATE TRIGGER mp_history AFTER INSERT OR UPDATE OF status ON membership_period
  FOR EACH ROW EXECUTE FUNCTION m05_period_history();

-- ---------------------------------------------------------------------------------------------
-- Grants (least privilege). vv_app: nur Ö-Konfiguration lesen, KEIN Zugriff auf Mitgliedsdaten.
-- ---------------------------------------------------------------------------------------------
GRANT SELECT ON membership_category, membership_end_reason TO vv_app, vv_definer;
GRANT SELECT ON membership_type, membership_type_version TO vv_app;
GRANT SELECT, INSERT, UPDATE ON membership_type TO vv_definer;
GRANT SELECT, INSERT ON membership_type_version TO vv_definer;
GRANT SELECT, INSERT, UPDATE ON member, membership_period, membership_proposal,
                                m05_settings, m05_approval_request, m05_import_batch TO vv_definer;
GRANT SELECT, INSERT ON membership_status_history, membership_type_assignment TO vv_definer;
GRANT SELECT, INSERT ON approval TO vv_definer;
REVOKE ALL ON member, membership_period, membership_status_history, membership_type_assignment,
              membership_proposal, m05_settings, m05_approval_request, m05_import_batch
       FROM vv_app, vv_worker;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO vv_definer;
REVOKE ALL ON FUNCTION m05_append_only(), m05_period_guard(), m05_period_history() FROM PUBLIC;

COMMIT;
