// VV Modul M05 „Mitglieder" — Aktionen (einziger App-Pfad zu den M05-Fachfunktionen).
// Jede exportierte Aktion: (1) zentraler Policy-Prüfpunkt (ADR-04) + Guard, (2) EIN DB-Aufruf in
// einer Transaktion mit verifiziertem Tenant + Actor (withTenant), (3) die DB-Funktion prüft das
// Recht am Objekt erneut, schreibt Audit + Outbox atomar (ADR-05). Kein Cross-Modul-Import (ADR-02).
// Bindendes (Beendigung/Anonymisierung) entsteht hier NIE direkt — nur als Freigabe-Objekt;
// ausgeführt wird es ausschließlich vom Worker nach fremder Freigabe (Vier-Augen, ADR-07).
import { checkPolicy, type PolicyDecision } from "../../platform/policy.ts";
import { withTenant } from "../../platform/tenant.ts";
import { pool } from "../../db.ts";

export interface Ctx { tenantId: string; actor: string }

export type ErrorKind = "forbidden" | "not_found" | "conflict" | "invalid" | "internal";
export type Result<T> = { ok: true; data: T } | { ok: false; error: ErrorKind; reason: string };

// "any": grobe Vorprüfung „Recht irgendwo" (R7). Zulässig NUR, weil JEDE M05-DB-Funktion das Recht
// je Objekt mit den Scopes der Zielperson erneut prüft (m05_require/m05_member_rows/vv_authorize).
const SCOPE = "any";

/** SQLSTATE -> fachlicher Fehler. Interne Details (Stack, SQL) verlassen den Server nie. */
export function mapDbError(err: unknown): { ok: false; error: ErrorKind; reason: string } {
  const e = err as { code?: string; message?: string };
  const msg = typeof e?.message === "string" ? e.message.split("\n")[0]!.slice(0, 300) : "";
  switch (e?.code) {
    case "42501": return { ok: false, error: "forbidden", reason: "deny-by-default" };
    case "P0002": return { ok: false, error: "not_found", reason: msg };
    case "40001": case "23505": return { ok: false, error: "conflict", reason: msg };
    case "P0001": case "23514": case "22007": case "22008": case "22P02": case "23503":
      return { ok: false, error: "invalid", reason: msg.startsWith("M05") || msg.startsWith("deny") ? msg : "ungültige Eingabe" };
    default: return { ok: false, error: "internal", reason: "interner Fehler" };
  }
}

function denied(d: PolicyDecision): { ok: false; error: ErrorKind; reason: string } {
  return { ok: false, error: "forbidden", reason: d.reason };
}

/** Ein DB-Aufruf in einer Transaktion (Tenant + Actor transaktionsgebunden). Nur nach Policy-Guard. */
async function dbCall<T>(ctx: Ctx, sql: string, params: unknown[], map: (rows: any[]) => T): Promise<Result<T>> {
  const client = await pool.connect();
  try {
    const data = await withTenant(client, ctx.tenantId, async () => {
      const { rows } = await client.query(sql, params);
      return map(rows);
    }, ctx.actor);
    return { ok: true, data };
  } catch (err) {
    return mapDbError(err);
  } finally {
    client.release();
  }
}

// ---------------------------------------------------------------- Lesen
export async function listMembers(ctx: Ctx, opts: { includeLocked: boolean; purpose: string | null }) {
  const decision = await checkPolicy({ ...ctx, resource: "membership", action: "read", scopeNode: SCOPE, dataClass: "Oe" });
  if (!decision.allowed) { return denied(decision); }
  return dbCall(ctx, "SELECT * FROM m05_list_members($1, $2)", [opts.includeLocked, opts.purpose], (r) => r);
}

export async function getMember(ctx: Ctx, memberId: string) {
  const decision = await checkPolicy({ ...ctx, resource: "membership", action: "read", scopeNode: SCOPE, dataClass: "Oe" });
  if (!decision.allowed) { return denied(decision); }
  return dbCall(ctx, "SELECT m05_get_member($1) AS m", [memberId], (r) => r[0]?.m ?? null);
}

export async function exportMembers(ctx: Ctx, opts: { purpose: string; includeLocked: boolean }) {
  const decision = await checkPolicy({ ...ctx, resource: "membership", action: "export", scopeNode: SCOPE, dataClass: "Oe" });
  if (!decision.allowed) { return denied(decision); }
  return dbCall(ctx, "SELECT * FROM m05_export_members($1, $2)", [opts.purpose, opts.includeLocked], (r) => r);
}

