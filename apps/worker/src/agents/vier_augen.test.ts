// Adversarial-Selbsttest Vier-Augen (ADR-07). Läuft via `npm test` (node:test + tsx).
// Weist die von Codex (Runde 3, #1 CRITICAL) demonstrierten Umgehungen als GESCHLOSSEN nach:
// (a) Umetikettieren einer bindenden Senke, (b) erfundene Freigabe, (c) Token-Replay/Neustart.
import { test } from "node:test";
import assert from "node:assert/strict";
import { assertExecutable, createExecutor, executeBindingEffect, type ExecContext } from "./vier_augen.ts";
import type { ApprovalStore } from "./approval_store.ts";
import { getEffect } from "./effects.ts";

// In-Memory-Store, der GENAU das DB-Prädikat von vv_consume_approval nachbildet
// (approved + fremd-genehmigt + nicht abgelaufen + noch nicht eingelöst, atomar einmal).
interface Row {
  tenantId: string; effectId: string; subjectRef: string;
  status: string; approvedBy: string | null; requestedBy: string;
  reviewerModel: string | null; builderModel: string;
  expiresAt: number | null; consumed: boolean;
}
class FakeStore implements ApprovalStore {
  rows: Row[] = [];
  grant(r: Partial<Row> & { tenantId: string; effectId: string; subjectRef: string }): void {
    this.rows.push({
      status: "approved", approvedBy: "human-2", requestedBy: "agent-1",
      reviewerModel: "gpt", builderModel: "claude", expiresAt: null, consumed: false, ...r,
    });
  }
  async consume(tenantId: string, effectId: string, subjectRef: string): Promise<void> {
    const now = Date.now();
    const hit = this.rows.find(r =>
      r.tenantId === tenantId && r.effectId === effectId && r.subjectRef === subjectRef &&
      r.status === "approved" && !r.consumed &&
      (r.expiresAt === null || r.expiresAt > now) &&
      r.approvedBy !== null && r.approvedBy !== r.requestedBy &&
      attestationOk(r.builderModel, r.reviewerModel));
    if (!hit) throw new Error("Keine gültige Vier-Augen-Freigabe — verweigert");
    hit.consumed = true;   // atomarer Einmal-Consume
  }
}

// Spiegel von vv_model_family/vv_attestation_ok (Migration 0011, R3): Modell-Vorschläge brauchen
// eine Fremdfamilien-Attestation; menschliche/System-Anträge nicht.
function family(m: string | null): string | null {
  if (!m) return null;
  const x = m.toLowerCase();
  if (/^(human|system):/.test(x)) return x.split(":")[0]!;
  if (/(claude|anthropic|opus|sonnet|haiku)/.test(x)) return "anthropic";
  if (/(gpt|openai|codex|^o[0-9])/.test(x)) return "openai";
  if (/(gemini|google)/.test(x)) return "google";
  if (/(mistral|mixtral|codestral)/.test(x)) return "mistral";
  if (/(llama|meta)/.test(x)) return "meta";
  return null;                                   // Review R2 (H-1): unbekannt = keine Familie
}
const KNOWN = new Set(["anthropic", "openai", "google", "mistral", "meta"]);
function attestationOk(builder: string, reviewer: string | null): boolean {
  const fb = family(builder);
  if (fb === "human" || fb === "system") return true;
  const fr = family(reviewer);
  return !!fb && !!fr && KNOWN.has(fb) && KNOWN.has(fr) && fr !== fb;
}

// Test-Executor mit FEST registrierten Senken (wie Produktion, nur mit Test-Handlern).
const exec = createExecutor({
  "person.delete": async () => "DELETED",
  "payment.execute": async () => "PAID",
});

const ctx: ExecContext = { tenantId: "t-aa", subjectRef: "person-1", requestedBy: "agent-1" };

test("bindender Effekt ist server-seitig klassifiziert (Registry, nicht Aufrufer)", () => {
  assert.equal(getEffect("payment.execute")!.binding, true);
  assert.equal(getEffect("person.delete")!.binding, true);
  assert.equal(getEffect("reminder.dispatch")!.binding, false);
});

test("ADVERSARIAL a) Umetikettieren erreicht die Zahlungs-Senke NICHT", async () => {
  const store = new FakeStore();
  // Eine echte Zahlung MUSS den payment.execute-Effekt aufrufen -> ohne Freigabe abgewiesen.
  await assert.rejects(() => exec.execute("payment.execute", ctx, store), /Freigabe/);
});

