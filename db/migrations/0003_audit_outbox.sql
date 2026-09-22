-- VV Migration 0003 — Audit-Log + Outbox (ADR-05), WP2-gehärtet
-- Hash-Kette wird DB-seitig in einem BEFORE-INSERT-Trigger unter per-Mandant-Advisory-Lock
-- berechnet -> keine App-Read-then-write-Race, kein Ketten-Fork (Review-Befund Gemini B / Codex #6).
-- Hash deckt ALLE unveränderlichen Felder ab. UPDATE/DELETE per Trigger hart blockiert.

CREATE TABLE IF NOT EXISTS audit_log (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id    uuid NOT NULL REFERENCES tenant(id),
    occurred_at  timestamptz NOT NULL DEFAULT now(),
    actor        text NOT NULL,
    action       text NOT NULL,
    subject_ref  text,                          -- ID/Pseudonym (B03-2), nie Klartext
    payload      jsonb NOT NULL DEFAULT '{}'::jsonb,
    prev_hash    text,                           -- vom Trigger gesetzt
    entry_hash   text NOT NULL DEFAULT ''        -- vom Trigger überschrieben
);
ALTER TABLE audit_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_log FORCE ROW LEVEL SECURITY;
CREATE POLICY audit_log_tenant_isolation ON audit_log
    USING (tenant_id = vv_current_tenant())
    WITH CHECK (tenant_id = vv_current_tenant());

-- Hash-Kette je Mandant, serialisiert per Advisory-Lock (kein Fork bei Nebenläufigkeit).
-- Review-Runde 2, Codex #6-new / Gemini #2: die alte Pipe-Verkettung (a||'|'||b) war NICHT
-- injektiv (ein '|' in einem Feld konnte Felder verschieben) und ließ die id aus. Jetzt:
-- KANONISCHE Kodierung über jsonb_build_object (Postgres normalisiert Schlüsselreihenfolge)
-- inkl. id + prev_hash -> eindeutig, kollisionsfrei, vollständig kettenfixierend.
CREATE OR REPLACE FUNCTION vv_audit_chain() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE prev text;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtextextended(NEW.tenant_id::text, 0));
  SELECT entry_hash INTO prev FROM audit_log
    WHERE tenant_id = NEW.tenant_id ORDER BY id DESC LIMIT 1;
  NEW.prev_hash := prev;
  NEW.entry_hash := encode(
    digest(
      convert_to(
        jsonb_build_object(
          'id',          NEW.id,          -- vor BEFORE-INSERT bereits aus IDENTITY belegt
          'tenant_id',   NEW.tenant_id,
          'actor',       NEW.actor,
          'action',      NEW.action,
          'subject_ref', NEW.subject_ref,
          'payload',     NEW.payload,      -- jsonb: kanonisch normalisiert
          'occurred_at', NEW.occurred_at,
          'prev_hash',   prev
        )::text, 'UTF8'),
      'sha256'), 'hex');
  RETURN NEW;
END $$;
CREATE TRIGGER audit_log_chain BEFORE INSERT ON audit_log
  FOR EACH ROW EXECUTE FUNCTION vv_audit_chain();

-- Append-only: UPDATE/DELETE hart abweisen (auch für Tabelleneigentümer).
CREATE OR REPLACE FUNCTION vv_audit_block() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'audit_log ist append-only (Operation % nicht erlaubt).', TG_OP;
END $$;
CREATE TRIGGER audit_log_no_change BEFORE UPDATE OR DELETE ON audit_log
  FOR EACH ROW EXECUTE FUNCTION vv_audit_block();
-- Auch TRUNCATE sperren (sonst ließe sich die gesamte Kette in einem Schritt tilgen).
CREATE TRIGGER audit_log_no_truncate BEFORE TRUNCATE ON audit_log
  FOR EACH STATEMENT EXECUTE FUNCTION vv_audit_block();

-- Kopf-Anchoring (ADR-05, v1.1): reale Offsite-WORM-Senke = spätere Infra-Stufe (WP7/ADR-11).
CREATE TABLE IF NOT EXISTS audit_anchor (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id    uuid NOT NULL REFERENCES tenant(id),
    anchored_at  timestamptz NOT NULL DEFAULT now(),
    head_hash    text NOT NULL,
    reason       text NOT NULL
);
ALTER TABLE audit_anchor ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_anchor FORCE ROW LEVEL SECURITY;
CREATE POLICY audit_anchor_tenant_isolation ON audit_anchor
    USING (tenant_id = vv_current_tenant())
    WITH CHECK (tenant_id = vv_current_tenant());

