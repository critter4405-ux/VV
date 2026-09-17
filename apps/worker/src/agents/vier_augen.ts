// VV Agenten — Vier-Augen-Zustandsautomat (ADR-07, BASIS-09), WP4-gehärtet.
// Review-Befund Codex #7: assertExecutable prüfte den Reviewer nicht, `binding` war frei
// setzbar, es gab kein Token. Jetzt: erzwungene Zustandsübergänge, Reviewer-Pflicht,
// Human-Approval, einmalig einlösbares Freigabe-Token (atomarer Consume).

export type FourEyesState =
  | "drafted" | "reviewed" | "awaiting_human" | "approved" | "executed" | "escalated";

const ALLOWED: Record<FourEyesState, FourEyesState[]> = {
  drafted:        ["reviewed", "escalated"],
  reviewed:       ["awaiting_human", "escalated"],
  awaiting_human: ["approved", "escalated"],
  approved:       ["executed", "escalated"],
  executed:       [],
  escalated:      [],
};

export interface Task {
  state: FourEyesState;
  builderModelFamily: string;
  reviewerModelFamily: string;
  requestedBy: string;
  approvedBy?: string;
  binding: boolean;             // Geld/Meldung/Löschung/Personendaten nach außen/rechtsverbindlich
  approvalToken?: string;       // einmalig, wird beim Ausführen eingelöst
}

export function assertTransition(from: FourEyesState, to: FourEyesState): void {
  if (!ALLOWED[from].includes(to)) {
    throw new Error(`Unerlaubter Vier-Augen-Übergang: ${from} -> ${to}`);
  }
}

/** Prüf-KI MUSS aus anderer Modellfamilie stammen (ADR-07). */
export function assertIndependentReviewer(t: Task): void {
  if (!t.reviewerModelFamily || t.builderModelFamily === t.reviewerModelFamily) {
    throw new Error("Vier-Augen verletzt: Prüf-KI muss andere Modellfamilie sein (ADR-07)");
  }
}

// Einmal-Token-Speicher (Skeleton: In-Memory; Prod: DB-Zustandsautomat mit atomarem Consume).
const consumedTokens = new Set<string>();
export function consumeApprovalToken(token: string | undefined): void {
  if (!token) throw new Error("Kein Freigabe-Token vorhanden");
  if (consumedTokens.has(token)) throw new Error("Freigabe-Token bereits eingelöst (Replay)");
  consumedTokens.add(token);
}

/** Verbindliche Ausführung nur mit fremd-geprüfter, menschlich freigegebener, einmaliger Freigabe. */
export function assertExecutable(t: Task): void {
  if (!t.binding) return; // Trivial-Routine unter stehender Klasse-Freigabe (B09-1)
  assertIndependentReviewer(t);                       // Reviewer-Check (Codex #7: fehlte)
  if (t.state !== "approved") {
    throw new Error("Keine verbindliche Ausführung ohne Zustand 'approved' (ADR-07)");
  }
  if (!t.approvedBy || t.approvedBy === t.requestedBy) {
    throw new Error("Vier-Augen verletzt: Antragsteller != Freigeber (SoD, K27)");
  }
  consumeApprovalToken(t.approvalToken);              // atomarer Einmal-Consume
}
