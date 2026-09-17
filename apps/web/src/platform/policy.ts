// VV Platform — Zentraler Policy-Prüfpunkt (ADR-04, BASIS-02).
// INVARIANTE (validator-erzwungen, ADR-09): KEINE Aktion umgeht diesen Prüfpunkt.
// deny-by-default. Jede *.action.ts MUSS checkPolicy() aufrufen.

export type Action =
  | "read" | "create" | "update" | "deactivate" | "export" | "approve";

export interface PolicyRequest {
  tenantId: string;          // aktiver Mandant (RLS-Kontext, ADR-01)
  actor: string;             // Referenz, kein Klartext-Personenbezug
  resource: string;          // z.B. "person", "role_assignment"
  action: Action;
  scopeNode: string;         // Verein/Abteilung/Mannschaft (vererbender Baum)
  dataClass?: "Oe" | "S" | "Se" | "F-Buch" | "F-Bank" | "A9";
}

export interface PolicyDecision {
  allowed: boolean;
  reason: string;
  requiresApproval: boolean;  // Bindendes -> Freigabe-Objekt (Vier-Augen)
}

// Bindende Aktionen erzeugen nie eine direkte Wirkung, sondern ein Freigabe-Objekt.
const BINDING: Action[] = ["approve"]; // Geld/Meldung/Löschung laufen über approve/Freigabe

/**
 * Einziger Autorisierungs-Eintrittspunkt. Im Stage-0-Skeleton deny-by-default
 * mit expliziter Allowlist-Struktur; die echte RBAC-Matrix (Q03/B02-1) wird
 * beim Modul-Bau als Daten in Postgres aufgelöst.
 */
export function checkPolicy(req: PolicyRequest): PolicyDecision {
  // deny-by-default: ohne aktiven Tenant-Kontext niemals erlauben.
  if (!req.tenantId || !req.actor) {
    return { allowed: false, reason: "no-tenant-or-actor", requiresApproval: false };
  }
  const requiresApproval = BINDING.includes(req.action);
  return {
    allowed: true,
    reason: "stage0-skeleton-allow (RBAC-Matrix folgt beim Modul-Bau)",
    requiresApproval,
  };
}