export async function pendingApprovals(ctx: Ctx) {
  const decision = await checkPolicy({ ...ctx, resource: "membership", action: "approve", scopeNode: SCOPE, dataClass: "S" });
  if (!decision.allowed) { return denied(decision); }
  return dbCall(ctx, "SELECT * FROM m05_pending_approvals()", [], (r) => r);
}

// ---------------------------------------------------------------- Mitgliedsarten / Config
export async function createType(ctx: Ctx, i: { code: string; name: string; category: string; noticeMonths: number;
  cutoff: string; youthAgeLimit: number | null; successorTypeId: string | null }) {
  const decision = await checkPolicy({ ...ctx, resource: "membership_type", action: "create", scopeNode: SCOPE, dataClass: "Oe" });
  if (!decision.allowed) { return denied(decision); }
  return dbCall(ctx, "SELECT m05_type_create($1,$2,$3,$4,$5,$6,$7) AS id",
    [i.code, i.name, i.category, i.noticeMonths, i.cutoff, i.youthAgeLimit, i.successorTypeId], (r) => ({ typeId: r[0].id as string }));
}

export async function newTypeVersion(ctx: Ctx, typeId: string, i: { validFrom: string; noticeMonths: number; cutoff: string;
  youthAgeLimit: number | null; successorTypeId: string | null }) {
  const decision = await checkPolicy({ ...ctx, resource: "membership_type", action: "update", scopeNode: SCOPE, dataClass: "Oe" });
  if (!decision.allowed) { return denied(decision); }
  return dbCall(ctx, "SELECT m05_type_new_version($1,$2,$3,$4,$5,$6) AS v",
    [typeId, i.validFrom, i.noticeMonths, i.cutoff, i.youthAgeLimit, i.successorTypeId], (r) => ({ version: r[0].v as number }));
}

export async function updateSettings(ctx: Ctx, i: { lockAfterDays: number; retentionYears: number; agingUpLeadDays: number;
  holdExtensionMonths: number | null }) {
  const decision = await checkPolicy({ ...ctx, resource: "membership_type", action: "update", scopeNode: SCOPE, dataClass: "Oe" });
  if (!decision.allowed) { return denied(decision); }
  return dbCall(ctx, "SELECT m05_settings_update($1,$2,$3,$4)",
    [i.lockAfterDays, i.retentionYears, i.agingUpLeadDays, i.holdExtensionMonths], () => ({}));
}

// ---------------------------------------------------------------- Lebenszyklus (einfache Aktionen)
export async function applyMembership(ctx: Ctx, i: { personId: string; memberNo: string | null; typeId: string; appliedOn: string }) {
  const decision = await checkPolicy({ ...ctx, resource: "membership", action: "create", scopeNode: SCOPE, dataClass: "S" });
  if (!decision.allowed) { return denied(decision); }
  return dbCall(ctx, "SELECT m05_apply($1,$2,$3,$4) AS id", [i.personId, i.memberNo, i.typeId, i.appliedOn],
    (r) => ({ periodId: r[0].id as string }));
}

export async function admit(ctx: Ctx, periodId: string, i: { effective: string; expectedVersion: number }) {
  const decision = await checkPolicy({ ...ctx, resource: "membership", action: "update", scopeNode: SCOPE, dataClass: "S" });
  if (!decision.allowed) { return denied(decision); }
  return dbCall(ctx, "SELECT m05_admit($1,$2,$3) AS v", [periodId, i.effective, i.expectedVersion], (r) => ({ version: r[0].v }));
}

export async function reject(ctx: Ctx, periodId: string, i: { expectedVersion: number }) {
  const decision = await checkPolicy({ ...ctx, resource: "membership", action: "update", scopeNode: SCOPE, dataClass: "S" });
  if (!decision.allowed) { return denied(decision); }
  return dbCall(ctx, "SELECT m05_reject($1,$2) AS v", [periodId, i.expectedVersion], (r) => ({ version: r[0].v }));
}

export async function suspend(ctx: Ctx, periodId: string, i: { effective: string; expectedVersion: number }) {
  const decision = await checkPolicy({ ...ctx, resource: "membership", action: "update", scopeNode: SCOPE, dataClass: "S" });
  if (!decision.allowed) { return denied(decision); }
  return dbCall(ctx, "SELECT m05_suspend($1,$2,$3) AS v", [periodId, i.effective, i.expectedVersion], (r) => ({ version: r[0].v }));
}

