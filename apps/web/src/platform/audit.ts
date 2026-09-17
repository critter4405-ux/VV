// VV Platform — Audit-Schreiber (ADR-05, BASIS-03). Append-only Hash-Kette.
import { createHash } from "node:crypto";
import type { PoolClient } from "pg";

export function chainHash(prevHash: string | null, content: unknown): string {
  return createHash("sha256")
    .update((prevHash ?? "") + JSON.stringify(content))
    .digest("hex");
}

export async function writeAudit(
  client: PoolClient,
  entry: { tenantId: string; actor: string; action: string; subjectRef?: string; payload?: unknown },
): Promise<void> {
  const { rows } = await client.query(
    "SELECT entry_hash FROM audit_log WHERE tenant_id = $1 ORDER BY id DESC LIMIT 1",
    [entry.tenantId],
  );
  const prev = rows[0]?.entry_hash ?? null;
  const content = { a: entry.action, s: entry.subjectRef ?? null, p: entry.payload ?? {} };
  const hash = chainHash(prev, content);
  await client.query(
    `INSERT INTO audit_log (tenant_id, actor, action, subject_ref, payload, prev_hash, entry_hash)
     VALUES ($1,$2,$3,$4,$5,$6,$7)`,
    [entry.tenantId, entry.actor, entry.action, entry.subjectRef ?? null, entry.payload ?? {}, prev, hash],
  );
}
