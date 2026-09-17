// VV Platform — OIDC-Bearer-Validierung (ADR-03/BASIS-10), WP6.
// Review-Befund Codex #10: es gab keine Token-Validierung; Endpunkte waren offen.
// Jetzt: echte JWT-Prüfung (Signatur via JWKS, Issuer, Audience). Fail-fast, wenn nicht
// konfiguriert (kein stiller offener Zugang). tenantId kommt aus verifizierten Claims
// -> speist withTenant (ADR-01), niemals roh aus dem Request.
import { createRemoteJWKSet, jwtVerify, type JWTPayload } from "jose";

const ISSUER = process.env.OIDC_ISSUER;
const AUDIENCE = process.env.OIDC_CLIENT_ID;

export interface Principal {
  actor: string;        // sub (Referenz, kein Klartext-Personenbezug)
  tenantId: string;     // aus verifiziertem Claim
  roles: string[];
}

let jwks: ReturnType<typeof createRemoteJWKSet> | undefined;

export async function verifyBearer(authHeader: string | undefined): Promise<Principal> {
  if (!ISSUER || !AUDIENCE) {
    throw new Error("OIDC nicht konfiguriert — fail-fast (kein offener Zugang)");
  }
  const token = (authHeader ?? "").replace(/^Bearer\s+/i, "").trim();
  if (!token) throw new Error("kein Bearer-Token");
  jwks ??= createRemoteJWKSet(new URL(`${ISSUER}/protocol/openid-connect/certs`));
  const { payload }: { payload: JWTPayload } = await jwtVerify(token, jwks, {
    issuer: ISSUER,
    audience: AUDIENCE,
  });
  const tenantId = String((payload as Record<string, unknown>)["tenant_id"] ?? "");
  if (!tenantId) throw new Error("kein tenant-Claim im Token");
  const roles = ((payload as Record<string, unknown>)["roles"] as string[] | undefined) ?? [];
  return { actor: String(payload.sub ?? "unknown"), tenantId, roles };
}
