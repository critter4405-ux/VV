// VV Ticket-Dienst — Ticket-Format (C-1, Bau-Auftrag §4). Muss byte-genau zur DB-Prüfung vv_set_context passen:
//   v1.<kid>.<payload_b64url>.<hmac_sha256_b64url>,  HMAC über "v1.<kid>.<payload_b64url>"
//   payload = {"t": Mandant (uuid), "s": Akteur (OIDC-sub), "iat": unix, "exp": unix (≤ 60 s), "jti": uuid}
// Kein Klartext-Personenbezug (sub ist eine Referenz). Die DB lehnt jede Abweichung ab (fail-closed).
import { createHmac, randomUUID } from "node:crypto";

export const MAX_TTL_S = 60;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const KID = /^[a-z0-9]{1,16}$/;

export interface TicketClaims { tenant: string; actor: string; iat: number; exp: number; jti: string }

export function b64url(buf: Buffer): string {
  return buf.toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** Baut die Nutzlast. exp = min(iat + ttl, Token-Ablauf) — ein Ticket überlebt nie das Access-Token. */
export function buildClaims(tenant: string, actor: string, nowS: number, ttlS: number, tokenExpS: number): TicketClaims {
  if (!UUID.test(tenant)) throw new Error("tenant ist keine UUID");
  if (!actor || actor.length > 255 || actor.startsWith("system:") || /[\u0000-\u001f\u007f]/.test(actor)) {
    throw new Error("ungültiger Akteur");
  }
  const ttl = Math.min(Math.max(1, Math.floor(ttlS)), MAX_TTL_S);
  const exp = Math.min(nowS + ttl, Math.floor(tokenExpS));
  if (exp <= nowS) throw new Error("Access-Token läuft ab — kein Ticket");
  return { tenant, actor, iat: nowS, exp, jti: randomUUID() };
}

export function signTicket(c: TicketClaims, kid: string, key: Buffer): string {
  if (!KID.test(kid)) throw new Error("ungültige Schlüssel-Kennung");
  if (key.length < 32) throw new Error("Schlüssel zu kurz (min. 32 Byte)");
  // Feste Schlüssel-Reihenfolge; die DB prüft die Schlüsselmenge exakt (t,s,iat,exp,jti).
  const payload = JSON.stringify({ t: c.tenant, s: c.actor, iat: c.iat, exp: c.exp, jti: c.jti });
  const body = b64url(Buffer.from(payload, "utf8"));
  const mac = createHmac("sha256", key).update(`v1.${kid}.${body}`, "ascii").digest();
  return `v1.${kid}.${body}.${b64url(mac)}`;
}
