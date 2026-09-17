-- VV Migration 0002 — Mandantentrennung + RLS (ADR-01), WP1-gehärtet
-- INVARIANTE: jede Tabelle mit tenant_id hat FORCE ROW LEVEL SECURITY + Policy.
-- WP1: zusammengesetzte Schlüssel/FKs (tenant_id,id) verhindern mandantenübergreifende
-- Fremdschlüssel (Review-Befund Codex #4).

CREATE TABLE IF NOT EXISTS tenant (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    slug        text NOT NULL UNIQUE,
    name        text NOT NULL,
    tz          text NOT NULL DEFAULT 'Europe/Vienna',
    created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION vv_current_tenant() RETURNS uuid
LANGUAGE sql STABLE AS $$
  SELECT NULLIF(current_setting('app.tenant_id', true), '')::uuid
$$;

-- Person (BASIS-01) — tenant-scoped, natürliche Personen.
CREATE TABLE IF NOT EXISTS person (
    id           uuid NOT NULL DEFAULT gen_random_uuid(),
    tenant_id    uuid NOT NULL REFERENCES tenant(id),
    identity_id  uuid NOT NULL DEFAULT gen_random_uuid(),
    last_name    text NOT NULL,
    first_name   text NOT NULL,
    birth_date   date,
    status       text NOT NULL DEFAULT 'active',
    version      integer NOT NULL DEFAULT 1,
    updated_at   timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (id),
    CONSTRAINT person_tenant_uk UNIQUE (tenant_id, id)   -- Ziel für zusammengesetzte FKs
);
ALTER TABLE person ENABLE ROW LEVEL SECURITY;
ALTER TABLE person FORCE ROW LEVEL SECURITY;
CREATE POLICY person_tenant_isolation ON person
    USING (tenant_id = vv_current_tenant())
    WITH CHECK (tenant_id = vv_current_tenant());

-- Organisation (VV-ORG) — tenant-scoped, juristische Personen.
CREATE TABLE IF NOT EXISTS organisation (
    id           uuid NOT NULL DEFAULT gen_random_uuid(),
    tenant_id    uuid NOT NULL REFERENCES tenant(id),
    org_id       uuid NOT NULL DEFAULT gen_random_uuid(),
    name         text NOT NULL,
    legal_form   text,
    uid_atu      text,
    status       text NOT NULL DEFAULT 'active',
    version      integer NOT NULL DEFAULT 1,
    updated_at   timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (id),
    CONSTRAINT organisation_tenant_uk UNIQUE (tenant_id, id)
);
ALTER TABLE organisation ENABLE ROW LEVEL SECURITY;
ALTER TABLE organisation FORCE ROW LEVEL SECURITY;
CREATE POLICY organisation_tenant_isolation ON organisation
    USING (tenant_id = vv_current_tenant())
    WITH CHECK (tenant_id = vv_current_tenant());

-- Rolle/Funktion-Zuweisung (BASIS-02) — tenant-scoped.
-- Zusammengesetzter FK (tenant_id, person_id) -> person(tenant_id, id): eine Zuweisung
-- kann NIE auf eine Person aus einem anderen Mandanten zeigen.
CREATE TABLE IF NOT EXISTS role_assignment (
    id           uuid NOT NULL DEFAULT gen_random_uuid(),
    tenant_id    uuid NOT NULL REFERENCES tenant(id),
    person_id    uuid NOT NULL,
    role_type    text NOT NULL,
    scope_node   text NOT NULL,
    valid_from   timestamptz NOT NULL DEFAULT now(),
    valid_to     timestamptz,
    created_at   timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (id),
    CONSTRAINT role_assignment_person_fk
        FOREIGN KEY (tenant_id, person_id) REFERENCES person (tenant_id, id)
);
ALTER TABLE role_assignment ENABLE ROW LEVEL SECURITY;
ALTER TABLE role_assignment FORCE ROW LEVEL SECURITY;
CREATE POLICY role_assignment_tenant_isolation ON role_assignment
    USING (tenant_id = vv_current_tenant())
    WITH CHECK (tenant_id = vv_current_tenant());
