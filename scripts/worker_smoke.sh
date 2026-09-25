#!/usr/bin/env bash
# VV — Worker-Start-Probe (gate-blockierend, Register P57; schließt einen Teil von H-13).
# Startet den ECHTEN Worker (pg-boss + Outbox-Consumer) gegen eine frisch migrierte DB mit der
# Least-Privilege-Rolle vv_worker und prüft: Start ohne Fehler, Queues + Tageszeitplan angelegt,
# pgboss-Schema gehört vv_worker, und vv_worker hat KEIN Datenbank-CREATE-Recht (bleibt so).
# Bisher liefen nur Funktions-Tests — der reale Start scheiterte unbemerkt an CREATE SCHEMA (P57).
#
#   VV_PGHOST=localhost PW=change_me_dev_only bash scripts/worker_smoke.sh
#   (vorher: Migrationen + Seeds eingespielt, `npm ci` in apps/worker)
set -uo pipefail
HOST="${VV_PGHOST:-localhost}"; PW="${PW:-change_me_dev_only}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG="$(mktemp)"; FAIL=0
ok(){ echo "  [OK]  $1"; }; no(){ echo "  [FAIL] $1"; FAIL=1; }
q(){ PGPASSWORD="$PW" psql -tA -h "$HOST" -U vv_bootstrap -d vv -c "$1"; }

echo "== Worker-Start-Probe =="
[ "$(q "SELECT has_database_privilege('vv_worker', current_database(), 'CREATE')")" = f ] \
  && ok "vv_worker ohne Datenbank-CREATE-Recht (Least Privilege)" || no "vv_worker hat Datenbank-CREATE-Recht"
( cd "$ROOT/apps/worker" && \
  WORKER_DATABASE_URL="postgres://vv_worker:$PW@$HOST:5432/vv" DATABASE_URL="postgres://vv_worker:$PW@$HOST:5432/vv" \
  timeout 20 npx tsx src/index.ts ) > "$LOG" 2>&1
RC=$?
grep -q "bereit" "$LOG" && ! grep -q "Startfehler" "$LOG" && [ "$RC" = 124 ] \
  && ok "Worker startet und läuft (Abbruch nach 20 s gewollt)" || { no "Worker-Start (rc=$RC)"; sed -n 1,30p "$LOG"; }
[ "$(q "SELECT count(*) FROM pgboss.queue WHERE name IN ('m05.daily','reminder.dispatch')")" = 2 ] \
  && ok "Queues m05.daily + reminder.dispatch angelegt" || no "Queues fehlen"
[ "$(q "SELECT cron||'|'||timezone FROM pgboss.schedule WHERE name='m05.daily'")" = "15 2 * * *|Europe/Vienna" ] \
  && ok "Tageszeitplan m05.daily 02:15 Europe/Vienna" || no "Tageszeitplan fehlt/falsch"
[ "$(q "SELECT string_agg(DISTINCT tableowner, ',') FROM pg_tables WHERE schemaname='pgboss'")" = vv_worker ] \
  && ok "pgboss-Tabellen gehören vv_worker" || no "pgboss-Eigentümer falsch"
rm -f "$LOG"
[ "$FAIL" = 0 ] && echo "Worker-Start-Probe grün." || { echo "WORKER-START-PROBE FEHLGESCHLAGEN"; exit 1; }
