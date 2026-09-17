// VV Agenten-/Job-Worker — Stage-0-Einstieg (ADR-06: pg-boss).
// Idempotente Jobs; kein Job überschreitet autonom eine harte Grenze — er bereitet
// vor und legt ein Freigabe-Objekt an. Stage-0: Boot + Beispiel-Job (Terminerinnerung
// als Trivial-Routine unter stehender Klasse-Freigabe, B09-1).
import PgBoss from "pg-boss";

async function main() {
  const boss = new PgBoss({ connectionString: process.env.DATABASE_URL });
  boss.on("error", (err) => console.error("[vv-worker] pg-boss error:", err));
  await boss.start();

  const QUEUE = "reminder.dispatch";
  await boss.createQueue(QUEUE);

  await boss.work(QUEUE, async ([job]) => {
    // Trivial-Routine (kein Personenbezug nach außen) — läuft ohne Einzel-Freigabe.
    console.log("[vv-worker] reminder job", job.id);
  });

  console.log("[vv-worker] Stage-0-Skeleton bereit (pg-boss).");
}

main().catch((err) => {
  console.error("[vv-worker] Startfehler:", err);
  process.exit(1);
});
