// VV Agenten-/Job-Worker — Stage-0-Einstieg (ADR-06), WP4.
// pg-boss für getriggerte Jobs + realer Outbox-Consumer (FOR UPDATE SKIP LOCKED via
// SECURITY-DEFINER-Funktion). Kein Job überschreitet autonom eine harte Grenze — er legt
// ein Freigabe-Objekt an (Vier-Augen, siehe agents/vier_augen.ts).
import { PgBoss } from "pg-boss";
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import { claimOutbox, markOutboxDone, markOutboxFail, pool } from "./db.ts";
import { handleM05Outbox, runM05Daily, M05_TOPICS } from "./jobs/m05.ts";

// Heartbeat für den Compose-Healthcheck. Eigener Ordner statt des gemeinsamen /tmp (CodeQL
// js/insecure-temporary-file: vorhersagbarer Name in einem für alle beschreibbaren Verzeichnis).
const HEARTBEAT_FILE = process.env.VV_HEARTBEAT_FILE ?? "/run/vv-worker/alive";

function beat() {
  try {
    mkdirSync(dirname(HEARTBEAT_FILE), { recursive: true, mode: 0o700 });
    writeFileSync(HEARTBEAT_FILE, String(Date.now()), { mode: 0o600 });
  } catch {
    // Heartbeat ist rein diagnostisch: schlägt er fehl, meldet der Healthcheck „unhealthy“ — der Worker läuft weiter.
  }
}

// Topics, für die dieser Worker einen Consumer hat. Nur diese werden geclaimt (R5/H-06): Events
// ohne Consumer (z. B. m05.membership.* für künftige BASIS-07/M06) bleiben unberührt GEPARKT und
// gehen nicht verloren. Neue Consumer registrieren hier ihre Topics.
const CONSUMED_TOPICS: readonly string[] = [...M05_TOPICS];

async function pollOutbox() {
  try {
    const rows = await claimOutbox(10, CONSUMED_TOPICS);
    for (const row of rows) {
      try {
        const handled = await handleM05Outbox(row, pool);
        if (handled) {
          // Quittieren nur mit gültigem Lease (R8): hat ein anderer Worker nach Lease-Ablauf übernommen,
          // wird dieses Ergebnis verworfen statt dessen Zustellung zu überschreiben.
          if (!(await markOutboxDone(row.id, row.lease_token))) {
            console.warn(`[vv-worker] outbox ${row.id}: Lease verloren — Quittung verworfen (Fencing)`);
          }
        } else {
          // Sollte wegen des Topic-Filters nie passieren — trotzdem NIE ohne Verarbeitung quittieren.
          await markOutboxFail(row.id, row.lease_token, `kein Consumer für Topic ${row.topic}`);
        }
      } catch (jobErr) {
        // Poison-Pill-Schutz: Fehlversuch zählen, nach N in die DLQ (dead_at) statt Endlos-Reclaim.
        console.error(`[vv-worker] outbox ${row.id} Zustellfehler:`, jobErr);
        await markOutboxFail(row.id, row.lease_token, String(jobErr)).catch(() => { /* best effort */ });
      }
    }
  } catch (err) {
    console.error("[vv-worker] outbox poll error:", err);
  }
}

async function main() {
  // pg-boss im eigenen Schema (Eigentümer vv_worker). Das Schema installiert die DB-Migration
  // 0012_pgboss_schema.sql (generiert, Register P57) — der Worker installiert/migriert NICHT selbst
  // (dafür bräuchte er das Datenbank-CREATE-Recht), sondern prüft nur die Schema-Version und
  // bricht bei Abweichung ab (fail-closed; neues pg-boss = neue Migration).
  const boss = new PgBoss({ connectionString: process.env.WORKER_DATABASE_URL, schema: "pgboss", migrate: false });
  boss.on("error", (err) => console.error("[vv-worker] pg-boss error:", err));
  await boss.start();

  const QUEUE = "reminder.dispatch";
  await boss.createQueue(QUEUE);
  await boss.work(QUEUE, async ([job]) => {
    console.log("[vv-worker] reminder job", job.id); // Trivial-Routine (stehende Klasse-Freigabe, B09-1)
  });

  // M05-Tagesjob (Stichtag, Sperre, Aging-up, Aufbewahrung) — 02:15 Europe/Vienna, idempotent.
  const M05_DAILY = "m05.daily";
  await boss.createQueue(M05_DAILY);
  await boss.schedule(M05_DAILY, "15 2 * * *", {}, { tz: "Europe/Vienna" });
  await boss.work(M05_DAILY, async () => {
    console.log("[vv-worker] m05.daily", JSON.stringify(await runM05Daily(pool)));
  });

  beat();
  setInterval(beat, 30_000);
  setInterval(pollOutbox, 5_000);
  console.log("[vv-worker] Stage-0-Skeleton bereit (pg-boss + Outbox-Consumer).");
}

main().catch((err) => { console.error("[vv-worker] Startfehler:", err); process.exit(1); });
