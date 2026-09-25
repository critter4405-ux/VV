// M05 — API-Integrationstest gegen ECHTE PostgreSQL (vv_app, RLS aktiv). Nur synthetische Daten.
// Läuft, wenn DATABASE_URL gesetzt ist (CI: db-integration). VV_REQUIRE_DB=1 macht Fehlen zum Fehler.
// Der Principal wird hier im TEST-Server gesetzt (simuliert verifiziertes OIDC-Token + Ticket-Dienst): das
// Ticket signiert der Test mit dem Wegwerf-Schlüssel des CI-Laufs (VV_TICKET_KEYRING) — genau wie der
// Ticket-Dienst. Der Produktionscode kennt weder Header noch Schlüssel (C-1).
// Testdaten (synthetische Person) legt der Betreiber-Zugang an (VV_BOOTSTRAP_URL): vv_app hat seit C-1
// keine Tabellenrechte mehr.
import { test, after } from "node:test";
import assert from "node:assert/strict";
import { createServer, type Server } from "node:http";
import { createHmac, randomUUID } from "node:crypto";
import { readFileSync } from "node:fs";

const HAS_DB = !!process.env.DATABASE_URL && !!process.env.VV_BOOTSTRAP_URL && !!process.env.VV_TICKET_KEYRING;

/** Test-Ticket im Format des Ticket-Dienstes (apps/ticket/src/ticket.ts). */
function mintTicket(tenant: string, actor: string): string {
  const ring = JSON.parse(readFileSync(process.env.VV_TICKET_KEYRING!, "utf8"));
  const kid: string = ring.active;
  const key = Buffer.from(ring.keys[kid], "base64");
  const now = Math.floor(Date.now() / 1000);
  const body = Buffer.from(JSON.stringify({ t: tenant, s: actor, iat: now, exp: now + 60, jti: randomUUID() })).toString("base64url");
  return `v1.${kid}.${body}.${createHmac("sha256", key).update(`v1.${kid}.${body}`).digest("base64url")}`;
}
const TENANT = "00000000-0000-0000-0000-0000000000aa";
const RUN = randomUUID().slice(0, 6);

let server: Server | undefined;
let base = "";

async function setup() {
  const { handleM05 } = await import("./mitglieder.routes.ts");
  server = createServer(async (req, res) => {
    const actor = String(req.headers["x-test-actor"] ?? "");
    await handleM05(req, res, { tenantId: TENANT, actor, ticket: actor ? mintTicket(TENANT, actor) : "" });
  });
  await new Promise<void>((r) => server!.listen(0, "127.0.0.1", () => r()));
  const addr = server.address();
  base = `http://127.0.0.1:${typeof addr === "object" && addr ? addr.port : 0}`;
}

async function call(actor: string, method: string, path: string, body?: unknown, ct = "application/json") {
  const r = await fetch(base + path, {
    method, headers: { "x-test-actor": actor, "content-type": ct },
    body: body === undefined ? undefined : typeof body === "string" ? body : JSON.stringify(body),
  });
  return { status: r.status, json: (await r.json()) as any };
}

after(async () => {
  if (server) await new Promise<void>((r) => server!.close(() => r()));
  if (HAS_DB) { const { pool } = await import("../../db.ts"); await pool.end(); }
});

