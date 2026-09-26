// M05-Worker — Integrationstest gegen ECHTE PostgreSQL: Freigabe -> Outbox-Event -> Worker-Claim ->
// m05_execute -> Zustand. Beweist „Zustand ⇔ Event" über den echten Outbox-Pfad (ADR-05/06/07).
// Läuft mit WORKER_DATABASE_URL (vv_worker) + DATABASE_URL (vv_app); VV_REQUIRE_DB=1 -> Pflicht.
// C-1: die App-Seite läuft mit signierten Tickets (Wegwerf-Schlüssel des CI-Laufs, VV_TICKET_KEYRING);
// Testdaten legt der Betreiber-Zugang an (VV_BOOTSTRAP_URL) — vv_app hat keine Tabellenrechte mehr.
import { test } from "node:test";
import assert from "node:assert/strict";
import { createHmac, randomUUID } from "node:crypto";
import { readFileSync } from "node:fs";

const HAS_DB = !!process.env.WORKER_DATABASE_URL && !!process.env.DATABASE_URL && !!process.env.VV_BOOTSTRAP_URL
  && !!process.env.VV_TICKET_KEYRING;

function mintTicket(tenant: string, actor: string): string {
  const ring = JSON.parse(readFileSync(process.env.VV_TICKET_KEYRING!, "utf8"));
  const kid: string = ring.active;
  const key = Buffer.from(ring.keys[kid], "base64");
  const now = Math.floor(Date.now() / 1000);
  const body = Buffer.from(JSON.stringify({ t: tenant, s: actor, iat: now, exp: now + 60, jti: randomUUID() })).toString("base64url");
  return `v1.${kid}.${body}.${createHmac("sha256", key).update(`v1.${kid}.${body}`).digest("base64url")}`;
}
const T = "00000000-0000-0000-0000-0000000000aa";

test("Freigabe wird über Outbox + Worker genau einmal ausgeführt",
  { skip: !HAS_DB && !process.env.VV_REQUIRE_DB ? "keine DB-URLs (lokal)" : false }, async () => {
  assert.ok(HAS_DB, "VV_REQUIRE_DB gesetzt, aber DB-URLs fehlen");
  const { Pool } = await import("pg");
  const app = new Pool({ connectionString: process.env.DATABASE_URL, max: 2 });
  const boot = new Pool({ connectionString: process.env.VV_BOOTSTRAP_URL, max: 1 });
  const { pool: wk, claimOutbox, markOutboxDone } = await import("../db.ts");
  const { handleM05Outbox, M05_TOPICS } = await import("./m05.ts");
  const run = async (actor: string, sql: string, p: unknown[] = []) => {
    const c = await app.connect();
    try {
      await c.query("BEGIN");
      await c.query("SELECT vv_set_context($1)", [mintTicket(T, actor)]);
      const r = await c.query(sql, p);
      await c.query("COMMIT");
      return r.rows;
    } catch (e) { await c.query("ROLLBACK"); throw e; } finally { c.release(); }
  };
  try {
    const run6 = randomUUID().slice(0, 6);
    const pid = randomUUID();
    const bc = await boot.connect();
    try {
      await bc.query("BEGIN");
      await bc.query("SELECT vv_bootstrap_context($1, 'system:test')", [T]);
      await bc.query("INSERT INTO person (id, tenant_id, last_name, first_name, birth_date) VALUES ($1,$2,$3,'Synth','1990-01-01')",
        [pid, T, `Worker${run6}`]);
      await bc.query("COMMIT");
    } finally { bc.release(); }
    const [{ id: typeId }] = await run("sub-admin-aa", "SELECT m05_type_create($1,'W','unterstuetzend',0,'sofort') AS id", [`w_${run6}`]);
    const [{ id: per }] = await run("sub-schrift-aa", "SELECT m05_apply($1,$2,$3,m05_today()-10) AS id", [pid, `W${run6}`, typeId]);
    await run("sub-schrift-aa", "SELECT m05_admit($1, m05_today()-10, 1)", [per]);
    const [{ id: appr }] = await run("sub-schrift-aa",
      "SELECT m05_request_termination($1,'ausgetreten',m05_today(),NULL,NULL,NULL,NULL,2) AS id", [per]);
    await run("sub-vorstand-aa", "SELECT m05_decide($1,'approved')", [appr]);

    // Worker-Schleife wie in index.ts: claim -> handle -> done
    let handled = 0;
    for (let i = 0; i < 20 && handled === 0; i++) {
      for (const row of await claimOutbox(50, M05_TOPICS)) {
        assert.ok((M05_TOPICS as readonly string[]).includes(row.topic), "nur Consumer-Topics werden geclaimt (R5)");
        const ours = row.topic === "m05.execute" && (row.payload as any)?.approval_id === appr;
        if (ours && await handleM05Outbox(row, wk)) {
          handled++;
          assert.equal(await markOutboxDone(row.id, row.lease_token), true, "Quittung mit gültigem Lease");
        }
      }
    }
    assert.equal(handled, 1, "Ausführungs-Event genau einmal verarbeitet");
    // R5: Ereignis OHNE Consumer (hier m05.membership.ended aus derselben Ausführung) bleibt geparkt
    const parked = (await boot.query("SELECT count(*)::int AS n FROM outbox WHERE topic='m05.membership.ended' "
      + "AND payload->>'period_id'=$1 AND processed_at IS NULL AND attempts=0", [per])).rows;
    assert.equal(parked[0].n, 1, "Event ohne Consumer bleibt unberührt geparkt (nicht quittiert, nicht DLQ)");
    const [{ m }] = await run("sub-schrift-aa", "SELECT m05_get_member((SELECT id FROM (SELECT member_id AS id FROM m05_list_members() WHERE period_id=$1) x)) AS m", [per]);
    assert.equal(m.periods[0].status, "beendet", "Frist 0/sofort -> heute beendet");
    // Replay: erneut ausgelöst -> No-Op
    const again = await handleM05Outbox({ id: "x", tenant_id: T, topic: "m05.execute", payload: { approval_id: appr } }, wk);
    assert.equal(again, true);
  } finally {
    await app.end();
    await boot.end();
    await wk.end();
  }
});
