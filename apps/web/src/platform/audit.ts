// VV Platform — Audit-Schreiber (ADR-05, BASIS-03), WP2-gehärtet.
// Review-Befund Codex #6 / Gemini B: Hash-Kette darf NICHT im App-Layer per read-then-write
// gebildet werden (Race/Fork). Sie wird jetzt DB-seitig im Trigger `vv_audit_chain` unter
// per-Mandant-Advisory-Lock berechnet (siehe 0003_audit_outbox.sql). Der App-Schreiber fügt
// nur die Fachfelder ein — in DERSELBEN Transaktion wie die Datenänderung (withTenant).
import type { PoolClient } from "pg";

export async function writeAudit(
  client: PoolClient,
  entry: { tenantId: string; actor: string; action: string; subjectRef?: string; payload?: unknown },
): Promise<void> {
  await client.query(
    `INSERT INTO audit_log (tenant_id, actor, action, subject_ref, payload)
     VALUES ($1, $2, $3, $4, $5)`,
    [entry.tenantId, entry.actor, entry.action, entry.subjectRef ?? null, entry.payload ?? {}],
  );
  // prev_hash/entry_hash werden vom BEFORE-INSERT-Trigger gesetzt (kanonisch, fork-frei).
}
