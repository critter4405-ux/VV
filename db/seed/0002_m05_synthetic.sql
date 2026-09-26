-- VV Seed 0002 — M05/BASIS-02: AUSSCHLIESSLICH SYNTHETISCHE Testdaten (K31/ADR-10).
-- Alle Namen/Nummern frei erfunden. Idempotent (feste UUIDs, ON CONFLICT DO NOTHING).
-- Läuft als Bootstrap (Onboarding-Pfad): Vereins-Wurzel, Principal-Bindungen, Start-Rollen.

-- ---------------- Mandant A (Demo FC) ----------------
-- C-1: geprüfter Bootstrap-Kontext (Superuser) statt frei setzbarer GUC; eine Transaktion je Seed.
BEGIN;
SELECT vv_bootstrap_context('00000000-0000-0000-0000-0000000000aa', 'system:seed');

INSERT INTO person (id, tenant_id, last_name, first_name, birth_date, status) VALUES
  ('a0000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000aa', 'Admin',     'Ada',    '1980-02-02', 'active'),
  ('a0000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-0000000000aa', 'Obfrau',    'Olga',   '1975-03-03', 'active'),
  ('a0000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-0000000000aa', 'Vorstand',  'Viktor', '1970-04-04', 'active'),
  ('a0000000-0000-0000-0000-000000000004', '00000000-0000-0000-0000-0000000000aa', 'Schrift',   'Sabine', '1985-05-05', 'active'),
  ('a0000000-0000-0000-0000-000000000005', '00000000-0000-0000-0000-0000000000aa', 'Pruef',     'Paula',  '1966-06-06', 'active'),
  ('a0000000-0000-0000-0000-000000000006', '00000000-0000-0000-0000-0000000000aa', 'Trainer',   'Toni',   '1990-07-07', 'active'),
  ('a0000000-0000-0000-0000-000000000007', '00000000-0000-0000-0000-0000000000aa', 'Kinder',    'Karin',  '1982-08-08', 'active'),
  ('a0000000-0000-0000-0000-000000000011', '00000000-0000-0000-0000-0000000000aa', 'Jugend',    'Jonas',  '2009-01-15', 'active'),
  ('a0000000-0000-0000-0000-000000000012', '00000000-0000-0000-0000-0000000000aa', 'Kicker',    'Kurt',   '2000-10-10', 'active'),
  ('a0000000-0000-0000-0000-000000000013', '00000000-0000-0000-0000-0000000000aa', 'Fremdteam', 'Fritz',  '1999-11-11', 'active'),
  ('a0000000-0000-0000-0000-000000000014', '00000000-0000-0000-0000-0000000000aa', 'Ohnedatum', 'Otto',   NULL,         'active'),
  ('a0000000-0000-0000-0000-000000000015', '00000000-0000-0000-0000-0000000000aa', 'Kassier',   'Klaus',  '1978-12-12', 'active')
ON CONFLICT (id) DO NOTHING;

SELECT rbac_onboard_root('00000000-0000-0000-0000-0000000000aa', 'Demo FC (synthetisch)');
INSERT INTO scope_node (id, tenant_id, parent_id, kind, name) VALUES
  ('5c000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000aa',
   (SELECT id FROM scope_node WHERE tenant_id = '00000000-0000-0000-0000-0000000000aa' AND parent_id IS NULL), 'abteilung', 'Fußball'),
  ('5c000000-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000aa',
   '5c000000-0000-0000-0000-0000000000a1', 'mannschaft', 'U18'),
  ('5c000000-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-0000000000aa',
   '5c000000-0000-0000-0000-0000000000a1', 'mannschaft', 'Kampfmannschaft')
ON CONFLICT (id) DO NOTHING;

