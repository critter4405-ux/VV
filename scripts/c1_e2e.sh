#!/usr/bin/env bash
# VV — C-1 Ende-zu-Ende (gate-blockierend in CI): ECHTE Kette  Token -> Ticket-Dienst -> Web-App -> PostgreSQL 16.
# Startet einen Test-OIDC-Aussteller (nur hier), den echten Ticket-Dienst und die echte Web-App (vv_app) und prüft:
#   gültiges Token -> Daten; Mandant/Akteur kommen aus dem Ticket (Audit); fremd signiertes Token -> 401;
#   ID-Token -> 401; Ticket-Dienst weg -> 503 ohne Datenzugriff (fail-closed); Dienst wieder da -> 200.
#   Voraussetzung: migrierte DB + Seeds, Keyring (VV_TICKET_KEYRING), npm ci in apps/web + apps/ticket.
set -uo pipefail
HOST="${VV_PGHOST:-localhost}"; PW="${PW:-change_me_dev_only}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
: "${VV_TICKET_KEYRING:?VV_TICKET_KEYRING fehlt}"
AA="00000000-0000-0000-0000-0000000000aa"; BB="00000000-0000-0000-0000-0000000000bb"
FAIL=0; PIDS=()
ok(){ echo "  [OK]  $1"; }; no(){ echo "  [FAIL] $1"; FAIL=1; }
cleanup(){ for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null; done; }
trap cleanup EXIT
waitport(){ for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$1$2" && return 0; sleep 0.2; done; return 1; }

echo "== C-1 Ende-zu-Ende (Token -> Ticket-Dienst -> Web -> DB) =="
( cd "$ROOT/apps/ticket" && FAKE_OIDC_PORT=18080 exec node --import tsx test-support/fake_oidc.ts ) >/tmp/c1_oidc.log 2>&1 & PIDS+=($!)
waitport 18080 /realms/vv/protocol/openid-connect/certs || { echo "fake-oidc startet nicht"; cat /tmp/c1_oidc.log; exit 1; }
start_ticket(){ ( cd "$ROOT/apps/ticket" && OIDC_ISSUER=http://127.0.0.1:18080/realms/vv OIDC_AUDIENCE=vv-web \
  TICKET_KEYRING_FILE="$VV_TICKET_KEYRING" PORT=18081 TICKET_BIND=127.0.0.1 exec node --import tsx src/index.ts ) >>/tmp/c1_ticket.log 2>&1 &
  TICKET_PID=$!; PIDS+=($TICKET_PID); waitport 18081 /health; }
start_ticket || { echo "Ticket-Dienst startet nicht"; cat /tmp/c1_ticket.log; exit 1; }
( cd "$ROOT/apps/web" && DATABASE_URL="postgres://vv_app:$PW@$HOST:5432/vv" OIDC_ISSUER=http://127.0.0.1:18080/realms/vv \
  OIDC_CLIENT_ID=vv-web TICKET_URL=http://127.0.0.1:18081 PORT=13000 exec node --import tsx src/index.ts ) >/tmp/c1_web.log 2>&1 & PIDS+=($!)
waitport 13000 /api/health || { echo "Web startet nicht"; cat /tmp/c1_web.log; exit 1; }

tok(){ curl -s "http://127.0.0.1:18080/mint?$1"; }
get(){ curl -s -o /tmp/c1_body.json -w '%{http_code}' -H "authorization: Bearer $1" "http://127.0.0.1:13000$2"; }
# Betreiber-Abfrage ohne psql-Abhängigkeit (pg aus apps/web; läuft auch im node:22-Prüfcontainer).
q(){ ( cd "$ROOT/apps/web" && VV_Q="$1" VV_DSN="postgres://vv_bootstrap:$PW@$HOST:5432/vv" node --input-type=module -e '
  import pg from "pg"; const c = new pg.Client({ connectionString: process.env.VV_DSN }); await c.connect();
  const r = await c.query({ text: process.env.VV_Q, rowMode: "array" }); await c.end();
  console.log(r.rows.map((x) => x.join("|")).join("\n"));' ); }

T_V=$(tok "sub=sub-vorstand-aa&tenant=$AA")
C=$(get "$T_V" /api/m05/members); [ "$C" = 200 ] && ok "gültiges Access-Token -> Ticket -> Daten (200)" || { no "Liste mit gültigem Token ($C)"; head -c 300 /tmp/c1_body.json; }
A=$(q "SELECT actor FROM audit_log WHERE tenant_id='$AA' AND action='m05.list' ORDER BY id DESC LIMIT 1")
[ "$A" = sub-vorstand-aa ] && ok "Akteur im Audit stammt aus dem Ticket ($A)" || no "Audit-Akteur ($A)"
C=$(get "$(tok "sub=sub-vorstand-aa&tenant=$BB")" /api/m05/members); [ "$C" = 403 ] && ok "Mandant B im Token -> keine Rechte des A-Nutzers (403)" || no "Mandantenwechsel ($C)"
C=$(get "$(tok "sub=sub-vorstand-aa&tenant=$AA&foreign=1")" /api/m05/members); [ "$C" = 401 ] && ok "fremd signiertes Token -> 401" || no "fremd signiert ($C)"
C=$(get "$(tok "sub=sub-vorstand-aa&tenant=$AA&typ=ID")" /api/m05/members); [ "$C" = 401 ] && ok "ID-Token statt Access-Token -> 401" || no "ID-Token ($C)"
C=$(get "$(tok "sub=sub-vorstand-aa&tenant=$AA&aud=vv-worker")" /api/m05/members); [ "$C" = 401 ] && ok "falsche Audience -> 401" || no "Audience ($C)"
N0=$(q "SELECT count(*) FROM audit_log WHERE tenant_id='$AA' AND action='m05.list'")
kill "$TICKET_PID"; wait "$TICKET_PID" 2>/dev/null; sleep 0.3
C=$(get "$T_V" /api/m05/members); R=$(cat /tmp/c1_body.json)
N1=$(q "SELECT count(*) FROM audit_log WHERE tenant_id='$AA' AND action='m05.list'")
[ "$C" = 503 ] && echo "$R" | grep -q "vorübergehend nicht verfügbar" && ok "Ticket-Dienst weg -> 503 'vorübergehend nicht verfügbar'" || no "fail-closed ($C ${R:0:120})"
[ "$N0" = "$N1" ] && ok "…und kein Datenzugriff (kein neuer Lese-Audit-Eintrag, kein Rückfall)" || no "Datenzugriff trotz Ausfall ($N0 -> $N1)"
start_ticket >/dev/null && C=$(get "$T_V" /api/m05/members) && [ "$C" = 200 ] && ok "Dienst wieder da (restart) -> 200, zustandslos" || no "Wiederanlauf ($C)"
grep -q "$T_V" /tmp/c1_ticket.log /tmp/c1_web.log && no "Token im Log gefunden" || ok "kein Token in den Dienst-Logs"
[ "$FAIL" = 0 ] && echo "C-1 Ende-zu-Ende grün." || { echo "C-1 ENDE-ZU-ENDE FEHLGESCHLAGEN"; tail -5 /tmp/c1_ticket.log /tmp/c1_web.log; exit 1; }
