-- VV Migration 0002 — Mandantentrennung + RLS (ADR-01)
-- INVARIANTE (validator-erzwungen, ADR-09): jede Tabelle mit tenant_id
-- hat ROW LEVEL SECURITY aktiviert UND mindestens eine Policy.
-- Tenant-Kontext pro Request: SET app.tenant_id = '<uuid>'.

-- Mandant (Verein) — Stammtabelle, selbst NICHT tenant-scoped.
CREATE TABLE IF NOT EXISTS tenant (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    slug        text NOT NULL UNIQUE,
    name        text NOT NULL,
    tz          text NOT NULL DEFAULT 'Europe/Vienna',
    created_at  timestamptz NOT NULL DEFAULT now()
);

-- Hilfsfunktion: aktiver Mandant aus Session-Variable (leer -> NULL).
CREATE OR REPLACE FUNCTION vv_current_tenant() RETURNS uuid
LANGUAGE sql STABLE AS $$
  SELECT NULLIF(current_setting('app.tenant_id', true), '')::uuid
$$;

-- ---------------------------------------------------------------------------
-- Person (BASIS-01) — Identitätskern, nur natürliche Personen. tenant-scoped.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS person (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id    uuid NOT NULL REFERENCES tenant(id),
    identity_id  uuid NOT NULL DEFAULT gen_random_uuid(),  -- global, Cross-Tenant vorbereitet
    last_name    text NOT NULL,
    first_name   text NOT NULL,
    birth_date   date,                                     -- bedingt Pflicht über Rolle
    status       text NOT NULL DEFAULT 'active',
    version      integer NOT NULL DEFAULT 1,               -- optimistische Nebenläufigkeit (BS-1)
    updated_at   timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE person ENABLE ROW LEVEL SECURITY;
ALTER TABLE person FORCE ROW LEVEL SECURITY;
CREATE POLICY person_tenant_isolation ON person
    USING (tenant_id = vv_current_tenant())
    WITH CHECK (tenant_id = vv_current_tenant());

-- ---------------------------------------------------------------------------
-- Organisation (VV-ORG) — juristische Personen, getrennt von person. tenant-scoped.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS organisation (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id    uuid NOT NULL REFERENCES tenant(id),
    org_id       uuid NOT NULL DEFAULT gen_random_uuid(),
    name         text NOT NULL,
    legal_form   text,
    uid_atu      text,                                     -- UID/ATU, Formatprüfung im App-Layer
    status       text NOT NULL DEFAULT 'active',
    version      integer NOT NULL DEFAULT 1,
    updated_at   timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE organisation ENABLE ROW LEVEL SECURITY;
ALTER TABLE organisation FORCE ROW LEVEL SECURITY;
CREATE POLICY organisation_tenant_isolation ON organisation
    USING (tenant_id = vv_current_tenant())
    WITH CHECK (tenant_id = vv_current_tenant());

-- ---------------------------------------------------------------------------
-- Rolle/Funktion-Zuweisung (BASIS-02) — Person × Rollentyp × Scope. tenant-scoped.
-- Eigentümer der Zuweisung ist BASIS-02 (keine Doppelung mit BASIS-01).
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS role_assignment (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id    uuid NOT NULL REFERENCES tenant(id),
    person_id    uuid NOT NULL REFERENCES person(id),
    role_type    text NOT NULL,
    scope_node   text NOT NULL,                            -- Verein/Abteilung/Mannschaft (vererbender Baum)
    valid_from   timestamptz NOT NULL DEFAULT now(),
    valid_to     timestamptz,                              -- Delegation/Vertretung: Pflicht-Ende (B02-2)
    created_at   timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE role_assignment ENABLE ROW LEVEL SECURITY;
ALTER TABLE role_assignment FORCE ROW LEVEL SECURITY;
CREATE POLICY role_assignment_tenant_isolation ON role_assignment
    USING (tenant_id = vv_current_tenant())
    WITH CHECK (tenant_id = vv_current_tenant());
