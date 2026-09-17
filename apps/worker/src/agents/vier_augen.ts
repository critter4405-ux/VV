// VV Agenten — Vier-Augen-Zustandsautomat (ADR-07, BASIS-09).
// Fach-Agent -> unabhängiger Prüf-Agent (andere Modellfamilie) -> Freigabe-Objekt ->
// Mensch bestätigt -> Ausführung -> Audit. Ohne gültiges Freigabe-Token KEINE
// verbindliche Ausführung. Stage-0: Zustände + Guard; Modelle folgen beim Agenten-Bau.

export type FourEyesState =
  | "drafted"        // Fach-Agent hat entworfen (mit Belegen)
  | "reviewed"       // Prüf-Agent hat geprüft (Veto möglich)
  | "awaiting_human" // Freigabe-Objekt liegt dem Menschen vor
  | "approved"       // Mensch hat freigegeben (Antragsteller != Freigeber)
  | "executed"
  | "escalated";     // Veto/Unklarheit/Fehler -> Eskalation

export interface Task {
  state: FourEyesState;
  builderModelFamily: string;
  reviewerModelFamily: string;
  requestedBy: string;
  approvedBy?: string;
  binding: boolean; // Geld/Meldung/Löschung/Personendaten nach außen/rechtsverbindlich
}

/** Prüf-KI MUSS aus anderer Modellfamilie stammen (ADR-07). */
export function assertIndependentReviewer(t: Task): void {
  if (t.builderModelFamily === t.reviewerModelFamily) {
    throw new Error("Vier-Augen verletzt: Prüf-KI muss andere Modellfamilie sein (ADR-07)");
  }
}

/** Verbindliche Ausführung nur mit gültiger, fremd-erteilter Freigabe (SoD). */
export function assertExecutable(t: Task): void {
  if (!t.binding) return; // Trivial-Routine unter stehender Klasse-Freigabe (B09-1)
  if (t.state !== "approved") {
    throw new Error("Keine verbindliche Ausführung ohne Freigabe-Objekt (ADR-07/BASIS-09)");
  }
  if (!t.approvedBy || t.approvedBy === t.requestedBy) {
    throw new Error("Vier-Augen verletzt: Antragsteller != Freigeber (SoD, K27)");
  }
}