-- Transactional Outbox (ADR-05). Idempotenz-Schlüssel je Mandant (Review-Befund Codex #13).
CREATE TABLE IF NOT EXISTS outbox (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       uuid NOT NULL REFERENCES tenant(id),
    topic           text NOT NULL,
    payload         jsonb NOT NULL,
    created_at      timestamptz NOT NULL DEFAULT now(),
    locked_until    timestamptz,                 -- Leasing für FOR UPDATE SKIP LOCKED (WP4)
    processed_at    timestamptz,
    attempts        int NOT NULL DEFAULT 0,       -- Zustellversuche (Review-Runde 3, Gemini MITTEL)
    dead_at         timestamptz,                  -- DLQ: nach N Fehlversuchen aussortiert
    last_error      text,
    idempotency_key text NOT NULL,
    CONSTRAINT outbox_idem_uk UNIQUE (tenant_id, idempotency_key)
);
ALTER TABLE outbox ENABLE ROW LEVEL SECURITY;
ALTER TABLE outbox FORCE ROW LEVEL SECURITY;
CREATE POLICY outbox_tenant_isolation ON outbox
    USING (tenant_id = vv_current_tenant())
    WITH CHECK (tenant_id = vv_current_tenant());

-- Outbox-Consumer (WP4/Review Codex #13): mandantenübergreifende Zustellung durch den Worker.
-- SECURITY DEFINER (Eigentümer = Bootstrap), damit der Worker über RLS hinweg zustellen kann,
-- OHNE der App-Rolle BYPASSRLS zu geben. Atomarer Claim per FOR UPDATE SKIP LOCKED + Leasing.
-- Review-Runde 4, Gemini (MITTEL): der Claim filterte nicht auf `attempts`. Bei einem HARTEN
-- Worker-Crash (OOM/kill) läuft der catch-Block nicht, vv_outbox_fail wird nie gerufen -> das Lease
-- läuft ab und dasselbe Giftelement wird endlos neu geholt. Jetzt: (1) Reaper verschiebt Einträge,
-- die die Versuchsgrenze erreicht haben, DB-seitig in die DLQ (dead_at) — auch ohne vv_outbox_fail;
-- (2) der Claim holt nur noch Einträge mit attempts < Grenze. Grenze = 5 (wie vv_outbox_fail-Default).
CREATE OR REPLACE FUNCTION vv_outbox_claim(max_rows int DEFAULT 10)
RETURNS SETOF outbox LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  -- (1) Reaper: über der Versuchsgrenze -> DLQ, unabhängig davon ob vv_outbox_fail lief.
  UPDATE outbox SET dead_at = now(), last_error = coalesce(last_error, 'max attempts (hard crash reaper)')
    WHERE processed_at IS NULL AND dead_at IS NULL AND attempts >= 5;
  -- (2) Claim nur unterhalb der Grenze.
  RETURN QUERY
    UPDATE outbox SET locked_until = now() + interval '1 minute', attempts = attempts + 1
    WHERE id IN (
      SELECT id FROM outbox
      WHERE processed_at IS NULL AND dead_at IS NULL AND attempts < 5
        AND (locked_until IS NULL OR locked_until < now())
      ORDER BY created_at
      FOR UPDATE SKIP LOCKED
      LIMIT max_rows)
    RETURNING *;
END $$;

CREATE OR REPLACE FUNCTION vv_outbox_done(p_id uuid)
RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  UPDATE outbox SET processed_at = now(), locked_until = NULL WHERE id = p_id;
$$;

-- Fehlschlag: nach p_max Versuchen in die DLQ (dead_at), sonst Lease sofort freigeben (Retry).
-- Verhindert Poison-Pill-Endlosschleifen (Review-Runde 3, Gemini MITTEL).
CREATE OR REPLACE FUNCTION vv_outbox_fail(p_id uuid, p_err text, p_max int DEFAULT 5)
RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  UPDATE outbox SET
    last_error   = left(p_err, 2000),
    dead_at      = CASE WHEN attempts >= p_max THEN now() ELSE NULL END,
    locked_until = CASE WHEN attempts >= p_max THEN locked_until ELSE NULL END
  WHERE id = p_id;
$$;

REVOKE ALL ON FUNCTION vv_outbox_claim(int) FROM PUBLIC;
REVOKE ALL ON FUNCTION vv_outbox_done(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION vv_outbox_fail(uuid, text, int) FROM PUBLIC;
-- EXECUTE-Grants an vv_worker folgen in 0005 (nach Rollen-Existenz).
