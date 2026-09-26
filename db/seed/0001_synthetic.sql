-- VV Seed 0001 — AUSSCHLIESSLICH SYNTHETISCHE Testdaten (K31/ADR-10).
-- HARTE REGEL: niemals echte/personenbezogene Daten. Alle Namen frei erfunden.
-- Zwei Mandanten, damit der RLS-Isolationstest (AK-08) ehrlich nachweisbar ist (WP7).

INSERT INTO tenant (id, slug, name, tz) VALUES
  ('00000000-0000-0000-0000-0000000000aa', 'demo-fc', 'Demo FC (synthetisch)',  'Europe/Vienna'),
  ('00000000-0000-0000-0000-0000000000bb', 'demo-b',  'Demo B (synthetisch)',   'Europe/Vienna')
ON CONFLICT (slug) DO NOTHING;

-- C-1 (Kontext-Signatur): Kontext nur noch geprüft — Betreiber-Seed nutzt den Bootstrap-Kontext (Superuser).
BEGIN;
SELECT vv_bootstrap_context('00000000-0000-0000-0000-0000000000aa', 'system:seed');
INSERT INTO person (tenant_id, last_name, first_name, birth_date, status) VALUES
  ('00000000-0000-0000-0000-0000000000aa', 'Testspieler', 'Anton',  '1998-05-01', 'active'),
  ('00000000-0000-0000-0000-0000000000aa', 'Musterfrau',  'Berta',  '2001-09-16', 'active'),
  ('00000000-0000-0000-0000-0000000000aa', 'Beispiel',    'Cäsar',  '2012-01-20', 'active');
INSERT INTO organisation (tenant_id, name, legal_form, uid_atu, status) VALUES
  ('00000000-0000-0000-0000-0000000000aa', 'Muster Sponsor GmbH (synthetisch)', 'GmbH', 'ATU00000000', 'active');

SELECT vv_bootstrap_context('00000000-0000-0000-0000-0000000000bb', 'system:seed');
INSERT INTO person (tenant_id, last_name, first_name, birth_date, status) VALUES
  ('00000000-0000-0000-0000-0000000000bb', 'FremdMandant', 'Zoe', '1990-03-03', 'active');

COMMIT;
