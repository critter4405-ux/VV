// VV Platform — Audit-Schreiber (ADR-05, BASIS-03).
// Hash-Kette wird DB-seitig im Trigger `vv_audit_chain` gebildet (fork-frei, Advisory-Lock).
// M05-Reparaturrunde 1 (R1/B-02): Die App darf NICHT mehr direkt in audit_log schreiben (vorher konnte
// vv_app Actor/Aktion/Zeit frei setzen und per OVERRIDING SYSTEM VALUE die id erzwingen). Jetzt nur
// noch über vv_audit_log(): Actor = transaktionsgebundener app.actor (verifizierte OIDC-Claims, via
// withTenant), Serverzeit, reservierte Fach-Präfixe gesperrt — erlaubt sind nur `app.*` / `policy.*`.
import type { PoolClient } from "pg";

export async function writeAudit(
  client: PoolClient,
  entry: { action: `app.${string}` | `policy.${string}`; subjectRef?: string; payload?: unknown },
): Promise<void> {
  // Muss INNERHALB von withTenant(client, tenantId, fn, actor) laufen (Tenant + Actor gesetzt).
  await client.query("SELECT vv_audit_log($1, $2, $3::jsonb)",
    [entry.action, entry.subjectRef ?? null, JSON.stringify(entry.payload ?? {})]);
}
