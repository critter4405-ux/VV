// VV Ticket-Dienst — Start (C-1 Kontext-Signatur, Grill P58). Zustandslos; Konfiguration fail-fast.
//   OIDC_ISSUER, OIDC_AUDIENCE (Default vv-web), OIDC_JWKS_URL (Default <issuer>/protocol/openid-connect/certs),
//   TICKET_KEYRING_FILE (Default /run/secrets/ticket_keyring), PORT (8081), TICKET_TTL_S (≤ 60),
//   TICKET_MAX_TOKEN_AGE_S (Default 300 = Keycloak-Access-Token-Lebensdauer)
import { createRemoteJWKSet } from "jose";
import { KeyringFile } from "./keyring.ts";
import { createTicketServer } from "./server.ts";

function need(name: string): string {
  const v = process.env[name];
  if (!v) { console.error(`[vv-ticket] ${name} fehlt — Abbruch (fail-fast)`); process.exit(1); }
  return v;
}

const issuer = need("OIDC_ISSUER");
const audience = process.env.OIDC_AUDIENCE ?? "vv-web";
const jwksUrl = process.env.OIDC_JWKS_URL ?? `${issuer}/protocol/openid-connect/certs`;
const keyring = new KeyringFile(process.env.TICKET_KEYRING_FILE ?? "/run/secrets/ticket_keyring");
try { keyring.current(); } catch (e) {
  console.error(`[vv-ticket] Keyring nicht ladbar (${(e as Error).message}) — Abbruch`); process.exit(1);
}
process.on("SIGHUP", () => { keyring.reload(); console.log("[vv-ticket] Keyring neu geladen"); });

const server = createTicketServer({
  verify: { jwks: createRemoteJWKSet(new URL(jwksUrl), { timeoutDuration: 3000, cooldownDuration: 30_000 }),
            issuer, audience, maxTokenAgeS: Number(process.env.TICKET_MAX_TOKEN_AGE_S ?? 300) },
  keyring,
  ttlS: Number(process.env.TICKET_TTL_S ?? 60),
});
const port = Number(process.env.PORT ?? 8081);
server.listen(port, process.env.TICKET_BIND ?? "0.0.0.0", () => console.log(`[vv-ticket] lauscht auf :${port} (intern)`));
for (const s of ["SIGTERM", "SIGINT"] as const) process.on(s, () => server.close(() => process.exit(0)));
