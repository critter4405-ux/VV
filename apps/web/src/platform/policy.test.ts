// Zentraler Policy-Prüfpunkt — Unit-Tests mit Fake-Pool (fail-closed, deny-by-default, Audit bei Deny).
import { test } from "node:test";
import assert from "node:assert/strict";
import { checkPolicy } from "./policy.ts";

function fakePool(allowed: boolean | "throw") {
  const log: string[] = [];
  const client = {
    async query(sql: string, params?: unknown[]) {
      log.push(sql.trim().split(/\s+/).slice(0, 3).join(" ") + (params ? ` ${JSON.stringify(params)}` : ""));
      if (sql.includes("vv_policy_any")) {
        if (allowed === "throw") throw new Error("db down");
        return { rows: [{ allowed }] };
      }
      return { rows: [] };
    },
    release() { log.push("release"); },
  };
  return { log, pool: { connect: async () => client } as any };
}

const base = { tenantId: "00000000-0000-0000-0000-0000000000aa", actor: "sub-x", resource: "membership",
               action: "read" as const, scopeNode: "verein", dataClass: "S" as const };

test("ohne Tenant/Actor/Scope: deny ohne DB-Zugriff", async () => {
  const f = fakePool(true);
  for (const k of ["tenantId", "actor", "scopeNode"] as const) {
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

test("DB entscheidet: erlaubt -> allowed, in Transaktion mit Tenant + Actor", async () => {
  const f = fakePool(true);
  const d = await checkPolicy(base, { pool: f.pool });
  assert.equal(d.allowed, true);
  assert.ok(f.log[0]!.startsWith("BEGIN"));
  assert.ok(f.log.some((l) => l.includes("app.tenant_id")));
  assert.ok(f.log.some((l) => l.includes("app.actor") && l.includes("sub-x")));
  assert.ok(f.log.includes("COMMIT"));
  assert.equal(f.log.at(-1), "release");
});

test("DB verweigert -> deny + Audit-Eintrag", async () => {
  const f = fakePool(false);
  const d = await checkPolicy(base, { pool: f.pool });
  assert.equal(d.allowed, false);
  assert.ok(f.log.some((l) => l.startsWith("INSERT INTO audit_log")));
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
