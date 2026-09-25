#!/usr/bin/env node
// VV — erzeugt die DB-Migration für das pg-boss-Schema aus pg-boss' eigenen Installationsplänen.
//
// Warum (Befund beim Dependabot-Update, Register P57): pg-boss führt beim Start
// `CREATE SCHEMA IF NOT EXISTS pgboss` aus. PostgreSQL verlangt dafür das CREATE-Recht auf der
// DATENBANK — auch wenn das Schema bereits existiert. `vv_worker` hat dieses Recht bewusst nicht
// (Least Privilege, Stage 0 F2/F3). Folge: der Worker startete gegen die gehärtete DB nie.
// Lösung: Schema-Installation als reguläre, prüfbare Migration (Eigentümer vv_worker); der Worker
// läuft mit `migrate: false` und prüft nur noch die Schema-Version (fail-closed bei Abweichung).
//
// Aufruf (aus dem Repo-Root, nach `npm ci` in apps/worker):
//   node scripts/gen_pgboss_schema.mjs > db/migrations/0012_pgboss_schema.sql
// Bei einem pg-boss-Update mit neuer Schema-Version: NEUE Migration mit getMigrationPlans()
// erzeugen (nie eine bestehende Migration umschreiben) — der CI-Worker-Start schlägt sonst fehl.
import { createRequire } from "node:module";
import { pathToFileURL } from "node:url";
import path from "node:path";

const workerDir = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..", "apps", "worker");
const req = createRequire(path.join(workerDir, "package.json"));
const pkgJson = req("pg-boss/package.json");
const mod = await import(pathToFileURL(req.resolve("pg-boss")).href);

const SCHEMA = "pgboss";
const TAG = "$vvpgbossplan$";
let plan = mod.getConstructionPlans(SCHEMA);
if (plan.includes(TAG)) throw new Error("Dollar-Quote-Tag kollidiert mit dem pg-boss-Plan");
// Schema existiert bereits (0001_extensions.sql, AUTHORIZATION vv_worker); CREATE SCHEMA würde das
// Datenbank-CREATE-Recht verlangen -> entfernen. Alles andere bleibt unverändert (pg-boss-Original).
const lines = plan.split("\n");
const filtered = lines.filter((l) => !/^\s*CREATE SCHEMA IF NOT EXISTS\s+pgboss\s*;?\s*$/i.test(l));
if (lines.length - filtered.length !== 1) throw new Error("CREATE SCHEMA-Zeile nicht genau einmal gefunden");
// Der Plan ist in BEGIN; … COMMIT; gekapselt — im DO-Block läuft er ohnehin in EINER Transaktion
// (EXECUTE erlaubt keine Transaktionsbefehle) -> genau diese zwei Zeilen entfernen.
const tx = filtered.filter((l) => /^\s*(BEGIN|COMMIT);\s*$/.test(l));
if (tx.length !== 2) throw new Error(`erwartet genau BEGIN;/COMMIT;, gefunden: ${tx.length}`);
plan = filtered.filter((l) => !/^\s*(BEGIN|COMMIT);\s*$/.test(l)).join("\n");
const version = (plan.match(/INSERT INTO pgboss\.version\(version\) VALUES \('(\d+)'\)/) || [])[1];
if (!version) throw new Error("Schema-Version im Plan nicht gefunden");

process.stdout.write(`-- =============================================================================================
-- VV — pg-boss-Schema (ADR-06) als reguläre Migration. GENERIERT durch scripts/gen_pgboss_schema.mjs
-- aus pg-boss ${pkgJson.version} (Schema-Version ${version}) — nicht von Hand ändern.
-- Eigentümer vv_worker (SET ROLE); KEIN Datenbank-CREATE-Recht nötig (Register P57).
-- Idempotent: nur wenn pgboss.version noch nicht existiert. Der Worker startet mit migrate:false
-- und prüft die Version (Abweichung = Startfehler, fail-closed).
-- Tabellen in Schema pgboss sind Fremd-Infrastruktur (pg-boss), keine Fachdaten, kein tenant_id.
-- =============================================================================================
SET ROLE vv_worker;
DO ${TAG.replace(/\$$/, "_outer$")}
BEGIN
  IF to_regclass('pgboss.version') IS NULL THEN
    EXECUTE ${TAG}
${plan}
${TAG};
  END IF;
END ${TAG.replace(/\$$/, "_outer$")};
RESET ROLE;
`);