test("ADVERSARIAL R2/B-03) kein Handler vom Aufrufer: nicht-bindende ID kann keine Senke ausführen", async () => {
  const store = new FakeStore();
  let paid = false;
  const pay = async () => { paid = true; return "PAID"; };
  // Früherer Angriff: executeBindingEffect("reminder.dispatch", ctx, store, pay) lief OHNE Freigabe.
  // Die API nimmt keinen Handler mehr; ein zusätzliches Argument wird ignoriert.
  // Reflect.apply: das überzählige Argument ist hier ABSICHT (Angriffs-Simulation), kein Aufruffehler.
  await assert.rejects(() => Reflect.apply(executeBindingEffect, undefined, ["reminder.dispatch", ctx, store, pay]), /nicht bindend/);
  await assert.rejects(() => Reflect.apply(exec.execute, exec, ["reminder.dispatch", ctx, store, pay]), /nicht bindend/);
  assert.equal(paid, false);
  // Registry lässt sich nicht nachträglich verbiegen:
  assert.throws(() => createExecutor({ "reminder.dispatch": pay }), /nicht als bindende Handler-Senke/);
  assert.throws(() => createExecutor({ "m05.membership.terminate": pay }), /nicht als bindende Handler-Senke/);
  assert.throws(() => createExecutor({ "gibt.es.nicht": pay }), /unbekannten Effekt/);
  assert.ok(Object.isFrozen(exec));
});

test("R2) DB-atomare M05-Effekte sind über den TS-Executor unerreichbar", async () => {
  const store = new FakeStore();
  store.grant({ tenantId: "t-aa", effectId: "m05.membership.terminate", subjectRef: "person-1" });
  await assert.rejects(() => exec.execute("m05.membership.terminate", ctx, store), /nur DB-atomar/);
  // Produktions-Executor hat (noch) keine TS-Senke registriert -> fail-closed
  store.grant({ tenantId: "t-aa", effectId: "person.delete", subjectRef: "person-1" });
  await assert.rejects(() => executeBindingEffect("person.delete", ctx, store), /Kein fest registrierter Handler/);
});

test("R3) Modell-Vorschlag ohne Fremdfamilien-Attestation wird nicht eingelöst", async () => {
  const store = new FakeStore();
  store.grant({ tenantId: "t-aa", effectId: "person.delete", subjectRef: "person-1", reviewerModel: null });
  await assert.rejects(() => exec.execute("person.delete", ctx, store), /Freigabe/);
  const s2 = new FakeStore();
  s2.grant({ tenantId: "t-aa", effectId: "person.delete", subjectRef: "person-1",
    builderModel: "claude-opus-5.5", reviewerModel: "claude-sonnet-4" });
  await assert.rejects(() => exec.execute("person.delete", ctx, s2), /Freigabe/);
  // Review R2 (H-1): leerer/unbekannter Builder ist auch mit fremdem Reviewer nicht einlösbar
  for (const builderModel of ["", "xyz-bot"]) {
    const s3 = new FakeStore();
    s3.grant({ tenantId: "t-aa", effectId: "person.delete", subjectRef: "person-1", builderModel, reviewerModel: "gpt-6-sol" });
    await assert.rejects(() => exec.execute("person.delete", ctx, s3), /Freigabe/);
  }
});

test("ADVERSARIAL b) erfundene Freigabe ohne echten DB-Eintrag wird abgewiesen", async () => {
  const store = new FakeStore();
  await assert.rejects(() => assertExecutable("person.delete", ctx, store), /Freigabe/);
  // Selbst-Freigabe (Freigeber == Antragsteller) zählt nicht:
  store.grant({ tenantId: "t-aa", effectId: "person.delete", subjectRef: "person-1", approvedBy: "agent-1" });
  await assert.rejects(() => assertExecutable("person.delete", ctx, store), /Freigabe/);
});

test("ADVERSARIAL b2) Reviewer aus gleicher Modellfamilie zählt nicht", async () => {
  const store = new FakeStore();
  store.grant({ tenantId: "t-aa", effectId: "person.delete", subjectRef: "person-1",
    reviewerModel: "claude", builderModel: "claude" });
  await assert.rejects(() => assertExecutable("person.delete", ctx, store), /Freigabe/);
});

test("ADVERSARIAL c) Token/Freigabe ist genau EINMAL einlösbar (Replay ROT)", async () => {
  const store = new FakeStore();
  store.grant({ tenantId: "t-aa", effectId: "person.delete", subjectRef: "person-1" });
  assert.equal(await exec.execute("person.delete", ctx, store), "DELETED");
  await assert.rejects(() => exec.execute("person.delete", ctx, store), /Freigabe/);   // Replay: bereits eingelöst
});

test("abgelaufene Freigabe wird abgewiesen", async () => {
  const store = new FakeStore();
  store.grant({ tenantId: "t-aa", effectId: "person.delete", subjectRef: "person-1", expiresAt: Date.now() - 1000 });
  await assert.rejects(() => assertExecutable("person.delete", ctx, store), /Freigabe/);
});

test("unbekannter Effekt: fail-closed; nicht-bindend nur wenn registriert", async () => {
  const store = new FakeStore();
  await assert.rejects(() => assertExecutable("unbekannt.effekt", ctx, store), /fail-closed/);
  await assert.doesNotReject(() => assertExecutable("person.list", ctx, store));  // registriert
});