test("M05-API end-to-end (echte DB)", { skip: !HAS_DB && !process.env.VV_REQUIRE_DB ? "kein DATABASE_URL (lokal)" : false }, async () => {
  assert.ok(HAS_DB, "VV_REQUIRE_DB gesetzt, aber DATABASE_URL/VV_BOOTSTRAP_URL/VV_TICKET_KEYRING fehlt");
  await setup();
  // Synthetische Person (BASIS-01) über den Betreiber-Zugang (Onboarding-Pfad, Bootstrap-Kontext)
  const { Pool } = await import("pg");
  const boot = new Pool({ connectionString: process.env.VV_BOOTSTRAP_URL, max: 1 });
  const personId = randomUUID();
  const c = await boot.connect();
  try {
    await c.query("BEGIN");
    await c.query("SELECT vv_bootstrap_context($1, 'system:test')", [TENANT]);
    await c.query("INSERT INTO person (id, tenant_id, last_name, first_name, birth_date) VALUES ($1,$2,$3,'Synth','1994-04-04')",
      [personId, TENANT, `ApiTest${RUN}`]);
    await c.query("COMMIT");
  } finally { c.release(); await boot.end(); }

  let r = await call("sub-schrift-aa", "POST", "/api/m05/types", { code: `api_${RUN}`, name: "API Aktiv", category: "aktiv",
    noticeMonths: 0, cutoff: "sofort" });
  assert.equal(r.status, 403, "Schriftführer darf keine Art anlegen");
  r = await call("sub-admin-aa", "POST", "/api/m05/types", { code: `api_${RUN}`, name: "API Aktiv", category: "aktiv",
    noticeMonths: 1, cutoff: "monatsende" });
  assert.equal(r.status, 200, JSON.stringify(r.json));
  const typeId = r.json.data.typeId;

  r = await call("sub-trainer-aa", "POST", "/api/m05/periods", { personId, memberNo: `A${RUN}`, typeId, appliedOn: "2026-01-02" });
  assert.equal(r.status, 403, "Trainer darf keinen Antrag stellen");
  r = await call("sub-schrift-aa", "POST", "/api/m05/periods", { personId, memberNo: `A${RUN}`, typeId, appliedOn: "2026-01-02" });
  assert.equal(r.status, 200, JSON.stringify(r.json));
  const periodId = r.json.data.periodId;

  r = await call("sub-schrift-aa", "POST", `/api/m05/periods/${periodId}/admit`, { effective: "2026-01-05", expectedVersion: 99 });
  assert.equal(r.status, 409, "veraltete Version -> 409");
  r = await call("sub-schrift-aa", "POST", `/api/m05/periods/${periodId}/admit`, { effective: "2026-01-05", expectedVersion: 1 });
  assert.equal(r.status, 200, JSON.stringify(r.json));

  r = await call("sub-trainer-aa", "GET", "/api/m05/members");
  assert.equal(r.status, 200);
  assert.ok(!r.json.data.some((m: any) => m.period_id === periodId), "Trainer sieht Mitglieder ohne Team-Bezug nicht");
  r = await call("sub-schrift-aa", "GET", "/api/m05/members");
  const row = r.json.data.find((m: any) => m.period_id === periodId);
  assert.equal(row?.status, "aktiv");
  assert.equal(row?.exclusion_reason_code, null);

  r = await call("sub-schrift-aa", "POST", `/api/m05/periods/${periodId}/request-termination`,
    { endKind: "ausgetreten", noticeReceivedOn: "2026-02-10", reasonCode: "zeitmangel", expectedVersion: 2 });
  assert.equal(r.status, 200, JSON.stringify(r.json));
  assert.equal(r.json.data.requiresApproval, true);
  const approvalId = r.json.data.approvalId;

  r = await call("sub-schrift-aa", "POST", `/api/m05/approvals/${approvalId}/decide`, { decision: "approved" });
  assert.equal(r.status, 403, "Antragsteller/ohne Freigaberecht kann nicht freigeben");
  r = await call("sub-obmann-aa", "POST", `/api/m05/approvals/${approvalId}/decide`,
    { decision: "approved", approvedBy: "sub-irgendwer" });   // Body-Feld wird ignoriert
  assert.equal(r.status, 200, JSON.stringify(r.json));
  r = await call("sub-vorstand-aa", "GET", "/api/m05/approvals");
  assert.ok(Array.isArray(r.json.data));

  // Robustheit: Fehlerbilder ohne interne Details
  r = await call("sub-schrift-aa", "POST", "/api/m05/periods", "{kaputt");
  assert.equal(r.status, 400);
  r = await call("sub-schrift-aa", "POST", "/api/m05/periods", "a=b", "application/x-www-form-urlencoded");
  assert.equal(r.status, 400);
  r = await call("sub-schrift-aa", "GET", "/api/m05/gibtsnicht");
  assert.equal(r.status, 404);
  r = await call("sub-pruef-aa", "POST", "/api/m05/members/export", {});
  assert.equal(r.status, 400, "Export ohne Zweck");
  r = await call("sub-pruef-aa", "POST", "/api/m05/members/export", { purpose: "Kassaprüfung 2026 Mitgliederstand" });
  assert.equal(r.status, 200);
  r = await call("", "GET", "/api/m05/members");
  assert.equal(r.status, 403, "ohne Actor/Ticket -> deny");
  r = await call("sub-schrift-aa", "POST", `/api/m05/periods/${periodId}/admit`, { effective: "2026-01-05", expectedVersion: 1, x: "'; DROP TABLE member;--" });
  assert.ok([400, 409].includes(r.status));
});
