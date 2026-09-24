// M05-Worker — Integrationstest gegen ECHTE PostgreSQL: Freigabe -> Outbox-Event -> Worker-Claim ->
// m05_execute -> Zustand. Beweist „Zustand ⇔ Event" über den echten Outbox-Pfad (ADR-05/06/07).
// Läuft mit WORKER_DATABASE_URL (vv_worker) + DATABASE_URL (vv_app); VV_REQUIRE_DB=1 -> Pflicht.
import { test } from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";

const HAS_DB = !!process.env.WORKER_DATABASE_URL && !!process.env.DATABASE_URL;
const T = "00000000-0000-0000-0000-0000000000aa";

test("Freigabe wird über Outbox + Worker genau einmal ausgeführt",
  { skip: !HAS_DB && !process.env.VV_REQUIRE_DB ? "keine DB-URLs (lokal)" : false }, async () => {
  assert.ok(HAS_DB, "VV_REQUIRE_DB gesetzt, aber DB-URLs fehlen");
  const { Pool } = await import("pg");
  const app = new Pool({ connectionString: process.env.DATABASE_URL, max: 2 });
  const { pool: wk, claimOutbox, markOutboxDone } = await import("../db.ts");
  const { handleM05Outbox } = await import("./m05.ts");
  const run = async (actor: string, sql: string, p: unknown[] = []) => {
    const c = await app.connect();
    try {
      await c.query("BEGIN");
      await c.query("SELECT set_config('app.tenant_id',$1,true), set_config('app.actor',$2,true)", [T, actor]);
      const r = await c.query(sql, p);
      await c.query("COMMIT");
      return r.rows;
    } catch (e) { await c.query("ROLLBACK"); throw e; } finally { c.release(); }
  };
  try {
    const run6 = randomUUID().slice(0, 6);
    const pid = randomUUID();
    await run("sub-schrift-aa", "INSERT INTO person (id, tenant_id, last_name, first_name, birth_date) VALUES ($1,$2,$3,'Synth','1990-01-01')",
      [pid, T, `Worker${run6}`]);
    const [{ id: typeId }] = await run("sub-admin-aa", "SELECT m05_type_create($1,'W','unterstuetzend',0,'sofort') AS id", [`w_${run6}`]);
    const [{ id: per }] = await run("sub-schrift-aa", "SELECT m05_apply($1,$2,$3,m05_today()-10) AS id", [pid, `W${run6}`, typeId]);
    await run("sub-schrift-aa", "SELECT m05_admit($1, m05_today()-10, 1)", [per]);
    const [{ id: appr }] = await run("sub-schrift-aa",
      "SELECT m05_request_termination($1,'ausgetreten',m05_today(),NULL,NULL,NULL,NULL,2) AS id", [per]);
    await run("sub-vorstand-aa", "SELECT m05_decide($1,'approved')", [appr]);

    // Worker-Schleife wie in index.ts: claim -> handle -> done
    let handled = 0;
    for (let i = 0; i < 20 && handled === 0; i++) {
      for (const row of await claimOutbox(50)) {
        const ours = row.topic === "m05.execute" && (row.payload as any)?.approval_id === appr;
        if (ours && await handleM05Outbox(row, wk)) handled++;
        if (ours) await markOutboxDone(row.id);
      }
    }
    assert.equal(handled, 1, "Ausführungs-Event genau einmal verarbeitet");
    const [{ m }] = await run("sub-schrift-aa", "SELECT m05_get_member((SELECT id FROM (SELECT member_id AS id FROM m05_list_members() WHERE period_id=$1) x)) AS m", [per]);
    assert.equal(m.periods[0].status, "beendet", "Frist 0/sofort -> heute beendet");
    // Replay: erneut ausgelöst -> No-Op
    const again = await handleM05Outbox({ id: "x", tenant_id: T, topic: "m05.execute", payload: { approval_id: appr } }, wk);
    assert.equal(again, true);
  } finally {
    await app.end();
    await wk.end();
  }
});
