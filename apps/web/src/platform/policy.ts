// VV Platform — Zentraler Policy-Prüfpunkt (ADR-04, BASIS-02), WP3-gehärtet.
// Review-Befund Codex #5 / Gemini C: der Stub startete mit `allowed:true` (fail-open).
// Jetzt strikt DENY-BY-DEFAULT: ohne explizite Allow-Regel wird verweigert.
// Die vollständige RBAC-Matrix (Q03/B02-1) wird beim Modul-Bau als Daten in Postgres aufgelöst;
// dieses Skeleton trägt nur eine kleine explizite Allowlist für die Fundament-Demo-Aktionen.

export type Action =
  | "read" | "create" | "update" | "deactivate" | "export" | "approve";

export interface PolicyRequest {
  tenantId: string;
  actor: string;
  resource: string;
  action: Action;
  scopeNode: string;
  dataClass?: "Oe" | "S" | "Se" | "F-Buch" | "F-Bank" | "A9";
}

export interface PolicyDecision {
  allowed: boolean;
  reason: string;
  requiresApproval: boolean;   // Bindendes -> Freigabe-Objekt (Vier-Augen)
}

const BINDING: Action[] = ["approve"];

// Explizite Allowlist (deny-by-default): NUR was hier steht, ist erlaubt.
const ALLOW: Record<string, Action[]> = {
  person: ["read"],
  role_assignment: ["read"],
};

export function checkPolicy(req: PolicyRequest): PolicyDecision {
  const requiresApproval = BINDING.includes(req.action);
  // Ohne aktiven Mandanten/Actor: verweigern.
  if (!req.tenantId || !req.actor || !req.scopeNode) {
    return { allowed: false, reason: "deny-by-default: fehlender Tenant/Actor/Scope", requiresApproval };
  }
  const allowed = (ALLOW[req.resource] ?? []).includes(req.action);
  return {
    allowed,
    reason: allowed
      ? "stage0-explicit-allow"
      : "deny-by-default: keine explizite Allow-Regel (RBAC-Matrix folgt beim Modul-Bau)",
    requiresApproval,
  };
}