SELECT rbac_link_principal('00000000-0000-0000-0000-0000000000aa', s, p::uuid) FROM (VALUES
  ('sub-admin-aa',   'a0000000-0000-0000-0000-000000000001'),
  ('sub-obmann-aa',  'a0000000-0000-0000-0000-000000000002'),
  ('sub-vorstand-aa','a0000000-0000-0000-0000-000000000003'),
  ('sub-schrift-aa', 'a0000000-0000-0000-0000-000000000004'),
  ('sub-pruef-aa',   'a0000000-0000-0000-0000-000000000005'),
  ('sub-trainer-aa', 'a0000000-0000-0000-0000-000000000006'),
  ('sub-kinder-aa',  'a0000000-0000-0000-0000-000000000007'),
  ('sub-jonas-aa',   'a0000000-0000-0000-0000-000000000011'),
  ('sub-kurt-aa',    'a0000000-0000-0000-0000-000000000012'),
  ('sub-kassier-aa', 'a0000000-0000-0000-0000-000000000015')
) v(s, p);

-- Start-Rollen (Onboarding): direkt als Bootstrap, SoD-Trigger greift trotzdem.
INSERT INTO role_assignment (id, tenant_id, person_id, role_type, scope_node, scope_node_id, assigned_by)
SELECT id::uuid, '00000000-0000-0000-0000-0000000000aa', person::uuid, role, scope, scope::uuid, 'system:onboarding'
FROM (VALUES
  ('a1a00000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000001', 'mandanten_admin', NULL),
  ('a1a00000-0000-0000-0000-000000000002', 'a0000000-0000-0000-0000-000000000002', 'obmann',          NULL),
  ('a1a00000-0000-0000-0000-000000000003', 'a0000000-0000-0000-0000-000000000003', 'vorstand',        NULL),
  ('a1a00000-0000-0000-0000-000000000004', 'a0000000-0000-0000-0000-000000000004', 'schriftfuehrer',  NULL),
  ('a1a00000-0000-0000-0000-000000000005', 'a0000000-0000-0000-0000-000000000005', 'kassapruefer',    NULL),
  ('a1a00000-0000-0000-0000-000000000006', 'a0000000-0000-0000-0000-000000000006', 'trainer',         '5c000000-0000-0000-0000-0000000000a2'),
  ('a1a00000-0000-0000-0000-000000000007', 'a0000000-0000-0000-0000-000000000007', 'kinderschutz',    NULL),
  ('a1a00000-0000-0000-0000-000000000011', 'a0000000-0000-0000-0000-000000000011', 'spieler',         '5c000000-0000-0000-0000-0000000000a2'),
  ('a1a00000-0000-0000-0000-000000000012', 'a0000000-0000-0000-0000-000000000012', 'spieler',         '5c000000-0000-0000-0000-0000000000a3'),
  ('a1a00000-0000-0000-0000-000000000013', 'a0000000-0000-0000-0000-000000000013', 'spieler',         '5c000000-0000-0000-0000-0000000000a3'),
  ('a1a00000-0000-0000-0000-000000000015', 'a0000000-0000-0000-0000-000000000015', 'kassier',         NULL)
) v(id, person, role, scope_raw)
CROSS JOIN LATERAL (SELECT coalesce(scope_raw,
  (SELECT id::text FROM scope_node WHERE tenant_id = '00000000-0000-0000-0000-0000000000aa' AND parent_id IS NULL)) AS scope) sc
ON CONFLICT (id) DO NOTHING;

-- ---------------- Mandant B (für Isolationstests) ----------------
SELECT vv_bootstrap_context('00000000-0000-0000-0000-0000000000bb', 'system:seed');
INSERT INTO person (id, tenant_id, last_name, first_name, birth_date, status) VALUES
  ('b0000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000bb', 'Badmin', 'Bea', '1981-01-01', 'active')
ON CONFLICT (id) DO NOTHING;
SELECT rbac_onboard_root('00000000-0000-0000-0000-0000000000bb', 'Demo B (synthetisch)');
SELECT rbac_link_principal('00000000-0000-0000-0000-0000000000bb', 'sub-admin-bb', 'b0000000-0000-0000-0000-000000000001');
INSERT INTO role_assignment (id, tenant_id, person_id, role_type, scope_node, scope_node_id, assigned_by)
SELECT 'b1b00000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000bb',
       'b0000000-0000-0000-0000-000000000001', 'mandanten_admin', id::text, id, 'system:onboarding'
  FROM scope_node WHERE tenant_id = '00000000-0000-0000-0000-0000000000bb' AND parent_id IS NULL
ON CONFLICT (id) DO NOTHING;

COMMIT;
