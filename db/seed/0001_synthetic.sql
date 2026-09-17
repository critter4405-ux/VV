-- VV Seed 0001 — AUSSCHLIESSLICH SYNTHETISCHE Testdaten (K31/ADR-10).
-- HARTE REGEL: niemals echte oder personenbezogene Daten. Alle Namen sind frei erfunden.
-- Dient nur dem Gate-0-Nachweis, dass der Stack + RLS laufen.

INSERT INTO tenant (id, slug, name, tz) VALUES
  ('00000000-0000-0000-0000-0000000000aa', 'demo-fc', 'Demo FC (synthetisch)', 'Europe/Vienna')
ON CONFLICT (slug) DO NOTHING;

-- Tenant-Kontext setzen (demonstriert RLS-Pfad; im initdb als Superuser ohnehin bypass).
SET app.tenant_id = '00000000-0000-0000-0000-0000000000aa';

INSERT INTO person (tenant_id, last_name, first_name, birth_date, status) VALUES
  ('00000000-0000-0000-0000-0000000000aa', 'Testspieler', 'Anton',  '1998-05-01', 'active'),
  ('00000000-0000-0000-0000-0000000000aa', 'Musterfrau',  'Berta',  '2001-09-16', 'active'),
  ('00000000-0000-0000-0000-0000000000aa', 'Beispiel',    'Cäsar',  '2012-01-20', 'active')
ON CONFLICT DO NOTHING;

INSERT INTO organisation (tenant_id, name, legal_form, uid_atu, status) VALUES
  ('00000000-0000-0000-0000-0000000000aa', 'Muster Sponsor GmbH (synthetisch)', 'GmbH', 'ATU00000000', 'active')
ON CONFLICT DO NOTHING;

RESET app.tenant_id;
