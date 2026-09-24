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

// ---------------------------------------------------------------------------------------------
// M05-Reparaturrunde R2 (B-03): Der Handler einer bindenden Senke wird NICHT mehr vom Aufrufer
// übergeben (vorher: executeBindingEffect(id, ctx, store, handler) -> `("reminder.dispatch", …,
// () => pay())` lief ohne Freigabe). Jetzt:
//  - Handler sind in einer beim Start EINGEFRORENEN Registry fest an die Effekt-ID gebunden
//    (createExecutor prüft: nur bindende Effekte mit execution="handler", keine Duplikate).
//  - Der Executor nimmt nur (effectId, ctx, store): nicht-bindende IDs, DB-atomare Effekte
//    (M05: nur m05_execute in der DB) und Effekte ohne registrierten Handler sind NICHT ausführbar.
//  - Erst atomarer DB-Consume der Freigabe, dann der fest registrierte Handler.
// ---------------------------------------------------------------------------------------------
export type BindingHandler = (ctx: ExecContext) => Promise<unknown>;

export interface BindingExecutor {
  /** Führt die fest registrierte Senke des bindenden Effekts aus — nur mit eingelöster Freigabe. */
  execute(effectId: string, ctx: ExecContext, store: ApprovalStore): Promise<unknown>;
  readonly effects: readonly string[];
}

export function createExecutor(handlers: Readonly<Record<string, BindingHandler>>): BindingExecutor {
  const table = new Map<string, BindingHandler>();
  for (const [effectId, fn] of Object.entries(handlers)) {
    const def = getEffect(effectId);
    if (!def) throw new Error(`Handler für unbekannten Effekt '${effectId}' (fail-closed)`);
    if (!def.binding || def.execution !== "handler") {
      throw new Error(`Effekt '${effectId}' ist nicht als bindende Handler-Senke klassifiziert (${def.execution})`);
    }
    if (typeof fn !== "function") throw new Error(`Handler für '${effectId}' ist keine Funktion`);
    table.set(effectId, fn);
  }
  Object.freeze(table);
  return Object.freeze({
    effects: Object.freeze([...table.keys()]),
    async execute(effectId: string, ctx: ExecContext, store: ApprovalStore): Promise<unknown> {
      const def = getEffect(effectId);
      if (!def) throw new Error(`Unbekannter Effekt '${effectId}' (fail-closed) — nicht ausführbar`);
      if (!def.binding) {
        throw new Error(`Effekt '${effectId}' ist nicht bindend — über den Vier-Augen-Executor nicht ausführbar`);
      }
      if (def.execution === "db-atomic") {
        throw new Error(`Effekt '${effectId}' ist nur DB-atomar ausführbar (Freigabe + Wirkung in einer Transaktion)`);
      }
      const handler = table.get(effectId);
      if (!handler) throw new Error(`Kein fest registrierter Handler für '${effectId}' (fail-closed)`);
      await assertExecutable(effectId, ctx, store);   // atomarer Einmal-Consume (wirft sonst)
      return handler(ctx);
    },
  });
}

/** Produktions-Registry: in Stage 0 / M05 gibt es noch KEINE TS-Handler-Senke (M05 läuft DB-atomar).
 *  Neue Senken werden hier (Code, Review) registriert — nie zur Laufzeit vom Aufrufer. */
export const PRODUCTION_EXECUTOR: BindingExecutor = createExecutor({});

/** DER EINZIGE Pfad zu einer bindenden TS-Senke (kein Handler-Parameter). */
export async function executeBindingEffect(effectId: string, ctx: ExecContext, store: ApprovalStore): Promise<unknown> {
  return PRODUCTION_EXECUTOR.execute(effectId, ctx, store);
}
