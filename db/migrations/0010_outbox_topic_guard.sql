-- VV Migration 0010 — Outbox: reservierte Modul-Topics nur über die Fachfunktionen (M05-Bau)
--
-- BEFUND (im M05-Selbstcheck vor dem Review): vv_app hat seit Stage 0 INSERT auf `outbox`
-- (Web schreibt Events in der Fach-Transaktion). Damit konnte die Web-Rolle beliebige M05-/BASIS-02-
-- Events FÄLSCHEN, z. B. `m05.membership.ended` (künftige Konsumenten wie BASIS-07 würden reagieren)
-- oder `m05.execute` (der Executor prüft zwar alles, aber Event-Spoofing ist trotzdem eine Lücke).
-- FIX: reservierte Präfixe dürfen nur aus den SECURITY-DEFINER-Fachfunktionen (current_user =
-- vv_definer) bzw. vom Bootstrap geschrieben werden — nicht direkt von vv_app/vv_worker.
-- Stage-0-Topics (frei) bleiben unverändert (Stage-0-Gegenproben unberührt). Idempotent + atomar.

BEGIN;
SET LOCAL client_min_messages = warning;

CREATE OR REPLACE FUNCTION vv_outbox_topic_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF current_user IN ('vv_app', 'vv_worker')
     AND (NEW.topic LIKE 'm05.%' OR NEW.topic LIKE 'basis02.%') THEN
    RAISE EXCEPTION 'outbox: Topic % ist reserviert (nur über Fachfunktionen) — Event-Spoofing verweigert', NEW.topic
      USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION vv_outbox_topic_guard() FROM PUBLIC;

DROP TRIGGER IF EXISTS outbox_topic_guard ON outbox;
CREATE TRIGGER outbox_topic_guard BEFORE INSERT ON outbox
  FOR EACH ROW EXECUTE FUNCTION vv_outbox_topic_guard();

COMMIT;
