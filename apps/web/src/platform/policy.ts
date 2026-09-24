// VV Platform — Zentraler Policy-Prüfpunkt (ADR-04, BASIS-02).
// Stage 0: statische Allowlist (deny-by-default). M05-Bau (Register P50-8): DATENGETRIEBEN aus
// Postgres — Rollen × Scope × Datenklasse (role_assignment/role_permission, vv_policy_any).
//
// Zwei Linien (Defense-in-Depth):
//  1. HIER (App): grobe Vorprüfung „hält der verifizierte Actor dieses Recht überhaupt?" —
//     jede Aktion muss durch diesen Punkt (validator-erzwungen, ADR-09).
//  2. In der DB-Fachfunktion: feingranulare Prüfung am Objekt (Scope der Ziel-Person, Feldsicht),
//     mit demselben transaktionsgebundenen app.actor. Selbst ein App-Fehler öffnet also nichts.
// Fail-closed: fehlender Kontext, unbekannte Ressource oder DB-Fehler => verweigert.
import type { Pool } from "pg";
import { pool as defaultPool } from "../db.ts";
import { withTenant } from "./tenant.ts";
import { writeAudit } from "./audit.ts";

export type Action =
  | "read" | "create" | "update" | "deactivate" | "export" | "approve";

export type DataClass = "Oe" | "S" | "Se" | "F-Buch" | "F-Bank" | "A9";

export interface PolicyRequest {
  tenantId: string;
  actor: string;
  resource: string;
  action: Action;
  scopeNode: string;
  dataClass?: DataClass;
}

export interface PolicyDecision {
  allowed: boolean;
  reason: string;
  requiresApproval: boolean;   // Bindendes -> Freigabe-Objekt (Vier-Augen)
}

const BINDING: Action[] = ["approve"];
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// Nur bekannte Ressourcen sind überhaupt prüfbar (Tippfehler => deny, nicht „zufällig erlaubt").
export const KNOWN_RESOURCES: ReadonlySet<string> = new Set([
  "person", "role_assignment", "scope_node", "membership", "membership_type",
]);

export interface PolicyDeps { pool: Pick<Pool, "connect"> }

export async function checkPolicy(req: PolicyRequest, deps: PolicyDeps = { pool: defaultPool }): Promise<PolicyDecision> {
  const requiresApproval = BINDING.includes(req.action);
  if (!req.tenantId || !req.actor || !req.scopeNode) {
    return { allowed: false, reason: "deny-by-default: fehlender Tenant/Actor/Scope", requiresApproval };
  }
  if (req.actor.startsWith("system:")) {
    return { allowed: false, reason: "deny-by-default: Systemakteure handeln nicht über die Web-API", requiresApproval };
  }
  if (!KNOWN_RESOURCES.has(req.resource)) {
    return { allowed: false, reason: `deny-by-default: unbekannte Ressource '${req.resource}'`, requiresApproval };
  }
  const dataClass: DataClass = req.dataClass ?? "Oe";
  // M05-Reparaturrunde 1 (R7/H-05): scopeNode hat Bedeutung (vorher nur „nicht leer").
  //   "verein" -> Recht an der Vereins-WURZEL nötig (Aktion liest/wirkt vereinsweit)
  //   <uuid>   -> Recht an diesem Scope-Knoten (bzw. einem Vorfahren) nötig
  //   "any"    -> Recht irgendwo genügt — NUR für Aktionen, deren DB-Funktion je Objekt mit den
  //               Scopes der Zielperson erneut prüft (alle M05-Fachfunktionen)
  //   sonst    -> deny
  let sql: string;
  let params: unknown[];
  if (req.scopeNode === "any") {
    sql = "SELECT vv_policy_any($1, $2, $3) AS allowed"; params = [req.resource, req.action, dataClass];
  } else if (req.scopeNode === "verein") {
    sql = "SELECT vv_authorize($1, $2, $3, NULL, NULL) AS allowed"; params = [req.resource, req.action, dataClass];
  } else if (UUID.test(req.scopeNode)) {
    sql = "SELECT vv_authorize($1, $2, $3, ARRAY[$4::uuid], NULL) AS allowed";
    params = [req.resource, req.action, dataClass, req.scopeNode];
  } else {
    return { allowed: false, reason: `deny-by-default: unbekannter Scope '${req.scopeNode}'`, requiresApproval };
  }
  try {
    const client = await deps.pool.connect();
    try {
      const allowed = await withTenant(client, req.tenantId, async () => {
        const { rows } = await client.query(sql, params);
        const ok = rows[0]?.allowed === true;
        if (!ok) {
          // Auch Verweigerungen werden protokolliert (ADR-04: jede Entscheidung ins Audit).
          await writeAudit(client, {
            action: "policy.deny", subjectRef: `${req.resource}.${req.action}`, payload: { dataClass, scope: req.scopeNode },
          });
        }
        return ok;
      }, req.actor);
      return {
        allowed,
        reason: allowed ? "rbac: Recht vorhanden (Objektprüfung folgt in der DB)"
                        : "deny-by-default: keine passende Rolle × Scope × Datenklasse",
        requiresApproval,
      };
    } finally {
      client.release();
    }
  } catch {
    return { allowed: false, reason: "deny-by-default: Policy-Prüfung fehlgeschlagen (fail-closed)", requiresApproval };
  }
}
