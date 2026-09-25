// VV Modul BASIS-02 (Rollen & Rechte) — Beispiel-Aktion (Stage-0-Skeleton).
// Geht durch den zentralen Policy-Prüfpunkt (ADR-04). Kein Cross-Modul-Import (ADR-02).
// C-1 (Kontext-Signatur): Lesen nur über die geprüfte DB-Funktion basis02_list_role_assignments().
import { checkPolicy } from "../../platform/policy.ts";
import { withTenant } from "../../platform/tenant.ts";
import { pool } from "../../db.ts";

export async function listRoleAssignments(ctx: { tenantId: string; actor: string; ticket: string; scopeNode: string }) {
  const decision = await checkPolicy({
    tenantId: ctx.tenantId,
    actor: ctx.actor,
    ticket: ctx.ticket,
    resource: "role_assignment",
    action: "read",
    scopeNode: ctx.scopeNode,
  });
  if (!decision.allowed) {
    return { ok: false as const, reason: decision.reason };
  }
  const client = await pool.connect();
  try {
    return await withTenant(client, ctx.ticket, async () => {
      const { rows } = await client.query(
        "SELECT id, person_id, role_type, scope_node_id, valid_to FROM basis02_list_role_assignments()");
      return { ok: true as const, rows };
    });
  } finally {
    client.release();
  }
}
