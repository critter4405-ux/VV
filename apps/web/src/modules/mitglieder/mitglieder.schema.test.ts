// M05 — Unit-Tests der Eingabe-Validierung (rein, ohne DB).
import { test } from "node:test";
import assert from "node:assert/strict";
import * as S from "./mitglieder.schema.ts";

const U1 = "a0000000-0000-0000-0000-000000000011";

test("UUID: gültig/ungültig", () => {
  assert.equal(S.uuid(U1.toUpperCase(), "x"), U1);
  for (const bad of ["", "abc", `${U1}x`, "'; DROP TABLE member;--", 42, null]) {
    assert.throws(() => S.uuid(bad, "x"), S.ValidationError);
  }
});

test("Datum: echtes Kalenderdatum, kein 30. Februar, kein Freitext", () => {
  assert.equal(S.date("2026-02-28", "d"), "2026-02-28");
  for (const bad of ["2026-02-30", "2026-13-01", "26-01-01", "2026-1-1", "heute", "1800-01-01"]) {
    assert.throws(() => S.date(bad, "d"), S.ValidationError);
  }
});

test("Kündigung: Enum-Beendigungsart, Katalog-Codes statt Freitext", () => {
  const ok = S.parseTermination({ endKind: "ausgetreten", noticeReceivedOn: "2026-09-01", reasonCode: "umzug", expectedVersion: 3 });
  assert.equal(ok.endKind, "ausgetreten");
  assert.equal(ok.exclusionCode, null);
  assert.throws(() => S.parseTermination({ endKind: "gekuendigt_weil", expectedVersion: 1 }), S.ValidationError);
  assert.throws(() => S.parseTermination({ endKind: "ausgetreten", reasonCode: "Er ist nach Wien gezogen", expectedVersion: 1 }),
    S.ValidationError);
  assert.throws(() => S.parseTermination({ endKind: "ausgeschlossen", resolutionRef: "VS 2026 <script>", expectedVersion: 1 }),
    S.ValidationError);
  assert.throws(() => S.parseTermination({ endKind: "verstorben", expectedVersion: 0 }), S.ValidationError);
});

test("Entscheidung nur approved/rejected", () => {
  assert.deepEqual(S.parseDecision({ decision: "approved" }), { decision: "approved" });
  assert.throws(() => S.parseDecision({ decision: "APPROVED" }), S.ValidationError);
});

test("Freigeber kann NICHT über den Body gesetzt werden (Feld wird ignoriert)", () => {
  const d = S.parseDecision({ decision: "approved", approvedBy: "sub-vorstand-aa", actor: "x" }) as Record<string, unknown>;
  assert.equal(d.approvedBy, undefined);
  assert.equal(d.actor, undefined);
});

test("Mitgliedsart: Aging-up nur mit Folgeart; Codes/Namen streng", () => {
  const t = S.parseTypeCreate({ code: "jugend_u18", name: "Jugend U18", category: "jugend", youthAgeLimit: 18, successorTypeId: U1 });
  assert.equal(t.youthAgeLimit, 18);
  assert.throws(() => S.parseTypeCreate({ code: "j", name: "J", category: "jugend", youthAgeLimit: 18 }), S.ValidationError);
  assert.throws(() => S.parseTypeCreate({ code: "Jugend!", name: "J", category: "jugend" }), S.ValidationError);
  assert.throws(() => S.parseTypeCreate({ code: "x_y", name: "X", category: "vip" }), S.ValidationError);
});

test("Aufbewahrung nie unter 7 Jahre (P50-9)", () => {
  assert.throws(() => S.parseSettings({ lockAfterDays: 0, retentionYears: 3, agingUpLeadDays: 30 }), S.ValidationError);
  assert.equal(S.parseSettings({ lockAfterDays: 0, retentionYears: 7, agingUpLeadDays: 30 }).retentionYears, 7);
});

test("Export: Zweckangabe Pflicht, ohne Steuerzeichen", () => {
  assert.equal(S.parseExport({ purpose: "Kassaprüfung 2026 Mitgliederstand" }).includeLocked, false);
  assert.throws(() => S.parseExport({}), S.ValidationError);
  assert.throws(() => S.parseExport({ purpose: "kurz" }), S.ValidationError);
  assert.throws(() => S.parseExport({ purpose: "Kassaprüfung\u0000 2026 Stand" }), S.ValidationError);
});

test("Import-Antrag: SHA-256 + Batch-Referenz strikt", () => {
  const h = "a".repeat(64);
  assert.equal(S.parseImportRequest({ batchRef: "VP-2026-01", rowsSha256: h, rowCount: 10 }).rowCount, 10);
  assert.throws(() => S.parseImportRequest({ batchRef: "../x", rowsSha256: h, rowCount: 1 }), S.ValidationError);
  assert.throws(() => S.parseImportRequest({ batchRef: "VP1", rowsSha256: "zz", rowCount: 1 }), S.ValidationError);
  assert.throws(() => S.parseImportRequest({ batchRef: "VP1", rowsSha256: h, rowCount: 0 }), S.ValidationError);
});

test("Body muss ein Objekt sein", () => {
  for (const bad of [null, [], "x", 1]) assert.throws(() => S.asObject(bad), S.ValidationError);
});
