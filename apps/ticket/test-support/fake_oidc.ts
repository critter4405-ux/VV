// NUR TEST (C-1 e2e, scripts/c1_e2e.sh): minimaler OIDC-Aussteller mit eigenem RSA-Schlüssel — JWKS unter dem
// Keycloak-Pfad + Test-Endpunkt /mint, der synthetische Access-Tokens signiert. Nie in Produktion/Compose.
import { createServer } from "node:http";
import { generateKeyPair, exportJWK, SignJWT } from "jose";

const PORT = Number(process.env.FAKE_OIDC_PORT ?? 18080);
const ISS = `http://127.0.0.1:${PORT}/realms/vv`;
const { publicKey, privateKey } = await generateKeyPair("RS256");
const foreign = await generateKeyPair("RS256");
const jwk = { ...(await exportJWK(publicKey)), kid: "e2e", alg: "RS256", use: "sig" };

createServer(async (req, res) => {
  const url = new URL(req.url ?? "/", ISS);
  if (url.pathname === "/realms/vv/protocol/openid-connect/certs") {
    res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify({ keys: [jwk] }));
    return;
  }
  if (url.pathname === "/mint") {
    const q = url.searchParams;
    const now = Math.floor(Date.now() / 1000);
    const tok = await new SignJWT({ typ: q.get("typ") ?? "Bearer", tenant_id: q.get("tenant") ?? "", roles: [] })
      .setProtectedHeader({ alg: "RS256", kid: "e2e" })
      .setIssuer(q.get("iss") ?? ISS).setAudience(q.get("aud") ?? "vv-web").setSubject(q.get("sub") ?? "x")
      .setIssuedAt(now).setExpirationTime(now + 300)
      .sign(q.get("foreign") ? foreign.privateKey : privateKey);
    res.writeHead(200, { "content-type": "text/plain" }).end(tok);
    return;
  }
  res.writeHead(404).end();
}).listen(PORT, "127.0.0.1", () => console.log(`[fake-oidc] ${ISS}`));
