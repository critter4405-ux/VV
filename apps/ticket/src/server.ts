// VV Ticket-Dienst — HTTP (ein Endpunkt). Gültiges Bearer-Token rein, kurzlebiges Ticket raus.
//   POST /v1/ticket   Authorization: Bearer <Keycloak-Access-Token>  ->  200 {ticket, exp}
//   GET  /health      200, wenn ein gültiger Signaturschlüssel geladen ist (sonst 503, fail-closed)
// Nur internes Netz (compose: kein Port-Mapping). Keine Protokollierung von Tokens/Tickets: Log enthält nur
// Ergebnis, Grund-Code und einen gekürzten Hash des Subjekts.
import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import { createHash } from "node:crypto";
import { buildClaims, signTicket, MAX_TTL_S } from "./ticket.ts";
import { verifyAccessToken, TokenRejected, type VerifyOptions } from "./verify.ts";
import { RateLimiter } from "./ratelimit.ts";
import type { ActiveKey } from "./keyring.ts";

export interface TicketServiceDeps {
  verify: Omit<VerifyOptions, "nowS">;
  keyring: { current(): ActiveKey };
  ttlS?: number;
  perSourcePerMinute?: number;
  perSubjectPerMinute?: number;
  log?: (line: Record<string, unknown>) => void;
  nowS?: () => number;
}

function send(res: ServerResponse, code: number, body: unknown): void {
  res.writeHead(code, { "content-type": "application/json; charset=utf-8", "cache-control": "no-store",
                        "x-content-type-options": "nosniff" });
  res.end(JSON.stringify(body));
}

const subRef = (s: string) => createHash("sha256").update(s).digest("hex").slice(0, 12);

export function createTicketServer(d: TicketServiceDeps): Server {
  const ttl = Math.min(d.ttlS ?? MAX_TTL_S, MAX_TTL_S);
  const bySource = new RateLimiter(d.perSourcePerMinute ?? 1200, 200);
  const bySubject = new RateLimiter(d.perSubjectPerMinute ?? 120, 30);
  const log = d.log ?? ((l) => console.log(JSON.stringify({ svc: "vv-ticket", ...l })));
  const now = d.nowS ?? (() => Math.floor(Date.now() / 1000));

  const server = createServer(async (req: IncomingMessage, res: ServerResponse) => {
    const path = (req.url ?? "").split("?")[0];
    if (req.method === "GET" && path === "/health") {
      try { d.keyring.current(); send(res, 200, { status: "ok" }); }
      catch { send(res, 503, { status: "no-key" }); }
      return;
    }
    if (path !== "/v1/ticket") { send(res, 404, { error: "not_found" }); return; }
    if (req.method !== "POST") { send(res, 405, { error: "method_not_allowed" }); return; }
    req.resume();                                             // Body wird nicht gebraucht
    const source = req.socket.remoteAddress ?? "?";
    if (!bySource.take(source)) { log({ r: "rate_limited", scope: "source" }); send(res, 429, { error: "rate_limited" }); return; }
    const auth = String(req.headers["authorization"] ?? "");
    const m = /^Bearer\s+([A-Za-z0-9._~+/=-]+)$/.exec(auth);
    if (!m) { log({ r: "rejected", why: "no_bearer" }); send(res, 401, { error: "unauthorized" }); return; }
    try {
      const tok = await verifyAccessToken(m[1]!, { ...d.verify, nowS: now });
      if (!bySubject.take(tok.sub)) { log({ r: "rate_limited", scope: "subject", sub: subRef(tok.sub) }); send(res, 429, { error: "rate_limited" }); return; }
      const key = d.keyring.current();
      const claims = buildClaims(tok.tenant, tok.sub, now(), ttl, tok.exp);
      const ticket = signTicket(claims, key.kid, key.key);
      log({ r: "issued", sub: subRef(tok.sub), kid: key.kid, ttl: claims.exp - claims.iat });
      send(res, 200, { ticket, exp: claims.exp });
    } catch (e) {
      if (e instanceof TokenRejected) {
        log({ r: "rejected", why: e.message.slice(0, 60) });
        send(res, 401, { error: "unauthorized" });
      } else {
        log({ r: "error", why: (e as Error).message.slice(0, 60) });
        send(res, 503, { error: "unavailable" });              // fail-closed (z. B. Keyring/JWKS weg)
      }
    }
  });
  server.requestTimeout = 5_000;
  server.headersTimeout = 5_000;
  server.keepAliveTimeout = 5_000;
  server.maxHeadersCount = 50;
  return server;
}
