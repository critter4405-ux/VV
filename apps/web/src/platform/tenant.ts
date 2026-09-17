// VV Platform — Tenant-Kontext (ADR-01). Setzt app.tenant_id pro Request/Transaktion.
import type { PoolClient } from "pg";

export async function withTenant<T>(
  client: PoolClient,
  tenantId: string,
  fn: () => Promise<T>,
): Promise<T> {
  // SET LOCAL gilt nur innerhalb der Transaktion -> RLS-Filter (ADR-01).
  await client.query("SELECT set_config('app.tenant_id', $1, true)", [tenantId]);
  return fn();
}
