// VV Platform — Tenant-/Actor-Kontext (ADR-01), C-1 „Kontext-Signatur“ (Grill P58).
// Früher setzte die App app.tenant_id/app.actor per set_config — mit den DB-Zugangsdaten der App frei fälschbar
// (Codex C-1, P54). Jetzt übergibt die App NUR noch das signierte Ticket; die DB prüft Signatur, Ablauf,
// Schlüssel-Kennung und Einmal-Nutzung und setzt den Kontext selbst (vv_set_context). Die App kann Mandant und
// Nutzer weder wählen noch wechseln (ein Kontext je Transaktion).
// Transaktions-Wrapper bleibt Pflicht: der geprüfte Kontext gilt genau für diese Transaktion (pool-/PgBouncer-sicher).
import type { PoolClient } from "pg";

export async function withTenant<T>(client: PoolClient, ticket: string, fn: () => Promise<T>): Promise<T> {
  if (!ticket) throw new Error("withTenant: kein Ticket (deny-by-default)");
  await client.query("BEGIN");
  try {
    await client.query("SELECT vv_set_context($1)", [ticket]);
    const result = await fn();
    await client.query("COMMIT");
    return result;
  } catch (err) {
    await client.query("ROLLBACK");
    throw err;
  }
}
