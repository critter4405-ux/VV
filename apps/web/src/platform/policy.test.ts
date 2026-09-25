// Zentraler Policy-Prüfpunkt — Unit-Tests mit Fake-Pool (fail-closed, deny-by-default, Audit bei Deny).
import { test } from "node:test";
import assert from "node:assert/strict";
import { checkPolicy } from "./policy.ts";

function fakePool(allowed: boolean | "throw") {
  const log: string[] = [];
  const client = {
    async query(sql: string, params?: unknown[]) {
      log.push(sql.trim().split(/\s+/).slice(0, 3).join(" ") + (params ? ` ${JSON.stringify(params)}` : ""));
      if (sql.includes("vv_policy_any") || sql.includes("vv_authorize")) {
        if (allowed === "throw") throw new Error("db down");
        return { rows: [{ allowed }] };
      }
      return { rows: [] };
    },
    release() { log.push("release"); },
  };
  return { log, pool: { connect: async () => client } as any };
}

const base = { tenantId: "00000000-0000-0000-0000-0000000000aa", actor: "sub-x", ticket: "v1.k1.test.sig", resource: "membership",
               action: "read" as const, scopeNode: "verein", dataClass: "S" as const };

test("ohne Tenant/Actor/Scope/Ticket: deny ohne DB-Zugriff", async () => {
  const f = fakePool(true);
  for (const k of ["tenantId", "actor", "scopeNode", "ticket"] as const) {
    const d = await checkPolicy({ ...base, [k]: "" }, { pool: f.pool });
    assert.equal(d.allowed, false);
  }
  assert.equal(f.log.length, 0);
});

test("Systemakteur und unbekannte Ressource: deny", async () => {
  const f = fakePool(true);
  assert.equal((await checkPolicy({ ...base, actor: "system:m05-job" }, { pool: f.pool })).allowed, false);
  assert.equal((await checkPolicy({ ...base, resource: "membershipp" }, { pool: f.pool })).allowed, false);
});

test("DB entscheidet: erlaubt -> allowed, in Transaktion mit GEPRÜFTEM Ticket-Kontext (C-1)", async () => {
  const f = fakePool(true);
  const d = await checkPolicy(base, { pool: f.pool });
  assert.equal(d.allowed, true);
  assert.ok(f.log[0]!.startsWith("BEGIN"));
  assert.ok(f.log.some((l) => l.startsWith("SELECT vv_set_context") && l.includes(base.ticket)), "Kontext nur per Ticket");
  assert.ok(!f.log.some((l) => /set_config|app\.tenant_id|app\.actor/.test(l)), "keine frei setzbaren GUCs mehr");
  assert.ok(f.log.includes("COMMIT"));
  assert.equal(f.log.at(-1), "release");
});

test("DB verweigert -> deny + Audit-Eintrag", async () => {
  const f = fakePool(false);
  const d = await checkPolicy(base, { pool: f.pool });
  assert.equal(d.allowed, false);
  assert.ok(f.log.some((l) => l.startsWith("SELECT vv_audit_log")), "Deny wird über vv_audit_log protokolliert (R1)");
  assert.ok(!f.log.some((l) => l.includes("INSERT INTO audit_log")), "kein direkter Audit-INSERT mehr (R1)");
});

test("DB-Fehler -> fail-closed", async () => {
  const f = fakePool("throw");
  const d = await checkPolicy(base, { pool: f.pool });
  assert.equal(d.allowed, false);
  assert.match(d.reason, /fail-closed/);
});

test("approve ist bindend (requiresApproval)", async () => {
  const f = fakePool(true);
  assert.equal((await checkPolicy({ ...base, action: "approve" }, { pool: f.pool })).requiresApproval, true);
});

test("R7) scopeNode hat Bedeutung: verein = Wurzelrecht, uuid = Knoten, any = irgendwo, sonst deny", async () => {
  const f = fakePool(true);
  await checkPolicy({ ...base, scopeNode: "verein" }, { pool: f.pool });
  assert.ok(f.log.some((l) => l.startsWith("SELECT vv_authorize") && l.endsWith('["membership","read","S"]')),
    "verein -> vv_authorize an der Wurzel (keine Ziel-Scopes)");
  const g = fakePool(true);
  const node = "5c000000-0000-0000-0000-0000000000a2";
  await checkPolicy({ ...base, scopeNode: node }, { pool: g.pool });
  assert.ok(g.log.some((l) => l.startsWith("SELECT vv_authorize") && l.includes(node)));
  const h = fakePool(true);
  await checkPolicy({ ...base, scopeNode: "any" }, { pool: h.pool });
  assert.ok(h.log.some((l) => l.startsWith("SELECT vv_policy_any")));
  const k = fakePool(true);
  const d = await checkPolicy({ ...base, scopeNode: "mannschaft-x" }, { pool: k.pool });
  assert.equal(d.allowed, false);
  assert.equal(k.log.length, 0, "unbekannter Scope: deny ohne DB-Zugriff");
});
