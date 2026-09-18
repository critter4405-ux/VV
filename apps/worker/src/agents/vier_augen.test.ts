// Adversarial-Selbsttest Vier-Augen (ADR-07). Läuft via `npm test` (node:test + tsx).
// Weist die von Codex (Runde 3, #1 CRITICAL) demonstrierten Umgehungen als GESCHLOSSEN nach:
// (a) Umetikettieren einer bindenden Senke, (b) erfundene Freigabe, (c) Token-Replay/Neustart.
import { test } from "node:test";
import assert from "node:assert/strict";
import { assertExecutable, executeBindingEffect, type ExecContext } from "./vier_augen.ts";
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
      (r.reviewerModel === null || r.reviewerModel !== r.builderModel));
    if (!hit) throw new Error("Keine gültige Vier-Augen-Freigabe — verweigert");
    hit.consumed = true;   // atomarer Einmal-Consume
  }
}

const ctx: ExecContext = { tenantId: "t-aa", subjectRef: "person-1", requestedBy: "agent-1" };

test("bindender Effekt ist server-seitig klassifiziert (Registry, nicht Aufrufer)", () => {
  assert.equal(getEffect("payment.execute")!.binding, true);
  assert.equal(getEffect("person.delete")!.binding, true);
  assert.equal(getEffect("reminder.dispatch")!.binding, false);
});

test("ADVERSARIAL a) Umetikettieren erreicht die Zahlungs-Senke NICHT", async () => {
  const store = new FakeStore();
  // Eine echte Zahlung MUSS den payment.execute-Effekt aufrufen -> ohne Freigabe abgewiesen.
  await assert.rejects(() => executeBindingEffect("payment.execute", ctx, store, async () => "PAID"),
    /Freigabe/);
  // „reminder.dispatch" ist ein anderer Effekt/Handler — er bewegt kein Geld, egal wie etikettiert.
  const r = await executeBindingEffect("reminder.dispatch", ctx, store, async () => "REMINDED");
  assert.equal(r, "REMINDED");
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
  await assert.doesNotReject(() => executeBindingEffect("person.delete", ctx, store, async () => "DELETED"));
  await assert.rejects(() => executeBindingEffect("person.delete", ctx, store, async () => "DELETED"),
    /Freigabe/);   // zweiter Versuch: bereits eingelöst
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
