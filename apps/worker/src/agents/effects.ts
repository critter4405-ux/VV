// VV Agenten — Effekt-Registry (ADR-07). Review-Runde 3, Codex #1 (CRITICAL):
// Die Verbindlichkeit einer Aktion darf NICHT aus einem frei gelieferten `actionClass`-Objekt
// kommen (sonst lässt sich eine Zahlung als „reminder.dispatch" etikettieren). Stattdessen wählt
// der Aufrufer eine EFFEKT-ID; jeder Effekt trägt eine FIXE, im Code definierte Klassifikation und
// (später) einen fest zugeordneten Handler. Die Senke ist so nur über ihren eigenen Effekt
// erreichbar — Umetikettieren erreicht die falsche Senke nicht.

export type DataClass = "Oe" | "S" | "Se" | "F-Buch" | "F-Bank" | "A9";

export interface EffectDef {
  id: string;
  action: string;
  dataClass?: DataClass;
  binding: boolean;   // bindend = Geld/Meldung/Löschung/Personendaten nach außen/rechtsverbindlich
}

// Zentrale, code-definierte Klassifikation. NUR Einträge hier sind ausführbar (fail-closed).
export const EFFECTS = {
  // --- bindend: nur über echte, fremd-genehmigte, einmalige DB-Freigabe ausführbar ---
  "person.delete":    { id: "person.delete",    action: "delete",          dataClass: "S",      binding: true  },
  "person.export":    { id: "person.export",    action: "export",          dataClass: "Se",     binding: true  },
  "payment.execute":  { id: "payment.execute",  action: "payment.execute", dataClass: "F-Bank", binding: true  },
  "sepa.submit":      { id: "sepa.submit",      action: "sepa.submit",     dataClass: "F-Bank", binding: true  },
  "report.authority": { id: "report.authority", action: "report.authority",dataClass: "A9",     binding: true  },
  // --- nicht-bindend: nur ausdrücklich registrierte Routineklassen (stehende Klasse-Freigabe) ---
  "reminder.dispatch":     { id: "reminder.dispatch",     action: "reminder.dispatch", binding: false },
  "person.list":           { id: "person.list",           action: "read",              dataClass: "S", binding: false },
  "person.read":           { id: "person.read",           action: "read",              dataClass: "S", binding: false },
  "role_assignment.read":  { id: "role_assignment.read",  action: "read",              dataClass: "Oe", binding: false },
} as const satisfies Record<string, EffectDef>;

export type EffectId = keyof typeof EFFECTS;

// Stehende Klasse-Freigaben (B09-1): registrierte, nicht-bindende Routineklassen.
export const STANDING_CLASS_APPROVED: ReadonlySet<string> = new Set<string>([
  "reminder.dispatch", "person.list", "person.read", "role_assignment.read",
]);

export function getEffect(effectId: string): EffectDef | undefined {
  return (EFFECTS as Record<string, EffectDef>)[effectId];
}
