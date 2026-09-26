// VV Ticket-Dienst — Unit-/Adversarial-Tests (ohne Netz: lokales JWKS, echter HTTP-Server auf Port 0).
import { test, after } from "node:test";
import assert from "node:assert/strict";
import { createHmac, randomBytes } from "node:crypto";
import type { AddressInfo } from "node:net";
import { generateKeyPair, exportJWK, createLocalJWKSet, SignJWT, type CryptoKey, type JWK } from "jose";
import { createTicketServer } from "./server.ts";
import { buildClaims, signTicket, b64url } from "./ticket.ts";
import { parseKeyring } from "./keyring.ts";

const ISS = "http://kc.test/realms/vv";
const AUD = "vv-web";
const TENANT = "00000000-0000-0000-0000-0000000000aa";
const KEY = randomBytes(32);
const KID = "ktest1";
const now = () => Math.floor(Date.now() / 1000);

const { publicKey, privateKey } = await generateKeyPair("RS256");
const jwk: JWK = { ...(await exportJWK(publicKey)), kid: "rsa1", alg: "RS256", use: "sig" };
const jwks = createLocalJWKSet({ keys: [jwk] });
const other = await generateKeyPair("RS256");

async function token(claims: Record<string, unknown>, opts: { key?: CryptoKey; alg?: string; iss?: string; aud?: string; iat?: number; exp?: number } = {}) {
  const iat = opts.iat ?? now();
  return new SignJWT({ typ: "Bearer", tenant_id: TENANT, ...claims })
    .setProtectedHeader({ alg: opts.alg ?? "RS256", kid: "rsa1" })
    .setIssuer(opts.iss ?? ISS).setAudience(opts.aud ?? AUD).setSubject(String(claims["sub"] ?? "sub-vorstand-aa"))
    .setIssuedAt(iat).setExpirationTime(opts.exp ?? iat + 300)
    .sign(opts.key ?? privateKey);
}

const logs: Record<string, unknown>[] = [];
const server = createTicketServer({
  verify: { jwks, issuer: ISS, audience: AUD, maxTokenAgeS: 300 },
  keyring: { current: () => ({ kid: KID, key: KEY }) },
  perSubjectPerMinute: 600,
  log: (l) => logs.push(l),
});
await new Promise<void>((r) => server.listen(0, "127.0.0.1", () => r()));
const base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
after(() => new Promise<void>((r) => server.close(() => r())));

async function call(auth?: string, method = "POST", path = "/v1/ticket") {
  const r = await fetch(base + path, { method, headers: auth ? { authorization: auth } : {} });
  return { status: r.status, json: (await r.json()) as any };
}

function decode(ticket: string) {
  const [v, kid, body, sig] = ticket.split(".");
  return { v, kid, body: JSON.parse(Buffer.from(body!, "base64url").toString("utf8")), sig, bodyRaw: body };
}

test("gültiges Access-Token -> Ticket im DB-Format, HMAC stimmt, ≤ 60 s, genau t/s/iat/exp/jti", async () => {
  const r = await call(`Bearer ${await token({ sub: "sub-vorstand-aa" })}`);
  assert.equal(r.status, 200);
  const t = decode(r.json.ticket);
  assert.equal(t.v, "v1"); assert.equal(t.kid, KID);
  assert.deepEqual(Object.keys(t.body).sort(), ["exp", "iat", "jti", "s", "t"]);
  assert.equal(t.body.t, TENANT); assert.equal(t.body.s, "sub-vorstand-aa");
  assert.ok(t.body.exp - t.body.iat <= 60 && t.body.exp - t.body.iat >= 1);
  const mac = b64url(createHmac("sha256", KEY).update(`v1.${KID}.${t.bodyRaw}`).digest());
  assert.equal(t.sig, mac);
});

test("jede Ausstellung hat eine eigene Ticket-Kennung (jti)", async () => {
  const tok = `Bearer ${await token({ sub: "sub-a" })}`;
  const a = decode((await call(tok)).json.ticket).body.jti;
  const b = decode((await call(tok)).json.ticket).body.jti;
  assert.notEqual(a, b);
});

test("Ticket überlebt nie das Access-Token (exp = min)", async () => {
  const iat = now() - 10;
  const r = await call(`Bearer ${await token({ sub: "sub-b" }, { iat, exp: now() + 20 })}`);
  assert.equal(r.status, 200);
  const t = decode(r.json.ticket).body;
  assert.ok(t.exp <= now() + 20);
});

