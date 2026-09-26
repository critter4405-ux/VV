// VV Web/API — HTTP-Server (ohne Framework). C-1 „Kontext-Signatur“ (Grill P58):
//   1. OIDC-Bearer lokal prüfen (verifyBearer, ADR-03) -> 401 bei ungültigem Token
//   2. Ticket beim internen Ticket-Dienst holen -> 503 „vorübergehend nicht verfügbar“, wenn der Dienst fehlt
//      (fail-closed: KEIN Rückfall auf einen Weg ohne Ticket, KEIN Datenzugriff)
//   3. Fachlogik mit Principal {tenantId, actor, ticket}; die DB setzt den Kontext NUR aus dem Ticket.
import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import type { Principal as AuthPrincipal } from "./platform/auth.ts";
import { TicketUnavailable, TicketRejected, type TicketSource } from "./platform/ticket.ts";
import type { Principal } from "./modules/mitglieder/mitglieder.routes.ts";

export interface WebDeps {
  pingDb: () => Promise<boolean>;
  verifyBearer: (authHeader: string | undefined) => Promise<AuthPrincipal>;
  getTicket: TicketSource;
  handleM05: (req: IncomingMessage, res: ServerResponse, p: Principal) => Promise<boolean>;
}

function json(res: ServerResponse, code: number, body: unknown): void {
  res.writeHead(code, { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" });
  res.end(JSON.stringify(body));
}

export function createWebServer(d: WebDeps): Server {
  return createServer(async (req, res) => {
    if (req.url === "/api/health") {
      const db = await d.pingDb();
      json(res, db ? 200 : 503, { status: db ? "ok" : "degraded", service: "vv-web", stage: 0, db });
      return;
    }
    if (req.url === "/api/me") {
      try {
        const p = await d.verifyBearer(req.headers["authorization"]);
        json(res, 200, { actor: p.actor, tenantId: p.tenantId, roles: p.roles });
      } catch (err) {
        json(res, 401, { error: "unauthorized", reason: (err as Error).message });
      }
      return;
    }
    // Modul M05 „Mitglieder": Principal NUR aus verifiziertem Token + signiertem Ticket (nie aus Body/Query).
    if ((req.url ?? "").startsWith("/api/m05/")) {
      let principal: AuthPrincipal;
      try {
        principal = await d.verifyBearer(req.headers["authorization"]);
      } catch (err) {
        json(res, 401, { ok: false, error: "unauthorized", reason: (err as Error).message });
        return;
      }
      let ticket: string;
      try {
        ticket = (await d.getTicket(req.headers["authorization"])).ticket;
      } catch (err) {
        if (err instanceof TicketRejected) { json(res, 401, { ok: false, error: "unauthorized", reason: "Token abgewiesen" }); return; }
        // TicketUnavailable und alles Unerwartete: fail-closed, kein Rückfall, kein Datenzugriff.
        res.setHeader("retry-after", "5");
        json(res, 503, { ok: false, error: "unavailable", reason: "vorübergehend nicht verfügbar" });
        if (!(err instanceof TicketUnavailable)) console.error("[vv-web] Ticket-Fehler:", (err as Error).message);
        return;
      }
      await d.handleM05(req, res, { tenantId: principal.tenantId, actor: principal.actor, ticket });
      return;
    }
    json(res, 200, { service: "vv-web", stage: 0, hint: "GET /api/health | /api/me (Bearer) | /api/m05/* (Bearer)" });
  });
}
