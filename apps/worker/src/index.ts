// VV Agenten-/Job-Worker — Stage-0-Einstieg (ADR-06), WP4.
// pg-boss für getriggerte Jobs + realer Outbox-Consumer (FOR UPDATE SKIP LOCKED via
// SECURITY-DEFINER-Funktion). Kein Job überschreitet autonom eine harte Grenze — er legt
// ein Freigabe-Objekt an (Vier-Augen, siehe agents/vier_augen.ts).
import PgBoss from "pg-boss";
import { writeFileSync } from "node:fs";
import { claimOutbox, markOutboxDone, markOutboxFail } from "./db.ts";

function beat() {
  try { writeFileSync("/tmp/vv-worker-alive", String(Date.now())); } catch { /* ignore */ }
}

async function pollOutbox() {
  try {
    const rows = await claimOutbox(10);
    for (const row of rows) {
      try {
        // Stage-0: nur protokollieren (Zustellung/Agentenlogik folgt beim Modul-Bau).
        console.log(`[vv-worker] outbox ${row.id} topic=${row.topic} tenant=${row.tenant_id}`);
        await markOutboxDone(row.id);
      } catch (jobErr) {
        // Poison-Pill-Schutz: Fehlversuch zählen, nach N in die DLQ (dead_at) statt Endlos-Reclaim.
        console.error(`[vv-worker] outbox ${row.id} Zustellfehler:`, jobErr);
        await markOutboxFail(row.id, String(jobErr)).catch(() => { /* best effort */ });
      }
    }
  } catch (err) {
    console.error("[vv-worker] outbox poll error:", err);
  }
}

async function main() {
  // pg-boss im eigenen Schema (Eigentümer vv_worker) — kein DB-weites CREATE nötig (Codex #3-new).
  const boss = new PgBoss({ connectionString: process.env.WORKER_DATABASE_URL, schema: "pgboss" });
  boss.on("error", (err) => console.error("[vv-worker] pg-boss error:", err));
  await boss.start();

  const QUEUE = "reminder.dispatch";
  await boss.createQueue(QUEUE);
  await boss.work(QUEUE, async ([job]) => {
    console.log("[vv-worker] reminder job", job.id); // Trivial-Routine (stehende Klasse-Freigabe, B09-1)
  });

  beat();
  setInterval(beat, 30_000);
  setInterval(pollOutbox, 5_000);
  console.log("[vv-worker] Stage-0-Skeleton bereit (pg-boss + Outbox-Consumer).");
}

main().catch((err) => { console.error("[vv-worker] Startfehler:", err); process.exit(1); });
