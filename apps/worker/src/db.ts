// VV Worker — DB-Pool (ADR-01). EIGENE Rolle vv_worker (NOSUPERUSER/NOBYPASSRLS), NICHT vv_app
// (Review-Runde 2, Codex #4-new / Gemini #1). Nur der Worker darf die Outbox-Consumer-Funktionen
// ausführen; die Verbindung nutzt daher WORKER_DATABASE_URL (vv_worker), nicht DATABASE_URL (vv_app).
import { Pool } from "pg";

const connectionString = process.env.WORKER_DATABASE_URL;
if (!connectionString) throw new Error("WORKER_DATABASE_URL fehlt (vv_worker-Verbindung, fail-fast)");

export const pool = new Pool({ connectionString, max: 4 });

export interface OutboxRow {
  id: string; tenant_id: string; topic: string; payload: unknown;
}

/** Atomarer Claim über die SECURITY-DEFINER-Funktion (RLS-übergreifend, ohne BYPASSRLS). */
export async function claimOutbox(max = 10): Promise<OutboxRow[]> {
  const { rows } = await pool.query(
    "SELECT id, tenant_id, topic, payload FROM vv_outbox_claim($1)", [max]);
  return rows as OutboxRow[];
}

export async function markOutboxDone(id: string): Promise<void> {
  await pool.query("SELECT vv_outbox_done($1)", [id]);
}
