// VV Worker — DB-Pool (ADR-01). EIGENE Rolle vv_worker (NOSUPERUSER/NOBYPASSRLS), NICHT vv_app
// (Review-Runde 2, Codex #4-new / Gemini #1). Nur der Worker darf die Outbox-Consumer-Funktionen
// ausführen; die Verbindung nutzt daher WORKER_DATABASE_URL (vv_worker), nicht DATABASE_URL (vv_app).
import { Pool } from "pg";

const connectionString = process.env.WORKER_DATABASE_URL;
if (!connectionString) throw new Error("WORKER_DATABASE_URL fehlt (vv_worker-Verbindung, fail-fast)");

export const pool = new Pool({ connectionString, max: 4 });

export interface OutboxRow {
  id: string; tenant_id: string; topic: string; payload: unknown; lease_token: string;
}

/** Atomarer Claim über die SECURITY-DEFINER-Funktion (RLS-übergreifend, ohne BYPASSRLS).
 *  M05-Reparaturrunde 1: NUR die Topics, die dieser Worker konsumiert (R5/H-06) — alle anderen
 *  Events bleiben geparkt; jede geclaimte Zeile trägt ein Lease-Token (R8/H-07, Fencing). */
export async function claimOutbox(max: number, topics: readonly string[]): Promise<OutboxRow[]> {
  if (topics.length === 0) return [];
  const { rows } = await pool.query(
    "SELECT id, tenant_id, topic, payload, lease_token FROM vv_outbox_claim($1, $2::text[])", [max, topics]);
  return rows as OutboxRow[];
}

/** Quittieren nur mit gültigem Lease-Token; false = Lease verloren (anderer Worker hat übernommen). */
export async function markOutboxDone(id: string, leaseToken: string): Promise<boolean> {
  const { rows } = await pool.query("SELECT vv_outbox_done($1, $2) AS ok", [id, leaseToken]);
  return rows[0]?.ok === true;
}

/** Fehlgeschlagene Zustellung (Token-gebunden): nach N Versuchen DLQ (dead_at), sonst Retry. */
export async function markOutboxFail(id: string, leaseToken: string, err: string): Promise<boolean> {
  const { rows } = await pool.query("SELECT vv_outbox_fail($1, $2, $3, 5) AS ok", [id, leaseToken, err]);
  return rows[0]?.ok === true;
}
