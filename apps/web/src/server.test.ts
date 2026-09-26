// C-1 DoD 8 — Fail-closed: ist der Ticket-Dienst weg, antwortet die Web-App mit 503, greift NICHT auf Daten zu
// und fällt NICHT auf einen Weg ohne Ticket zurück. Plus: Ticket-Client gegen einen echten (toten/kaputten) Dienst.
import { test } from "node:test";
import assert from "node:assert/strict";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { createWebServer, type WebDeps } from "./server.ts";
import { httpTicketSource, TicketRejected, TicketUnavailable } from "./platform/ticket.ts";

const principal = { actor: "sub-vorstand-aa", tenantId: "00000000-0000-0000-0000-0000000000aa", roles: [] };

async function withServer(s: Server, fn: (base: string) => Promise<void>) {
  await new Promise<void>((r) => s.listen(0, "127.0.0.1", () => r()));
  try { await fn(`http://127.0.0.1:${(s.address() as AddressInfo).port}`); }
  finally { await new Promise<void>((r) => s.close(() => r())); }
}

function deps(over: Partial<WebDeps>, calls: string[]): WebDeps {
  return {
    pingDb: async () => true,
    verifyBearer: async () => principal,
    getTicket: async () => ({ ticket: "v1.k1.xxxxxxxxxxxxxxxxxxxx.yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy", exp: 0 }),
    handleM05: async (_q, res, p) => { calls.push(`m05:${p.ticket.slice(0, 6)}`); res.writeHead(200).end("{}"); return true; },
    ...over,
  };
}

test("Ticket-Dienst weg -> 503 'vorübergehend nicht verfügbar', KEIN Fachzugriff, kein Rückfall", async () => {
  const calls: string[] = [];
  const s = createWebServer(deps({ getTicket: httpTicketSource("http://127.0.0.1:9", 500) }, calls));  // Port 9: nichts lauscht
  await withServer(s, async (base) => {
    const r = await fetch(`${base}/api/m05/members`, { headers: { authorization: "Bearer abc" } });
    assert.equal(r.status, 503);
    const j = (await r.json()) as any;
    assert.equal(j.error, "unavailable");
    assert.match(j.reason, /vorübergehend nicht verfügbar/);
    assert.equal(r.headers.get("retry-after"), "5");
  });
  assert.deepEqual(calls, [], "Fachlogik/DB wird ohne Ticket nie erreicht");
});

test("Ticket-Dienst nicht konfiguriert / antwortet 5xx / Unsinn -> 503 (fail-closed)", async () => {
  const bad = createServer((req, res) => {
    if (req.url?.startsWith("/v1/ticket") && req.headers["x-mode"] !== "junk") { res.writeHead(500).end("{}"); return; }
    res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify({ ticket: "nicht-im-format", exp: 1 }));
  });
  await withServer(bad, async (b) => {
    await assert.rejects(httpTicketSource(undefined)("Bearer x"), TicketUnavailable);
    await assert.rejects(httpTicketSource(b)("Bearer x"), TicketUnavailable);
  });
  const junk = createServer((_q, res) => res.writeHead(200, { "content-type": "application/json" })
    .end(JSON.stringify({ ticket: "v1.k1.abc.def", exp: 1 })));
  await withServer(junk, async (b) => { await assert.rejects(httpTicketSource(b)("Bearer x"), TicketUnavailable); });
  const slow = createServer(() => { /* antwortet nie */ });
  await withServer(slow, async (b) => { await assert.rejects(httpTicketSource(b, 200)("Bearer x"), TicketUnavailable); });
});

test("Ticket-Dienst weist Token ab -> 401 (kein Zugriff)", async () => {
  const deny = createServer((_q, res) => res.writeHead(401, { "content-type": "application/json" }).end("{}"));
  const calls: string[] = [];
  await withServer(deny, async (b) => {
    await assert.rejects(httpTicketSource(b)("Bearer x"), TicketRejected);
    const s = createWebServer(deps({ getTicket: httpTicketSource(b) }, calls));
    await withServer(s, async (base) => {
      const r = await fetch(`${base}/api/m05/members`, { headers: { authorization: "Bearer abc" } });
      assert.equal(r.status, 401);
    });
  });
  assert.deepEqual(calls, []);
});

test("ungültiges Bearer-Token -> 401 noch VOR dem Ticket-Dienst", async () => {
  const calls: string[] = [];
  let asked = 0;
  const s = createWebServer(deps({
    verifyBearer: async () => { throw new Error("Token ungültig"); },
    getTicket: async () => { asked++; throw new TicketUnavailable("x"); },
  }, calls));
  await withServer(s, async (base) => {
    assert.equal((await fetch(`${base}/api/m05/members`)).status, 401);
  });
  assert.equal(asked, 0);
  assert.deepEqual(calls, []);
});

test("mit Ticket: Fachlogik erhält das Ticket (Kontext nur daraus)", async () => {
  const calls: string[] = [];
  const s = createWebServer(deps({}, calls));
  await withServer(s, async (base) => {
    assert.equal((await fetch(`${base}/api/m05/members`, { headers: { authorization: "Bearer abc" } })).status, 200);
  });
  assert.deepEqual(calls, ["m05:v1.k1."]);
});
