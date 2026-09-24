// VV Agenten — Effekt-Registry (ADR-07). Review-Runde 3, Codex #1 (CRITICAL):
// Die Verbindlichkeit einer Aktion darf NICHT aus einem frei gelieferten `actionClass`-Objekt
// kommen (sonst lässt sich eine Zahlung als „reminder.dispatch" etikettieren). Stattdessen wählt
// der Aufrufer eine EFFEKT-ID; jeder Effekt trägt eine FIXE, im Code definierte Klassifikation und
// einen FEST zugeordneten Ausführungsweg (M05-Reparaturrunde, R2/B-03 — vorher „später"):
//   execution="db-atomic"  -> nur die DB-Funktion löst Freigabe + Wirkung in EINER Transaktion ein
//                             (z. B. m05_execute); über den TS-Executor NICHT erreichbar.
//   execution="handler"    -> fester Handler aus der beim Start eingefrorenen Handler-Registry
//                             (vier_augen.ts, createExecutor) — nie vom Aufrufer übergeben.
//   execution="routine"    -> nicht-bindend, nur unter stehender Klasse-Freigabe.
// Die Senke ist so nur über ihren eigenen Effekt erreichbar — Umetikettieren erreicht sie nicht.

export type DataClass = "Oe" | "S" | "Se" | "F-Buch" | "F-Bank" | "A9";

export interface EffectDef {
  id: string;
  action: string;
  dataClass?: DataClass;
  binding: boolean;   // bindend = Geld/Meldung/Löschung/Personendaten nach außen/rechtsverbindlich
  execution: "db-atomic" | "handler" | "routine";
}

// Zentrale, code-definierte Klassifikation. NUR Einträge hier sind ausführbar (fail-closed).
export const EFFECTS = {
  // --- bindend: nur über echte, fremd-genehmigte, einmalige DB-Freigabe ausführbar ---
  "person.delete":    { id: "person.delete",    action: "delete",          dataClass: "S",      binding: true, execution: "handler" },
  "person.export":    { id: "person.export",    action: "export",          dataClass: "Se",     binding: true, execution: "handler" },
  "payment.execute":  { id: "payment.execute",  action: "payment.execute", dataClass: "F-Bank", binding: true, execution: "handler" },
  "sepa.submit":      { id: "sepa.submit",      action: "sepa.submit",     dataClass: "F-Bank", binding: true, execution: "handler" },
  "report.authority": { id: "report.authority", action: "report.authority",dataClass: "A9",     binding: true, execution: "handler" },
  // M05 „Mitglieder" (harte Grenzen): Ausführung NUR in der DB-Funktion m05_execute, die die
  // Freigabe atomar mit der Wirkung einlöst (Consume + Effekt in EINER Transaktion).
  "m05.membership.terminate": { id: "m05.membership.terminate", action: "deactivate", dataClass: "S", binding: true, execution: "db-atomic" },
  "m05.membership.anonymize": { id: "m05.membership.anonymize", action: "delete",     dataClass: "S", binding: true, execution: "db-atomic" },
  "q05.import.commit":        { id: "q05.import.commit",        action: "create",     dataClass: "S", binding: true, execution: "db-atomic" },
  // --- nicht-bindend: nur ausdrücklich registrierte Routineklassen (stehende Klasse-Freigabe) ---
  "reminder.dispatch":     { id: "reminder.dispatch",     action: "reminder.dispatch", binding: false, execution: "routine" },
  "person.list":           { id: "person.list",           action: "read",              dataClass: "S", binding: false, execution: "routine" },
  "person.read":           { id: "person.read",           action: "read",              dataClass: "S", binding: false, execution: "routine" },
  "role_assignment.read":  { id: "role_assignment.read",  action: "read",              dataClass: "Oe", binding: false, execution: "routine" },
} as const satisfies Record<string, EffectDef>;

export type EffectId = keyof typeof EFFECTS;

// Stehende Klasse-Freigaben (B09-1): registrierte, nicht-bindende Routineklassen.
export const STANDING_CLASS_APPROVED: ReadonlySet<string> = new Set<string>([
  "reminder.dispatch", "person.list", "person.read", "role_assignment.read",
]);

export function getEffect(effectId: string): EffectDef | undefined {
  return (EFFECTS as Record<string, EffectDef>)[effectId];
}
