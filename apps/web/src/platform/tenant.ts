// VV Platform — Tenant-Kontext (ADR-01), WP1-gehärtet.
// Review-Befund Codex #3 / Gemini A: `set_config(...,true)` (SET LOCAL) wirkt NUR in einer
// Transaktion. Ohne BEGIN war der Tenant-Kontext unwirksam (RLS fiel closed) bzw. hätte bei
// einem "Fix" auf Session-Ebene im Connection-Pool Daten über Mandantengrenzen geleakt.
// Daher: harter Transaktions-Wrapper. SET LOCAL ist damit PgBouncer-Transaction-Mode-tauglich.
import type { PoolClient } from "pg";

/**
 * WICHTIG: `tenantId` MUSS serverseitig aus verifizierten OIDC-Claims/Mitgliedschaften
 * stammen (BASIS-10/ADR-03) — niemals ungeprüft aus dem Request. Die Durchsetzung erfolgt
 * am Auth-Layer (WP6); diese Funktion setzt den bereits verifizierten Tenant transaktional.
 */
export async function withTenant<T>(
  client: PoolClient,
  tenantId: string,
  fn: () => Promise<T>,
): Promise<T> {
  if (!tenantId) throw new Error("withTenant: leerer tenantId (deny-by-default)");
  await client.query("BEGIN");
  try {
    // SET LOCAL gilt nur innerhalb DIESER Transaktion -> RLS-Filter, pool-sicher.
    await client.query("SELECT set_config('app.tenant_id', $1, true)", [tenantId]);
    const result = await fn();
    await client.query("COMMIT");
    return result;
  } catch (err) {
    await client.query("ROLLBACK");
    throw err;
  }
}
