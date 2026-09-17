// Adversarial-Selbsttest Vier-Augen (ADR-07). Läuft via `npm test` (node:test + tsx).
// Weist die von Codex (Runde 2, #7) demonstrierte Umgehung als GESCHLOSSEN nach:
// eine bindende Aktion lässt sich NICHT durch ein Aufrufer-Flag entschärfen.
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  assertExecutable, isBinding, type ExecRequest,
} from "./vier_augen.ts";

const base: ExecRequest = {
  actionClass: { action: "person.delete", dataClass: "S" },
  state: "drafted",
  builderModelFamily: "claude",
  reviewerModelFamily: "gpt",
  requestedBy: "u1",
};

test("Löschen wird server-seitig als bindend klassifiziert", () => {
  assert.equal(isBinding({ action: "person.delete" }), true);
  assert.equal(isBinding({ action: "payment.execute" }), true);
  assert.equal(isBinding({ action: "x", dataClass: "F-Bank" }), true);
});

test("ADVERSARIAL: bindende Aktion NICHT über Aufrufer umgehbar", () => {
  // Kein Aufrufer-Flag mehr vorhanden; selbst ohne Reviewer/Approval bleibt es bindend.
  assert.throws(() => assertExecutable({ ...base }), /approved|Reviewer|Modellfamilie/i);
});

test("bindend braucht Reviewer aus anderer Familie", () => {
  assert.throws(
    () => assertExecutable({ ...base, state: "approved", approvedBy: "u2",
      approvalToken: "t1", reviewerModelFamily: "claude" }),
    /Modellfamilie/i);
});

test("bindend braucht approved + fremden Freigeber + Token", () => {
  assert.throws(() => assertExecutable({ ...base, state: "approved", approvedBy: "u1",
    approvalToken: "t2" }), /Antragsteller != Freigeber/);
  // Vollständig korrekt -> erlaubt, Token einmalig.
  const ok: ExecRequest = { ...base, state: "approved", approvedBy: "u2", approvalToken: "t3" };
  assert.doesNotThrow(() => assertExecutable(ok));
  assert.throws(() => assertExecutable(ok), /Replay/);   // Token-Wiedereinlösung blockiert
});

test("nicht-bindend nur unter registrierter stehender Klasse-Freigabe (fail-closed)", () => {
  assert.doesNotThrow(() => assertExecutable({
    ...base, actionClass: { action: "person.list" } }));            // registriert
  assert.throws(() => assertExecutable({
    ...base, actionClass: { action: "unbekannt.routine" } }), /fail-closed/);  // unbekannt -> ROT
});
