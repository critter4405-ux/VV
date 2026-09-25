// VV Worker — Modul M05 „Mitglieder": Executor für eingelöste Vier-Augen-Freigaben + Tagesjob.
// ADR-06: idempotent, keine autonome Grenzüberschreitung. Der Worker ENTSCHEIDET nichts: er führt
// nur aus, was ein fremder, berechtigter Mensch freigegeben hat. Die DB-Funktion m05_execute prüft
// Bindung (Antrag ↔ Freigabe ↔ Parameter-Hash), Freigeber-Recht, Ablauf, Perioden-Version und löst
// die Freigabe ATOMAR mit der Wirkung ein (ein Fehler => Rollback, Freigabe bleibt unverbraucht).
import type { Pool } from "pg";
import { getEffect } from "../agents/effects.ts";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const BATCH = /^[A-Za-z0-9._-]{3,64}$/;

/** Topics, die dieser Consumer verarbeitet (Worker claimt NUR diese, R5). */
export const M05_TOPICS = ["m05.execute", "m05.import.approved"] as const;

/** Quelle der freigegebenen Import-Zeilen (Sync/Q05-Engine, eigener Bauschritt). Liefert GENAU die
 *  Zeilen, deren Hash freigegeben wurde; m05_import_apply prüft Hash + Anzahl erneut. */
export interface ImportRowSource {
  rowsFor(tenantId: string, batchRef: string): Promise<unknown[] | null>;
}
/** Solange die Q05-Engine nicht gebaut ist: keine Quelle -> sichtbarer Fehlschlag (Retry -> DLQ). */
export const NO_IMPORT_SOURCE: ImportRowSource = { rowsFor: async () => null };

export interface OutboxLike { id: string; tenant_id: string; topic: string; payload: unknown }
export type Db = Pick<Pool, "connect">;

async function inTenant<T>(db: Db, tenantId: string, fn: (q: (sql: string, p?: unknown[]) => Promise<any[]>) => Promise<T>): Promise<T> {
  if (!UUID.test(tenantId)) throw new Error("m05: ungültiger Tenant (fail-closed)");
  const client = await db.connect();
  try {
    await client.query("BEGIN");
    await client.query("SELECT set_config('app.tenant_id', $1, true)", [tenantId]);
    const out = await fn(async (sql, p) => (await client.query(sql, p)).rows);
    await client.query("COMMIT");
    return out;
  } catch (err) {
    await client.query("ROLLBACK");
    throw err;
  } finally {
    client.release();
  }
}

/** true = Topic gehörte zu M05 und wurde verarbeitet. Fehler werfen -> Outbox-Retry/DLQ. */
export async function handleM05Outbox(row: OutboxLike, db: Db,
                                      importSource: ImportRowSource = NO_IMPORT_SOURCE): Promise<boolean> {
  if (row.topic === "m05.import.approved") return handleImportApproved(row, db, importSource);
  if (row.topic !== "m05.execute") return false;
  const approvalId = (row.payload as { approval_id?: unknown } | null)?.approval_id;
  if (typeof approvalId !== "string" || !UUID.test(approvalId)) {
    throw new Error("m05.execute: ungültige approval_id (fail-closed)");
  }
  // Nur registrierte, bindende M05-Effekte sind über diesen Pfad erreichbar (Effekt-Registry, G1).
  for (const eff of ["m05.membership.terminate", "m05.membership.anonymize"]) {
    if (!getEffect(eff)?.binding) throw new Error(`Effekt ${eff} nicht als bindend registriert (fail-closed)`);
  }
  const res = await inTenant(db, row.tenant_id, (q) => q("SELECT m05_execute($1) AS r", [approvalId]));
  console.log(`[vv-worker] m05.execute ${approvalId}: ${JSON.stringify(res[0]?.r ?? null)}`);
  return true;
}

/** Reparaturrunde 1 (Gemini G-1): freigegebener Import wird angewendet, sobald die Q05-Engine die
 *  freigegebenen Zeilen liefert. Ohne Quelle: eindeutiger Fehler -> Retry -> DLQ (überwacht, ADR-11) —
 *  nie stilles Liegenbleiben, nie Quittung ohne Wirkung. */
async function handleImportApproved(row: OutboxLike, db: Db, source: ImportRowSource): Promise<boolean> {
  const batchRef = (row.payload as { batch_ref?: unknown } | null)?.batch_ref;
  if (typeof batchRef !== "string" || !BATCH.test(batchRef)) {
    throw new Error("m05.import.approved: ungültige batch_ref (fail-closed)");
  }
  if (!UUID.test(row.tenant_id)) throw new Error("m05: ungültiger Tenant (fail-closed)");
  const rows = await source.rowsFor(row.tenant_id, batchRef);
  if (!rows) {
    throw new Error(`Import ${batchRef} freigegeben, aber keine Q05-Zeilenquelle angebunden — wartet (Eskalation via DLQ)`);
  }
  const res = await inTenant(db, row.tenant_id, (q) => q("SELECT m05_import_apply($1, $2::jsonb) AS r",
    [batchRef, JSON.stringify(rows)]));
  console.log(`[vv-worker] m05.import.approved ${batchRef}: ${JSON.stringify(res[0]?.r ?? null)}`);
  return true;
}

/** Tagesjob je Mandant (Stichtag, Sperre, Aging-up-Vorschläge, Anonymisierungs-ANTRÄGE). */
export async function runM05Daily(db: Db): Promise<Record<string, unknown>> {
  const client = await db.connect();
  let tenants: string[];
  try {
    tenants = (await client.query("SELECT id FROM tenant ORDER BY id")).rows.map((r: { id: string }) => r.id);
  } finally {
    client.release();
  }
  const out: Record<string, unknown> = {};
  for (const t of tenants) {
    try {
      out[t] = (await inTenant(db, t, (q) => q("SELECT m05_job_daily() AS r")))[0]?.r;
    } catch (err) {
      out[t] = { error: String(err).slice(0, 200) };   // ein Mandant blockiert nicht die anderen
    }
  }
  return out;
}
