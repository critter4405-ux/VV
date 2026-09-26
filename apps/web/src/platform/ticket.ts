// VV Platform — Ticket-Übergabe (C-1 Kontext-Signatur, Grill P58). Die Web-App kennt den HMAC-Schlüssel NIE:
// Sie reicht das Bearer-Token des Nutzers an den internen Ticket-Dienst weiter und bekommt ein kurzlebiges,
// signiertes Ticket (Mandant, Nutzer, Ablauf, Kennung), das NUR die Datenbank prüfen kann (vv_set_context).
// Fail-closed: ist der Dienst weg/langsam/fehlkonfiguriert -> TicketUnavailable (HTTP 503), KEIN Rückfall.
export class TicketUnavailable extends Error {}
export class TicketRejected extends Error {}

export interface TicketGrant { ticket: string; exp: number }
export type TicketSource = (authorization: string | undefined) => Promise<TicketGrant>;

const TICKET = /^v1\.[a-z0-9]{1,16}\.[A-Za-z0-9_-]{16,700}\.[A-Za-z0-9_-]{43}$/;

export function httpTicketSource(url = process.env.TICKET_URL, timeoutMs = 2000): TicketSource {
  return async (authorization) => {
    if (!url) throw new TicketUnavailable("TICKET_URL nicht konfiguriert (fail-closed)");
    if (!authorization) throw new TicketRejected("kein Bearer-Token");
    let r: Response;
    try {
      r = await fetch(`${url.replace(/\/$/, "")}/v1/ticket`, {
        method: "POST", headers: { authorization }, signal: AbortSignal.timeout(timeoutMs), redirect: "error",
      });
    } catch {
      throw new TicketUnavailable("Ticket-Dienst nicht erreichbar");
    }
    if (r.status === 401 || r.status === 403) throw new TicketRejected("Token vom Ticket-Dienst abgewiesen");
    if (!r.ok) throw new TicketUnavailable(`Ticket-Dienst antwortet ${r.status}`);
    const body = (await r.json().catch(() => null)) as { ticket?: unknown; exp?: unknown } | null;
    if (!body || typeof body.ticket !== "string" || !TICKET.test(body.ticket) || typeof body.exp !== "number") {
      throw new TicketUnavailable("ungültige Antwort des Ticket-Dienstes");
    }
    return { ticket: body.ticket, exp: body.exp };
  };
}