for (const [name, mk] of [
  ["fremder Signaturschlüssel", async () => token({ sub: "x" }, { key: other.privateKey })],
  ["falscher Issuer", async () => token({ sub: "x" }, { iss: "http://evil/realms/vv" })],
  ["falsche Audience", async () => token({ sub: "x" }, { aud: "vv-worker" })],
  ["abgelaufen", async () => token({ sub: "x" }, { iat: now() - 400, exp: now() - 100 })],
  ["zu alt (Wiederverwendung abgefangener Tokens begrenzt)", async () => token({ sub: "x" }, { iat: now() - 301, exp: now() + 600 })],
  ["ID-Token statt Access-Token", async () => token({ sub: "x", typ: "ID" })],
  ["Refresh-Token", async () => token({ sub: "x", typ: "Refresh" })],
  ["ohne tenant_id", async () => token({ sub: "x", tenant_id: undefined })],
  ["tenant_id keine UUID", async () => token({ sub: "x", tenant_id: "aa' OR 1=1" })],
  ["Systemakteur als sub", async () => token({ sub: "system:worker" })],
  ["HS256 mit öffentlichem Schlüssel als Geheimnis", async () =>
    new SignJWT({ typ: "Bearer", tenant_id: TENANT }).setProtectedHeader({ alg: "HS256" }).setIssuer(ISS).setAudience(AUD)
      .setSubject("x").setIssuedAt().setExpirationTime("5m").sign(new TextEncoder().encode(JSON.stringify(jwk)))],
  ["alg none", async () => `${Buffer.from('{"alg":"none"}').toString("base64url")}.${Buffer.from(JSON.stringify({ sub: "x", iss: ISS, aud: AUD, typ: "Bearer", tenant_id: TENANT, iat: now(), exp: now() + 60 })).toString("base64url")}.`],
] as const) {
  test(`abgewiesen: ${name}`, async () => {
    const r = await call(`Bearer ${await mk()}`);
    assert.equal(r.status, 401);
    assert.equal(r.json.ticket, undefined);
  });
}

test("ohne Bearer / falsche Methode / falscher Pfad", async () => {
  assert.equal((await call()).status, 401);
  assert.equal((await call("Basic abc")).status, 401);
  assert.equal((await call(undefined, "GET")).status, 405);
  assert.equal((await call(undefined, "GET", "/v1/other")).status, 404);
});

test("Keyring weg -> 503 (fail-closed), Health meldet 503", async () => {
  const s = createTicketServer({ verify: { jwks, issuer: ISS, audience: AUD, maxTokenAgeS: 300 },
    keyring: { current: () => { throw new Error("kein Secret"); } }, log: () => {} });
  await new Promise<void>((r) => s.listen(0, "127.0.0.1", () => r()));
  const b = `http://127.0.0.1:${(s.address() as AddressInfo).port}`;
  const r = await fetch(b + "/v1/ticket", { method: "POST", headers: { authorization: `Bearer ${await token({ sub: "y" })}` } });
  assert.equal(r.status, 503);
  assert.equal((await fetch(b + "/health")).status, 503);
  await new Promise<void>((r2) => s.close(() => r2()));
});

test("Rate-Limit je Nutzer greift (429)", async () => {
  const s = createTicketServer({ verify: { jwks, issuer: ISS, audience: AUD, maxTokenAgeS: 300 },
    keyring: { current: () => ({ kid: KID, key: KEY }) }, perSubjectPerMinute: 1, log: () => {} });
  await new Promise<void>((r) => s.listen(0, "127.0.0.1", () => r()));
  const b = `http://127.0.0.1:${(s.address() as AddressInfo).port}`;
  const tok = `Bearer ${await token({ sub: "sub-flood" })}`;
  const codes: number[] = [];
  for (let i = 0; i < 35; i++) codes.push((await fetch(b + "/v1/ticket", { method: "POST", headers: { authorization: tok } })).status);
  assert.ok(codes.includes(429), "nach dem Burst wird gedrosselt");
  await new Promise<void>((r2) => s.close(() => r2()));
});

test("Protokoll enthält nie Token oder Ticket", async () => {
  const tok = await token({ sub: "sub-log" });
  const r = await call(`Bearer ${tok}`);
  const all = JSON.stringify(logs);
  assert.ok(!all.includes(tok.split(".")[2]!), "keine Token-Signatur im Log");
  assert.ok(!all.includes(r.json.ticket), "kein Ticket im Log");
  assert.ok(!all.includes("sub-log"), "sub nur als Hash");
});

test("Ticket-Bausteine: Systemakteur/ungültiger Mandant/abgelaufenes Token werden nicht signiert", () => {
  assert.throws(() => buildClaims(TENANT, "system:x", now(), 60, now() + 100));
  assert.throws(() => buildClaims("nicht-uuid", "sub", now(), 60, now() + 100));
  assert.throws(() => buildClaims(TENANT, "sub", now(), 60, now()));
  assert.equal(buildClaims(TENANT, "sub", 1000, 999, 5000).exp, 1060, "TTL gedeckelt auf 60 s");
  assert.throws(() => signTicket(buildClaims(TENANT, "sub", now(), 60, now() + 100), "Kid!", KEY));
  assert.throws(() => signTicket(buildClaims(TENANT, "sub", now(), 60, now() + 100), KID, Buffer.alloc(16)));
});

test("Keyring-Parser: nur gültige Kennung/Länge", () => {
  const ok = parseKeyring(JSON.stringify({ version: 1, active: "k1", keys: { k1: KEY.toString("base64") } }));
  assert.equal(ok.kid, "k1");
  assert.throws(() => parseKeyring(JSON.stringify({ active: "K1", keys: { K1: KEY.toString("base64") } })));
  assert.throws(() => parseKeyring(JSON.stringify({ active: "k1", keys: { k1: Buffer.alloc(8).toString("base64") } })));
  assert.throws(() => parseKeyring(JSON.stringify({ active: "k1", keys: {} })));
});
