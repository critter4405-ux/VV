// VV Modul BASIS-01 (Person) — Beispiel-Aktion (Stage-0-Skeleton).
// Geht durch den zentralen Policy-Prüfpunkt (ADR-04) — Pflicht, validator-erzwungen.
// Cross-Modul-Import verboten (ADR-02): nur ../../platform + eigenes Modul.
import { checkPolicy } from "../../platform/policy.ts";
import { withTenant } from "../../platform/tenant.ts";
import { writeAudit } from "../../platform/audit.ts";
import { pool } from "../../db.ts";

export async function listPersons(ctx: { tenantId: string; actor: string; scopeNode: string }) {
  const decision = await checkPolicy({
    tenantId: ctx.tenantId,
    actor: ctx.actor,
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
    return await withTenant(client, ctx.tenantId, async () => {
      const { rows } = await client.query(
        "SELECT id, last_name, first_name, status FROM person ORDER BY last_name",
      );
      await writeAudit(client, { action: "app.person.list" });
      return { ok: true as const, rows };
    }, ctx.actor);
  } finally {
    client.release();
  }
}
