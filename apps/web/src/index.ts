// VV Web/API — Einstieg. Minimaler HTTP-Server (kein Framework), damit `docker compose up` zuverlässig bootet.
// Voller Next.js/TS/Tailwind/shadcn-Layer folgt. Logik in server.ts (testbar, C-1 fail-closed).
import { pingDb } from "./db.ts";
import { verifyBearer } from "./platform/auth.ts";
import { httpTicketSource } from "./platform/ticket.ts";
import { handleM05 } from "./modules/mitglieder/mitglieder.routes.ts";
import { createWebServer } from "./server.ts";

const PORT = Number(process.env.PORT ?? 3000);

createWebServer({ pingDb, verifyBearer, getTicket: httpTicketSource(), handleM05 })
  .listen(PORT, () => console.log(`[vv-web] lauscht auf :${PORT}`));
