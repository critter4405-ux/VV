// VV Agenten — Freigabe-Speicher (ADR-07). Review-Runde 3, Codex #1:
// Der Vier-Augen-Zustand (approved/Freigeber/Reviewer/Token) darf NICHT aus Aufrufer-Metadaten
// stammen. Er liegt in der DB-Tabelle `approval`; der Consume ist atomar, scope-gebunden,
// ablaufend und einmalig (SECURITY-DEFINER-Funktion vv_consume_approval). Diese Schnittstelle
// kapselt genau diesen atomaren Einmal-Consume.

import type { Pool } from "pg";

export interface ApprovalStore {
  /** Löst genau EINE gültige Freigabe für (effectId, subjectRef) atomar ein.
   *  Wirft, wenn keine 'approved', nicht abgelaufene, noch nicht eingelöste, fremd-genehmigte
   *  Freigabe existiert. Kein Aufrufer-Zustand — die DB entscheidet. */
  consume(tenantId: string, effectId: string, subjectRef: string): Promise<void>;
}

/** Produktions-Store: verbraucht die Freigabe in derselben Transaktion, tenant-lokal (RLS). */
export class DbApprovalStore implements ApprovalStore {
  constructor(private pool: Pool) {}

  async consume(tenantId: string, effectId: string, subjectRef: string): Promise<void> {
    if (!tenantId) throw new Error("consume: leerer tenantId (deny-by-default)");
    const client = await this.pool.connect();
    try {
      await client.query("BEGIN");
      await client.query("SELECT set_config('app.tenant_id', $1, true)", [tenantId]);
      const { rows } = await client.query(
        "SELECT vv_consume_approval($1, $2) AS id", [effectId, subjectRef]);
      if (!rows[0] || rows[0].id == null) {
        throw new Error(
          `Keine gültige Vier-Augen-Freigabe für '${effectId}'/${subjectRef} ` +
          "(fehlend/abgelaufen/bereits eingelöst/Selbst-Freigabe) — verweigert");
      }
      await client.query("COMMIT");
    } catch (err) {
      await client.query("ROLLBACK");
      throw err;
    } finally {
      client.release();
    }
  }
}
