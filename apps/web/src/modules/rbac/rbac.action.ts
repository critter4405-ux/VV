// VV Modul BASIS-02 (Rollen & Rechte) — Beispiel-Aktion (Stage-0-Skeleton).
// Geht durch den zentralen Policy-Prüfpunkt (ADR-04). Kein Cross-Modul-Import (ADR-02).
import { checkPolicy } from "../../platform/policy.ts";
import { withTenant } from "../../platform/tenant.ts";
import { writeAudit } from "../../platform/audit.ts";
import { pool } from "../../db.ts";

export async function listRoleAssignments(ctx: { tenantId: string; actor: string; scopeNode: string }) {
  const decision = await checkPolicy({
    tenantId: ctx.tenantId,
    actor: ctx.actor,
    resource: "role_assignment",
    action: "read",
    scopeNode: ctx.scopeNode,
  });
  if (!decision.allowed) {
    return { ok: false as const, reason: decision.reason };
  }
  const client = await pool.connect();
  try {
    return await withTenant(client, ctx.tenantId, async () => {
      const { rows } = await client.query(
        "SELECT id, person_id, role_type, scope_node, valid_to FROM role_assignment",
      );
      await writeAudit(client, { tenantId: ctx.tenantId, actor: ctx.actor, action: "rbac.list" });
      return { ok: true as const, rows };
    });
  } finally {
    client.release();
  }
}
