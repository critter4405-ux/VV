// VV Agenten — Vier-Augen-Ausführungsschutz (ADR-07, BASIS-09).
// Review-Runde 3, Codex #1 (CRITICAL): zuvor waren Verbindlichkeit, Zustand, Freigeber und Token
// frei gelieferte Aufrufer-Daten -> eine Zahlung ließ sich als „reminder" etikettieren, ein
// „approved"-Zustand erfinden, ein In-Memory-Token nach Neustart wiederverwenden.
//
// Jetzt strukturell erzwungen:
//  1. Der Aufrufer wählt eine EFFEKT-ID (effects.ts) — die Verbindlichkeit kommt aus der fixen
//     Registry, nicht aus einem Aufrufer-Feld. Eine bindende Senke ist nur über ihren eigenen
//     Effekt erreichbar (kein Umetikettieren).
//  2. Bindende Effekte laufen NUR über `executeBindingEffect(...)`; dieser Executor löst vor dem
//     Handler eine echte Freigabe atomar aus der DB ein (ApprovalStore -> vv_consume_approval):
//     fremd-genehmigt, scope-gebunden, ablaufend, genau einmal, replay-fest über Neustarts.
//  3. Reviewer-Unabhängigkeit (andere Modellfamilie) + Antragsteller≠Freigeber werden in der DB
//     (CHECK-Constraints + Consume-Prädikat) erzwungen, nicht im App-Code behauptet.

import { getEffect, STANDING_CLASS_APPROVED } from "./effects.ts";
import type { ApprovalStore } from "./approval_store.ts";

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

export function assertTransition(from: FourEyesState, to: FourEyesState): void {
  if (!ALLOWED[from].includes(to)) {
    throw new Error(`Unerlaubter Vier-Augen-Übergang: ${from} -> ${to}`);
  }
}

export interface ExecContext {
  tenantId: string;      // aus verifizierten OIDC-Claims (nie roh aus dem Request)
  subjectRef: string;    // worauf sich die Aktion bezieht (ID/Pseudonym)
  requestedBy: string;
}

/**
 * Prüft, ob ein Effekt ausgeführt werden darf. Bindend -> echte DB-Freigabe atomar einlösen;
 * nicht-bindend -> nur registrierte stehende Klasse-Freigabe (fail-closed). Ein unbekannter
 * Effekt wird immer abgewiesen. Kein Aufrufer-Zustand geht ein.
 */
export async function assertExecutable(
  effectId: string, ctx: ExecContext, store: ApprovalStore,
): Promise<void> {
  const def = getEffect(effectId);
  if (!def) {
    throw new Error(`Unbekannter Effekt '${effectId}' (fail-closed) — nicht ausführbar`);
  }
  if (!def.binding) {
    if (!STANDING_CLASS_APPROVED.has(effectId)) {
      throw new Error(
        `Keine stehende Klasse-Freigabe für '${effectId}' (fail-closed) — Einzel-Freigabe nötig`);
    }
    return;
  }
  if (!ctx.tenantId) throw new Error("assertExecutable: leerer tenantId (deny-by-default)");
  // bindend: echte, fremd-genehmigte, einmalige DB-Freigabe atomar einlösen (wirft sonst).
  await store.consume(ctx.tenantId, effectId, ctx.subjectRef);
}

/**
 * DER EINZIGE Pfad zu einer bindenden Senke. Erst Freigabe atomar einlösen, dann Handler.
 * So kann kein Aufrufer den Handler unter Umgehung des Vier-Augen-Gates erreichen.
 */
export async function executeBindingEffect<T>(
  effectId: string, ctx: ExecContext, store: ApprovalStore, handler: () => Promise<T>,
): Promise<T> {
  await assertExecutable(effectId, ctx, store);
  return handler();
}
