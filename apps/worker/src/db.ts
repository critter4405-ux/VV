// VV Worker — DB-Pool (ADR-01). App-Rolle vv_app (NOSUPERUSER/NOBYPASSRLS).
import { Pool } from "pg";

export const pool = new Pool({ connectionString: process.env.DATABASE_URL, max: 4 });

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
