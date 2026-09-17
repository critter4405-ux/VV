// VV Web/API — Stage-0-Einstieg. Minimaler HTTP-Server (kein Framework), damit
// `docker compose up` zuverlässig bootet. Der volle Next.js/TS/Tailwind/shadcn-Layer
// wird in späteren Stufen darübergelegt (ADR-02: modularer Monolith).
import { createServer } from "node:http";
import { pingDb } from "./db.ts";

const PORT = Number(process.env.PORT ?? 3000);

const server = createServer(async (req, res) => {
  if (req.url === "/api/health") {
    const db = await pingDb();
    res.writeHead(db ? 200 : 503, { "content-type": "application/json" });
    res.end(JSON.stringify({ status: db ? "ok" : "degraded", service: "vv-web", stage: 0, db }));
    return;
  }
  res.writeHead(200, { "content-type": "application/json" });
  res.end(JSON.stringify({ service: "vv-web", stage: 0, hint: "GET /api/health" }));
});

server.listen(PORT, () => {
  console.log(`[vv-web] Stage-0-Skeleton lauscht auf :${PORT}`);
});
