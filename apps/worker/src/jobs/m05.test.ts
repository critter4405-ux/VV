// M05-Worker — Unit-Tests (Fake-Pool): fail-closed bei ungültigen Events, Tenant-Kontext, Rollback.
import { test } from "node:test";
import assert from "node:assert/strict";
import { handleM05Outbox, runM05Daily, M05_TOPICS } from "./m05.ts";

function fakeDb(opts: { fail?: boolean } = {}) {
  const log: string[] = [];
  const client = {
    async query(sql: string, p?: unknown[]) {
      log.push(sql + (p ? " " + JSON.stringify(p) : ""));
      if (opts.fail && sql.includes("m05_execute")) throw new Error("M05: verweigert");
      if (sql.includes("FROM vv_worker_tenants()")) return { rows: [{ id: "00000000-0000-0000-0000-0000000000aa" }] };
      return { rows: [{ r: { ok: true } }] };
    },
    release() { log.push("release"); },
  };
  return { log, db: { connect: async () => client } as any };
}

const T = "00000000-0000-0000-0000-0000000000aa";
const A = "11111111-2222-3333-4444-555555555555";

test("fremde Topics werden nicht angefasst", async () => {
  const f = fakeDb();
  assert.equal(await handleM05Outbox({ id: "x", tenant_id: T, topic: "m05.membership.admitted", payload: {} }, f.db), false);
  assert.equal(f.log.length, 0);
});

test("ungültige approval_id / Tenant -> fail-closed, kein DB-Zugriff", async () => {
  const f = fakeDb();
  await assert.rejects(handleM05Outbox({ id: "x", tenant_id: T, topic: "m05.execute", payload: { approval_id: "1; DROP" } }, f.db));
  await assert.rejects(handleM05Outbox({ id: "x", tenant_id: "bad", topic: "m05.execute", payload: { approval_id: A } }, f.db));
  assert.equal(f.log.length, 0);
});

test("Ausführung in Transaktion mit Tenant-Kontext; Fehler -> ROLLBACK + Wurf (Retry/DLQ)", async () => {
  const ok = fakeDb();
  assert.equal(await handleM05Outbox({ id: "x", tenant_id: T, topic: "m05.execute", payload: { approval_id: A } }, ok.db), true);
  assert.ok(ok.log[0] === "BEGIN" && ok.log[1]!.startsWith("SELECT vv_worker_context") && ok.log[1]!.includes(T)
    && ok.log.includes("COMMIT"), "C-1: Systemkontext (vv_worker_context), keine GUC");
  assert.ok(!ok.log.some((l) => l.includes("set_config")), "keine frei setzbare GUC mehr");
  const bad = fakeDb({ fail: true });
  await assert.rejects(handleM05Outbox({ id: "x", tenant_id: T, topic: "m05.execute", payload: { approval_id: A } }, bad.db));
  assert.ok(bad.log.includes("ROLLBACK") && !bad.log.includes("COMMIT"));
});

test("Tagesjob läuft je Mandant", async () => {
  const f = fakeDb();
  const r = await runM05Daily(f.db);
  assert.deepEqual(Object.keys(r), [T]);
  assert.ok(f.log.some((l) => l.includes("m05_job_daily")));
});

test("G-1) m05.import.approved ohne Q05-Zeilenquelle: sichtbarer Fehler (Retry/DLQ), keine Quittung", async () => {
  const f = fakeDb();
  await assert.rejects(handleM05Outbox({ id: "x", tenant_id: T, topic: "m05.import.approved",
    payload: { batch_ref: "VP-2026-01", approval_id: A } }, f.db), /keine Q05-Zeilenquelle/);
  assert.equal(f.log.length, 0, "ohne Zeilen kein DB-Aufruf");
});

test("G-1) m05.import.approved mit Zeilenquelle: m05_import_apply in Tenant-Transaktion", async () => {
  const f = fakeDb();
  const src = { rowsFor: async (_t: string, b: string) => (b === "VP-2026-01" ? [{ member_no: "X1" }] : null) };
  assert.equal(await handleM05Outbox({ id: "x", tenant_id: T, topic: "m05.import.approved",
    payload: { batch_ref: "VP-2026-01" } }, f.db, src), true);
  assert.ok(f.log.some((l) => l.includes("m05_import_apply") && l.includes("VP-2026-01")));
  await assert.rejects(handleM05Outbox({ id: "x", tenant_id: T, topic: "m05.import.approved",
    payload: { batch_ref: "../evil" } }, f.db, src), /batch_ref/);
});

test("R5) Consumer-Topics sind explizit (Worker claimt nur diese)", () => {
  assert.deepEqual([...M05_TOPICS].sort(), ["m05.execute", "m05.import.approved"]);
});
