// VV Ticket-Dienst — Prüfung des Keycloak-Access-Tokens (Keycloak unverändert; RS256 via JWKS, Issuer, Audience).
// Zusätzlich (Schutzziel B): nur ACCESS-Token (typ=Bearer, kein ID-/Refresh-Token), Mandant als UUID-Claim,
// begrenztes Token-Alter (eine übernommene App kann ein abgefangenes Token nur kurz weiterverwenden).
import { jwtVerify, type JWTVerifyGetKey, type JWTPayload } from "jose";

export interface VerifyOptions {
  jwks: JWTVerifyGetKey;
  issuer: string;
  audience: string;
  maxTokenAgeS: number;
  nowS?: () => number;
}

export interface VerifiedToken { sub: string; tenant: string; iat: number; exp: number }

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export class TokenRejected extends Error {}

export async function verifyAccessToken(token: string, o: VerifyOptions): Promise<VerifiedToken> {
  if (!token || token.length > 8192) throw new TokenRejected("kein/zu großes Token");
  let payload: JWTPayload;
  try {
    ({ payload } = await jwtVerify(token, o.jwks, {
      issuer: o.issuer,
      audience: o.audience,
      algorithms: ["RS256"],          // kein HS*/none — Keycloak-Realm-Schlüssel (RSA) bleibt unverändert
      clockTolerance: 5,
      requiredClaims: ["sub", "exp", "iat"],
    }));
  } catch (e) {
    throw new TokenRejected(`Token ungültig (${(e as { code?: string }).code ?? "verify"})`);
  }
  const p = payload as Record<string, unknown>;
  if (p["typ"] !== "Bearer") throw new TokenRejected("kein Access-Token (typ)");
  const sub = typeof p["sub"] === "string" ? p["sub"] : "";
  if (!sub || sub.length > 255 || sub.startsWith("system:")) throw new TokenRejected("ungültiges sub");
  const tenant = typeof p["tenant_id"] === "string" ? p["tenant_id"] : "";
  if (!UUID.test(tenant)) throw new TokenRejected("kein gültiger tenant_id-Claim");
  const now = (o.nowS ?? (() => Math.floor(Date.now() / 1000)))();
  const iat = Number(p["iat"]);
  if (!Number.isFinite(iat) || now - iat > o.maxTokenAgeS) throw new TokenRejected("Token zu alt");
  return { sub, tenant, iat, exp: Number(p["exp"]) };
}
