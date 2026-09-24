// VV Modul M05 „Mitglieder" — Eingabe-Validierung (rein, ohne DB; unit-getestet).
// Alles aus dem Request ist unvertrauenswürdig: strikte Typen, Formate, Enums, Längen.
// Die DB-Funktionen prüfen fachlich ein zweites Mal (Defense-in-Depth).

export class ValidationError extends Error {
  constructor(public readonly field: string, message: string) {
    super(`${field}: ${message}`);
  }
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const ISO_DATE = /^(\d{4})-(\d{2})-(\d{2})$/;

export const END_KINDS = ["ausgetreten", "ausgeschlossen", "verstorben"] as const;
export const CATEGORIES = ["aktiv", "unterstuetzend", "foerdernd", "ehren", "jugend"] as const;
export const CUTOFFS = ["sofort", "monatsende", "quartalsende", "halbjahresende", "jahresende"] as const;
export const DECISIONS = ["approved", "rejected"] as const;
export const PROPOSAL_DECISIONS = ["bestaetigt", "abgelehnt"] as const;

type Obj = Record<string, unknown>;

export function asObject(body: unknown): Obj {
  if (typeof body !== "object" || body === null || Array.isArray(body)) {
    throw new ValidationError("body", "JSON-Objekt erwartet");
  }
  return body as Obj;
}

export function uuid(v: unknown, field: string): string {
  if (typeof v !== "string" || !UUID.test(v)) throw new ValidationError(field, "UUID erwartet");
  return v.toLowerCase();
}

export function date(v: unknown, field: string): string {
  if (typeof v !== "string") throw new ValidationError(field, "Datum JJJJ-MM-TT erwartet");
  const m = ISO_DATE.exec(v);
  if (!m) throw new ValidationError(field, "Datum JJJJ-MM-TT erwartet");
  const [y, mo, d] = [Number(m[1]), Number(m[2]), Number(m[3])];
  const dt = new Date(Date.UTC(y, mo - 1, d));
  if (dt.getUTCFullYear() !== y || dt.getUTCMonth() !== mo - 1 || dt.getUTCDate() !== d || y < 1900 || y > 2200) {
    throw new ValidationError(field, "ungültiges Kalenderdatum");
  }
  return v;
}

export function optDate(v: unknown, field: string): string | null {
  return v === undefined || v === null ? null : date(v, field);
}

export function int(v: unknown, field: string, min: number, max: number): number {
  if (typeof v !== "number" || !Number.isInteger(v) || v < min || v > max) {
    throw new ValidationError(field, `Ganzzahl ${min}..${max} erwartet`);
  }
  return v;
}

export function oneOf<T extends string>(v: unknown, field: string, allowed: readonly T[]): T {
  if (typeof v !== "string" || !(allowed as readonly string[]).includes(v)) {
    throw new ValidationError(field, `erlaubt: ${allowed.join(", ")}`);
  }
  return v as T;
}

export function str(v: unknown, field: string, re: RegExp, maxLen: number): string {
  if (typeof v !== "string" || v.length > maxLen || !re.test(v)) throw new ValidationError(field, "ungültiges Format");
  return v;
}

export function optStr(v: unknown, field: string, re: RegExp, maxLen: number): string | null {
  return v === undefined || v === null ? null : str(v, field, re, maxLen);
}

export function bool(v: unknown, field: string, dflt: boolean): boolean {
  if (v === undefined || v === null) return dflt;
  if (typeof v !== "boolean") throw new ValidationError(field, "true/false erwartet");
  return v;
}

// Freitext ist im Kern verboten (P50-3); nur Zweckangabe beim Export (Pflicht) als kurzer Text,
// ohne Steuerzeichen.
export function purpose(v: unknown, field = "purpose"): string {
  if (typeof v !== "string") throw new ValidationError(field, "Zweckangabe erforderlich");
  const t = v.trim();
  if (t.length < 10 || t.length > 200 || /[\u0000-\u001f\u007f]/.test(t)) {
    throw new ValidationError(field, "Zweckangabe 10–200 Zeichen, ohne Steuerzeichen");
  }
  return t;
}

export const MEMBER_NO = /^[A-Za-z0-9._-]{1,32}$/;
export const CODE = /^[a-z0-9_]{2,40}$/;
export const REASON = /^[a-z_]{3,40}$/;
export const RESOLUTION = /^[A-Za-z0-9./_-]{1,64}$/;
export const BATCH = /^[A-Za-z0-9._-]{3,64}$/;
export const SHA256 = /^[0-9a-f]{64}$/;
export const NAME = /^[\p{L}\p{N} .,'()/-]{1,80}$/u;

// ---- Befehls-Schemata ------------------------------------------------------------------------
export function parseApply(b: unknown) {
  const o = asObject(b);
  return {
    personId: uuid(o.personId, "personId"),
    memberNo: o.memberNo === undefined || o.memberNo === null ? null : str(o.memberNo, "memberNo", MEMBER_NO, 32),
    typeId: uuid(o.typeId, "typeId"),
    appliedOn: date(o.appliedOn, "appliedOn"),
  };
}

export function parseVersioned(b: unknown) {
  const o = asObject(b);
  return { expectedVersion: int(o.expectedVersion, "expectedVersion", 1, 1_000_000) };
}

export function parseEffective(b: unknown) {
  const o = asObject(b);
  return { effective: date(o.effective, "effective"), expectedVersion: int(o.expectedVersion, "expectedVersion", 1, 1_000_000) };
}

export function parseChangeType(b: unknown) {
  const o = asObject(b);
  return {
    typeId: uuid(o.typeId, "typeId"),
    effectiveFrom: date(o.effectiveFrom, "effectiveFrom"),
    expectedVersion: int(o.expectedVersion, "expectedVersion", 1, 1_000_000),
  };
}

export function parseTermination(b: unknown) {
  const o = asObject(b);
  return {
    endKind: oneOf(o.endKind, "endKind", END_KINDS),
    noticeReceivedOn: optDate(o.noticeReceivedOn, "noticeReceivedOn"),
    reasonCode: optStr(o.reasonCode, "reasonCode", REASON, 40),
    exclusionCode: optStr(o.exclusionCode, "exclusionCode", REASON, 40),
    resolutionRef: optStr(o.resolutionRef, "resolutionRef", RESOLUTION, 64),
    effectiveDate: optDate(o.effectiveDate, "effectiveDate"),
    expectedVersion: int(o.expectedVersion, "expectedVersion", 1, 1_000_000),
  };
}

export function parseDecision(b: unknown) {
  return { decision: oneOf(asObject(b).decision, "decision", DECISIONS) };
}

export function parseProposalDecision(b: unknown) {
  return { decision: oneOf(asObject(b).decision, "decision", PROPOSAL_DECISIONS) };
}

export function parseTypeCreate(b: unknown) {
  const o = asObject(b);
  const youth = o.youthAgeLimit === undefined || o.youthAgeLimit === null ? null : int(o.youthAgeLimit, "youthAgeLimit", 6, 30);
  const succ = o.successorTypeId === undefined || o.successorTypeId === null ? null : uuid(o.successorTypeId, "successorTypeId");
  if ((youth === null) !== (succ === null)) throw new ValidationError("youthAgeLimit", "nur zusammen mit successorTypeId");
  return {
    code: str(o.code, "code", CODE, 40),
    name: str(o.name, "name", NAME, 80),
    category: oneOf(o.category, "category", CATEGORIES),
    noticeMonths: o.noticeMonths === undefined ? 0 : int(o.noticeMonths, "noticeMonths", 0, 24),
    cutoff: o.cutoff === undefined ? "sofort" : oneOf(o.cutoff, "cutoff", CUTOFFS),
    youthAgeLimit: youth,
    successorTypeId: succ,
  };
}

export function parseTypeVersion(b: unknown) {
  const o = asObject(b);
  const youth = o.youthAgeLimit === undefined || o.youthAgeLimit === null ? null : int(o.youthAgeLimit, "youthAgeLimit", 6, 30);
  const succ = o.successorTypeId === undefined || o.successorTypeId === null ? null : uuid(o.successorTypeId, "successorTypeId");
  if ((youth === null) !== (succ === null)) throw new ValidationError("youthAgeLimit", "nur zusammen mit successorTypeId");
  return {
    validFrom: date(o.validFrom, "validFrom"),
    noticeMonths: int(o.noticeMonths, "noticeMonths", 0, 24),
    cutoff: oneOf(o.cutoff, "cutoff", CUTOFFS),
    youthAgeLimit: youth,
    successorTypeId: succ,
  };
}

export function parseSettings(b: unknown) {
  const o = asObject(b);
  return {
    lockAfterDays: int(o.lockAfterDays, "lockAfterDays", 0, 365),
    retentionYears: int(o.retentionYears, "retentionYears", 7, 30),
    agingUpLeadDays: int(o.agingUpLeadDays, "agingUpLeadDays", 0, 180),
  };
}

export function parseExport(b: unknown) {
  const o = asObject(b);
  return { purpose: purpose(o.purpose), includeLocked: bool(o.includeLocked, "includeLocked", false) };
}

export function parseImportRequest(b: unknown) {
  const o = asObject(b);
  return {
    batchRef: str(o.batchRef, "batchRef", BATCH, 64),
    rowsSha256: str(o.rowsSha256, "rowsSha256", SHA256, 64),
    rowCount: int(o.rowCount, "rowCount", 1, 20000),
  };
}