export async function resume(ctx: Ctx, periodId: string, i: { effective: string; expectedVersion: number }) {
  const decision = await checkPolicy({ ...ctx, resource: "membership", action: "update", scopeNode: SCOPE, dataClass: "S" });
  if (!decision.allowed) { return denied(decision); }
  return dbCall(ctx, "SELECT m05_resume($1,$2,$3) AS v", [periodId, i.effective, i.expectedVersion], (r) => ({ version: r[0].v }));
}

export async function changeType(ctx: Ctx, periodId: string, i: { typeId: string; effectiveFrom: string; expectedVersion: number }) {
  const decision = await checkPolicy({ ...ctx, resource: "membership", action: "update", scopeNode: SCOPE, dataClass: "S" });
  if (!decision.allowed) { return denied(decision); }
  return dbCall(ctx, "SELECT m05_change_type($1,$2,$3,$4) AS v", [periodId, i.typeId, i.effectiveFrom, i.expectedVersion],
    (r) => ({ version: r[0].v }));
}

export async function withdrawNotice(ctx: Ctx, periodId: string, i: { expectedVersion: number }) {
  const decision = await checkPolicy({ ...ctx, resource: "membership", action: "deactivate", scopeNode: SCOPE, dataClass: "S" });
  if (!decision.allowed) { return denied(decision); }
  return dbCall(ctx, "SELECT m05_withdraw_notice($1,$2) AS v", [periodId, i.expectedVersion], (r) => ({ version: r[0].v }));
}

export async function decideProposal(ctx: Ctx, proposalId: string, i: { decision: string }) {
  const decision = await checkPolicy({ ...ctx, resource: "membership", action: "update", scopeNode: SCOPE, dataClass: "S" });
  if (!decision.allowed) { return denied(decision); }
  return dbCall(ctx, "SELECT m05_decide_proposal($1,$2) AS r", [proposalId, i.decision], (r) => r[0].r);
}

// ---------------------------------------------------------------- Harte Grenzen: nur Antrag/Entscheidung
export async function requestTermination(ctx: Ctx, periodId: string, i: { endKind: string; noticeReceivedOn: string | null;
  reasonCode: string | null; exclusionCode: string | null; resolutionRef: string | null; effectiveDate: string | null;
  expectedVersion: number }) {
  const decision = await checkPolicy({ ...ctx, resource: "membership", action: "deactivate", scopeNode: SCOPE, dataClass: "S" });
  if (!decision.allowed) { return denied(decision); }
  return dbCall(ctx, "SELECT m05_request_termination($1,$2,$3,$4,$5,$6,$7,$8) AS id",
    [periodId, i.endKind, i.noticeReceivedOn, i.reasonCode, i.exclusionCode, i.resolutionRef, i.effectiveDate, i.expectedVersion],
    (r) => ({ approvalId: r[0].id as string, requiresApproval: true }));
}

export async function decideApproval(ctx: Ctx, approvalId: string, i: { decision: string }) {
  const decision = await checkPolicy({ ...ctx, resource: "membership", action: "approve", scopeNode: SCOPE, dataClass: "S" });
  if (!decision.allowed) { return denied(decision); }
  return dbCall(ctx, "SELECT m05_decide($1,$2) AS r", [approvalId, i.decision], (r) => r[0].r);
}

// ---------------------------------------------------------------- Import-Schnittstelle (Q05)
export async function requestImport(ctx: Ctx, i: { batchRef: string; rowsSha256: string; rowCount: number }) {
  const decision = await checkPolicy({ ...ctx, resource: "membership", action: "create", scopeNode: SCOPE, dataClass: "S" });
  if (!decision.allowed) { return denied(decision); }
  return dbCall(ctx, "SELECT m05_import_request($1,$2,$3) AS id", [i.batchRef, i.rowsSha256, i.rowCount],
    (r) => ({ approvalId: r[0].id as string, requiresApproval: true }));
}

export async function decideImport(ctx: Ctx, batchRef: string, i: { decision: string }) {
  const decision = await checkPolicy({ ...ctx, resource: "membership", action: "approve", scopeNode: SCOPE, dataClass: "S" });
  if (!decision.allowed) { return denied(decision); }
  return dbCall(ctx, "SELECT m05_import_decide($1,$2) AS r", [batchRef, i.decision], (r) => r[0].r);
}
