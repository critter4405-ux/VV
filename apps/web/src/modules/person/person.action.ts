// VV Modul BASIS-01 (Person) — Beispiel-Aktion (Stage-0-Skeleton).
// Geht durch den zentralen Policy-Prüfpunkt (ADR-04) — Pflicht, validator-erzwungen.
// Cross-Modul-Import verboten (ADR-02): nur ../../platform + eigenes Modul.
// C-1 (Kontext-Signatur): KEIN direkter Tabellenzugriff mehr — die geprüfte DB-Funktion basis01_list_persons()
// prüft das Recht erneut und protokolliert selbst; der Kontext kommt nur aus dem signierten Ticket.
import { checkPolicy } from "../../platform/policy.ts";
import { withTenant } from "../../platform/tenant.ts";
import { pool } from "../../db.ts";

export async function listPersons(ctx: { tenantId: string; actor: string; ticket: string; scopeNode: string }) {
  const decision = await checkPolicy({
    tenantId: ctx.tenantId,
    actor: ctx.actor,
    ticket: ctx.ticket,
    resource: "person",
    action: "read",
    scopeNode: ctx.scopeNode,
    dataClass: "S",
  });
  if (!decision.allowed) {
    return { ok: false as const, reason: decision.reason };
  }
  const client = await pool.connect();
  try {
    return await withTenant(client, ctx.ticket, async () => {
      const { rows } = await client.query("SELECT id, last_name, first_name, status FROM basis01_list_persons()");
      return { ok: true as const, rows };
    });
  } finally {
    client.release();
  }
}
