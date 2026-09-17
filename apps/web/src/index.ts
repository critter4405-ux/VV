// VV Web/API — Stage-0-Einstieg. Minimaler HTTP-Server (kein Framework), damit
// `docker compose up` zuverlässig bootet. Voller Next.js/TS/Tailwind/shadcn-Layer folgt.
// WP6: /api/health offen; /api/me erfordert ein gültiges OIDC-Bearer-Token (fail-fast).
import { createServer } from "node:http";
import { pingDb } from "./db.ts";
import { verifyBearer } from "./platform/auth.ts";

const PORT = Number(process.env.PORT ?? 3000);

const server = createServer(async (req, res) => {
  if (req.url === "/api/health") {
    const db = await pingDb();
    res.writeHead(db ? 200 : 503, { "content-type": "application/json" });
    res.end(JSON.stringify({ status: db ? "ok" : "degraded", service: "vv-web", stage: 0, db }));
    return;
  }
  if (req.url === "/api/me") {
    try {
      const p = await verifyBearer(req.headers["authorization"]);
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({ actor: p.actor, tenantId: p.tenantId, roles: p.roles }));
    } catch (err) {
      res.writeHead(401, { "content-type": "application/json" });
      res.end(JSON.stringify({ error: "unauthorized", reason: (err as Error).message }));
    }
    return;
  }
  res.writeHead(200, { "content-type": "application/json" });
  res.end(JSON.stringify({ service: "vv-web", stage: 0, hint: "GET /api/health | /api/me (Bearer)" }));
});

server.listen(PORT, () => console.log(`[vv-web] Stage-0-Skeleton lauscht auf :${PORT}`));
