// VV Agenten — Vier-Augen-Zustandsautomat (ADR-07, BASIS-09).
// Review-Runde 2, Codex #7 (CRITICAL): `binding` war ein AUFRUFER-Feld — mit `binding:false`
// ließen sich Reviewer-Pflicht, Zustand und Token komplett überspringen. Fix: `binding` wird
// jetzt SERVER-SEITIG aus Aktion + Datenklasse KLASSIFIZIERT (`isBinding`) und ist nicht mehr
// vom Aufrufer setzbar. Nicht-bindende Ausführung ist nur unter einer AUSDRÜCKLICH
// REGISTRIERTEN stehenden Klasse-Freigabe erlaubt (B09-1) — alles andere schlägt fehl (fail-closed).

export type FourEyesState =
  | "drafted" | "reviewed" | "awaiting_human" | "approved" | "executed" | "escalated";

export type DataClass = "Oe" | "S" | "Se" | "F-Buch" | "F-Bank" | "A9";

const ALLOWED: Record<FourEyesState, FourEyesState[]> = {
  drafted:        ["reviewed", "escalated"],
  reviewed:       ["awaiting_human", "escalated"],
  awaiting_human: ["approved", "escalated"],
  approved:       ["executed", "escalated"],
  executed:       [],
  escalated:      [],
};

// --- Server-seitige Binding-Klassifikation (NICHT vom Aufrufer setzbar) ---------------------
// Bindend = Geld/Zahlung, behördliche Meldung, Löschung, Personendaten nach außen,
// rechtsverbindliche Erklärung. Wird aus der Aktion + Datenklasse abgeleitet.
const BINDING_ACTIONS: ReadonlySet<string> = new Set([
  "approve", "delete", "deactivate", "export",
  "payment.execute", "sepa.submit", "report.authority", "member.delete",
  "person.delete", "person.export",
]);
const BINDING_DATACLASSES: ReadonlySet<DataClass> = new Set(["F-Bank", "F-Buch", "A9", "Se"]);

export interface ActionClass {
  action: string;
  dataClass?: DataClass;
}

/** Ableitung der Verbindlichkeit rein aus der (server-klassifizierten) Aktion + Datenklasse. */
export function isBinding(a: ActionClass): boolean {
  if (BINDING_ACTIONS.has(a.action)) return true;
  if (a.dataClass && BINDING_DATACLASSES.has(a.dataClass)) return true;
  return false;
}

// Stehende Klasse-Freigaben (B09-1): NUR ausdrücklich registrierte, nicht-bindende
// Routineklassen dürfen ohne Einzel-Freigabe laufen. Unbekannte Aktion -> fail-closed.
const STANDING_CLASS_APPROVED: ReadonlySet<string> = new Set([
  "person.list", "person.read", "role_assignment.read", "reminder.dispatch",
]);

export interface ExecRequest {
  actionClass: ActionClass;      // server-seitig klassifiziert (aus Policy/Datenklasse)
  state: FourEyesState;
  builderModelFamily: string;
  reviewerModelFamily: string;
  requestedBy: string;
  approvedBy?: string;
  approvalToken?: string;        // Einmal-Token für bindende Ausführung
}

export function assertTransition(from: FourEyesState, to: FourEyesState): void {
  if (!ALLOWED[from].includes(to)) {
    throw new Error(`Unerlaubter Vier-Augen-Übergang: ${from} -> ${to}`);
  }
}

/** Prüf-KI MUSS aus anderer Modellfamilie stammen (ADR-07). */
export function assertIndependentReviewer(r: Pick<ExecRequest, "builderModelFamily" | "reviewerModelFamily">): void {
  if (!r.reviewerModelFamily || r.builderModelFamily === r.reviewerModelFamily) {
    throw new Error("Vier-Augen verletzt: Prüf-KI muss andere Modellfamilie sein (ADR-07)");
  }
}

// Einmal-Token-Speicher (Skeleton: In-Memory; Prod: DB-Zustandsautomat mit atomarem Consume
// via UPDATE ... WHERE consumed_at IS NULL RETURNING). Beim Modul-Bau ersetzt.
const consumedTokens = new Set<string>();
export function consumeApprovalToken(token: string | undefined): void {
  if (!token) throw new Error("Kein Freigabe-Token vorhanden");
  if (consumedTokens.has(token)) throw new Error("Freigabe-Token bereits eingelöst (Replay)");
  consumedTokens.add(token);
}

/**
 * Verbindliche Ausführung nur mit fremd-geprüfter, menschlich freigegebener, einmaliger Freigabe.
 * `binding` wird intern klassifiziert — ein Aufrufer kann Vier-Augen NICHT durch ein Flag umgehen.
 */
export function assertExecutable(r: ExecRequest): void {
  const binding = isBinding(r.actionClass);           // server-seitig, ignoriert jeden Aufrufer-Wunsch
  if (!binding) {
    // Nicht-bindend darf NUR laufen, wenn die Routineklasse ausdrücklich freigegeben ist (B09-1).
    if (!STANDING_CLASS_APPROVED.has(r.actionClass.action)) {
      throw new Error(
        `Keine stehende Klasse-Freigabe für '${r.actionClass.action}' (fail-closed) — ` +
        "unbekannte/nicht freigegebene Aktion erfordert Einzel-Freigabe (ADR-07/B09-1)");
    }
    return;
  }
  // Ab hier: bindend -> volles Vier-Augen erzwingen.
  assertIndependentReviewer(r);                        // Reviewer-Pflicht
  if (r.state !== "approved") {
    throw new Error("Keine verbindliche Ausführung ohne Zustand 'approved' (ADR-07)");
  }
  if (!r.approvedBy || r.approvedBy === r.requestedBy) {
    throw new Error("Vier-Augen verletzt: Antragsteller != Freigeber (SoD, K27)");
  }
  consumeApprovalToken(r.approvalToken);               // atomarer Einmal-Consume
}
