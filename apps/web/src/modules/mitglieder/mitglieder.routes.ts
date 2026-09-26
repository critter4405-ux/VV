// VV Modul M05 „Mitglieder" — HTTP-API (Routing + Validierung). Keine DB-Zugriffe hier:
// alles läuft über mitglieder.action.ts (Policy-Guard). Der Principal (tenantId/actor/ticket) stammt
// ausschließlich aus dem verifizierten OIDC-Token bzw. dem Ticket-Dienst, nie aus Body/Query.
import type { IncomingMessage, ServerResponse } from "node:http";
import * as A from "./mitglieder.action.ts";
import * as S from "./mitglieder.schema.ts";

const MAX_BODY = 64 * 1024;

export interface Principal { tenantId: string; actor: string; ticket: string }

type Handler = (ctx: A.Ctx, p: string[], body: unknown, q: URLSearchParams) => Promise<A.Result<unknown>>;

interface Route { method: string; re: RegExp; h: Handler }

const U = "([0-9a-fA-F-]{36})";
const REF = "([A-Za-z0-9._-]{3,64})";

export const ROUTES: Route[] = [
  { method: "GET", re: /^\/api\/m05\/members$/, h: (c, _p, _b, q) => {
      const includeLocked = q.get("includeLocked") === "true";
      const purpose = q.get("purpose");
      return A.listMembers(c, { includeLocked, purpose: includeLocked ? S.purpose(purpose) : null });
    } },
  { method: "GET", re: new RegExp(`^/api/m05/members/${U}$`), h: (c, p) => A.getMember(c, S.uuid(p[0], "memberId")) },
  { method: "POST", re: /^\/api\/m05\/members\/export$/, h: (c, _p, b) => A.exportMembers(c, S.parseExport(b)) },
  { method: "POST", re: /^\/api\/m05\/types$/, h: (c, _p, b) => A.createType(c, S.parseTypeCreate(b)) },
  { method: "POST", re: new RegExp(`^/api/m05/types/${U}/versions$`),
    h: (c, p, b) => A.newTypeVersion(c, S.uuid(p[0], "typeId"), S.parseTypeVersion(b)) },
  { method: "PUT", re: /^\/api\/m05\/settings$/, h: (c, _p, b) => A.updateSettings(c, S.parseSettings(b)) },
  { method: "POST", re: /^\/api\/m05\/periods$/, h: (c, _p, b) => A.applyMembership(c, S.parseApply(b)) },
  { method: "POST", re: new RegExp(`^/api/m05/periods/${U}/admit$`),
    h: (c, p, b) => A.admit(c, S.uuid(p[0], "periodId"), S.parseEffective(b)) },
  { method: "POST", re: new RegExp(`^/api/m05/periods/${U}/reject$`),
    h: (c, p, b) => A.reject(c, S.uuid(p[0], "periodId"), S.parseVersioned(b)) },
  { method: "POST", re: new RegExp(`^/api/m05/periods/${U}/suspend$`),
    h: (c, p, b) => A.suspend(c, S.uuid(p[0], "periodId"), S.parseEffective(b)) },
  { method: "POST", re: new RegExp(`^/api/m05/periods/${U}/resume$`),
    h: (c, p, b) => A.resume(c, S.uuid(p[0], "periodId"), S.parseEffective(b)) },
  { method: "POST", re: new RegExp(`^/api/m05/periods/${U}/change-type$`),
    h: (c, p, b) => A.changeType(c, S.uuid(p[0], "periodId"), S.parseChangeType(b)) },
  { method: "POST", re: new RegExp(`^/api/m05/periods/${U}/withdraw-notice$`),
    h: (c, p, b) => A.withdrawNotice(c, S.uuid(p[0], "periodId"), S.parseVersioned(b)) },
  { method: "POST", re: new RegExp(`^/api/m05/periods/${U}/request-termination$`),
    h: (c, p, b) => A.requestTermination(c, S.uuid(p[0], "periodId"), S.parseTermination(b)) },
  { method: "GET", re: /^\/api\/m05\/approvals$/, h: (c) => A.pendingApprovals(c) },
  { method: "POST", re: new RegExp(`^/api/m05/approvals/${U}/decide$`),
    h: (c, p, b) => A.decideApproval(c, S.uuid(p[0], "approvalId"), S.parseDecision(b)) },
  { method: "POST", re: new RegExp(`^/api/m05/proposals/${U}/decide$`),
    h: (c, p, b) => A.decideProposal(c, S.uuid(p[0], "proposalId"), S.parseProposalDecision(b)) },
  { method: "POST", re: /^\/api\/m05\/imports$/, h: (c, _p, b) => A.requestImport(c, S.parseImportRequest(b)) },
  { method: "POST", re: new RegExp(`^/api/m05/imports/${REF}/decide$`),
    h: (c, p, b) => A.decideImport(c, p[0]!, S.parseDecision(b)) },
];

const STATUS: Record<A.ErrorKind, number> = { unauthorized: 401, forbidden: 403, not_found: 404, conflict: 409, invalid: 400, internal: 500 };

export function match(method: string, path: string): { route: Route; params: string[] } | null {
  for (const r of ROUTES) {
    if (r.method !== method) continue;
    const m = r.re.exec(path);
    if (m) return { route: r, params: m.slice(1) };
  }
  return null;
}

async function readJson(req: IncomingMessage): Promise<unknown> {
  if (req.method === "GET") return undefined;
  const ct = String(req.headers["content-type"] ?? "");
  if (!ct.toLowerCase().startsWith("application/json")) throw new S.ValidationError("content-type", "application/json erwartet");
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of req) {
    size += (chunk as Buffer).length;
    if (size > MAX_BODY) throw new S.ValidationError("body", "zu groß");
    chunks.push(chunk as Buffer);
  }
  try {
    return JSON.parse(Buffer.concat(chunks).toString("utf8"));
  } catch {
    throw new S.ValidationError("body", "ungültiges JSON");
  }
}

function send(res: ServerResponse, code: number, body: unknown): void {
  res.writeHead(code, { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" });
  res.end(JSON.stringify(body));
}

/** true = Anfrage gehörte zu M05 (beantwortet), false = nicht zuständig. */
export async function handleM05(req: IncomingMessage, res: ServerResponse, principal: Principal): Promise<boolean> {
  const url = new URL(req.url ?? "/", "http://localhost");
  if (!url.pathname.startsWith("/api/m05/")) return false;
  const hit = match(req.method ?? "GET", url.pathname);
  if (!hit) { send(res, 404, { ok: false, error: "not_found" }); return true; }
  try {
    const body = await readJson(req);
    const result = await hit.route.h({ tenantId: principal.tenantId, actor: principal.actor, ticket: principal.ticket },
      hit.params, body, url.searchParams);
    send(res, result.ok ? 200 : STATUS[result.error], result);
  } catch (err) {
    if (err instanceof S.ValidationError) send(res, 400, { ok: false, error: "invalid", reason: err.message });
    else send(res, 500, { ok: false, error: "internal", reason: "interner Fehler" });
  }
  return true;
}
