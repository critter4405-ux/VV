#!/usr/bin/env bash
# VV — Sicherheits-DB-Gegenproben (CI, gate-blockierend). Läuft gegen eine bereits migrierte
# PostgreSQL mit gesetzten Rollen-Passwörtern (-h $VV_PGHOST, Default localhost; Passwort $PW).
# Jede Gegenprobe hält eine über die Review-Runden hart erarbeitete Invariante als DAUERHAFTEN
# Regressionsschutz fest. Kein eval -> robustes Quoting.
set -uo pipefail
HOST="${VV_PGHOST:-localhost}"; PW="${PW:-change_me_dev_only}"
AA="00000000-0000-0000-0000-0000000000aa"; BB="00000000-0000-0000-0000-0000000000bb"
FAIL=0
q(){ PGPASSWORD="$PW" psql -tA -h "$HOST" -U "$1" -d vv; }
pass(){ echo "  [OK]  $1"; }
fail(){ echo "  [FAIL] $1"; FAIL=1; }
# ck NAME COND(0/1)
ck(){ if [ "$2" = 0 ]; then pass "$1"; else fail "$1"; fi; }

echo "== Sicherheits-Gegenproben =="

# ADR-01 RLS
N0=$(q vv_app <<<"SELECT count(*) FROM person" | grep -E '^[0-9]+$' | head -1)
NA=$(q vv_app <<<"BEGIN; SELECT set_config('app.tenant_id','$AA',true); SELECT count(*) FROM person; COMMIT;" | grep -E '^[0-9]+$' | head -1)
NBv=$(q vv_app <<<"BEGIN; SELECT set_config('app.tenant_id','$BB',true); SELECT count(*) FROM person; COMMIT;" | grep -E '^[0-9]+$' | head -1)
[ "$N0" = 0 ] && [ "$NA" != 0 ] && [ "$NBv" != 0 ] && [ "$NA" != "$NBv" ]; ck "RLS: ohne Kontext 0, Mandanten isoliert (0/$NA/$NBv)" $?

# Rollen NOSUPERUSER/NOBYPASSRLS
RA=$(q vv_bootstrap <<<"SELECT rolsuper::text||rolbypassrls::text FROM pg_roles WHERE rolname='vv_app'")
RW=$(q vv_bootstrap <<<"SELECT rolsuper::text||rolbypassrls::text FROM pg_roles WHERE rolname='vv_worker'")
[ "$RA" = falsefalse ] && [ "$RW" = falsefalse ]; ck "vv_app/vv_worker NOSUPERUSER+NOBYPASSRLS" $?

# G4: Outbox nicht direkt unterdrückbar
O=$(q vv_app <<<"UPDATE outbox SET processed_at=now()" 2>&1); echo "$O" | grep -qi "permission denied"; ck "vv_app UPDATE outbox denied" $?
O=$(q vv_app <<<"DELETE FROM outbox" 2>&1); echo "$O" | grep -qi "permission denied"; ck "vv_app DELETE outbox denied" $?
O=$(q vv_app <<<"SELECT vv_outbox_claim(1)" 2>&1); echo "$O" | grep -qi "permission denied"; ck "vv_app EXECUTE vv_outbox_claim denied" $?

# H1: approved_by-Bindung
q vv_app >/dev/null 2>&1 <<SQL
BEGIN; SELECT set_config('app.tenant_id','$AA',true);
INSERT INTO approval(tenant_id,kind,effect_id,subject_ref,requested_by,builder_model) VALUES ('$AA','deletion','person.delete','ci1','agent-1','claude'); COMMIT;
SQL
O=$(q vv_app <<<"BEGIN; SELECT set_config('app.tenant_id','$AA',true); UPDATE approval SET approved_by='x',status='approved' WHERE subject_ref='ci1'; COMMIT;" 2>&1); echo "$O" | grep -qi "permission denied"; ck "H1: vv_app UPDATE approval.approved_by denied" $?
O=$(q vv_app <<<"SELECT vv_consume_approval('person.delete','ci1')" 2>&1); echo "$O" | grep -qi "permission denied"; ck "H1: vv_app EXECUTE vv_consume_approval denied" $?
AID=$(q vv_app <<<"BEGIN; SELECT set_config('app.tenant_id','$AA',true); SELECT id FROM approval WHERE subject_ref='ci1'; COMMIT;" | grep -iE '^[0-9a-f-]{36}$' | grep -vi "0000000000aa" | head -1)
O=$(q vv_app <<<"BEGIN; SELECT set_config('app.tenant_id','$AA',true); SELECT set_config('app.actor','agent-1',true); SELECT vv_decide_approval('$AID','approved'); COMMIT;" 2>&1); echo "$O" | grep -qi "nicht selbst freigeben"; ck "H1: Selbst-Freigabe (actor=requester) abgewiesen (SoD)" $?
q vv_app >/dev/null 2>&1 <<SQL
BEGIN; SELECT set_config('app.tenant_id','$AA',true); SELECT set_config('app.actor','human-2',true);
SELECT vv_decide_approval('$AID','approved','gpt'); COMMIT;
SQL
AB=$(q vv_app <<<"BEGIN; SELECT set_config('app.tenant_id','$AA',true); SELECT status||'/'||approved_by FROM approval WHERE id='$AID'; COMMIT;" | grep -i approved/ | head -1)
[ "$AB" = approved/human-2 ]; ck "H1: Freigeber = app.actor (DB-seitig)" $?
C1=$(q vv_worker <<<"BEGIN; SELECT set_config('app.tenant_id','$AA',true); SELECT (vv_consume_approval('person.delete','ci1') IS NOT NULL); COMMIT;" | grep -iE '^(t|f)$' | head -1)
C2=$(q vv_worker <<<"BEGIN; SELECT set_config('app.tenant_id','$AA',true); SELECT (vv_consume_approval('person.delete','ci1') IS NOT NULL); COMMIT;" | grep -iE '^(t|f)$' | head -1)
[ "$C1" = t ] && [ "$C2" = f ]; ck "H1: Consume einmal, Replay ROT ($C1/$C2)" $?

# Audit append-only inkl. TRUNCATE
O=$(q vv_bootstrap <<<"TRUNCATE audit_log" 2>&1); echo "$O" | grep -qi "append-only"; ck "Audit: TRUNCATE für Eigentümer blockiert" $?

# H2/H3: Hard-Crash-DLQ + in-flight bleibt am Leben
q vv_app >/dev/null 2>&1 <<<"BEGIN; SELECT set_config('app.tenant_id','$AA',true); INSERT INTO outbox(tenant_id,topic,payload,idempotency_key) VALUES ('$AA','hc','{}','cihc'); COMMIT;"
for i in 1 2 3 4 5 6; do
  q vv_worker >/dev/null 2>&1 <<<"BEGIN; SELECT set_config('app.tenant_id','$AA',true); SELECT count(*) FROM vv_outbox_claim(5); COMMIT;"
  q vv_bootstrap >/dev/null 2>&1 <<<"UPDATE outbox SET locked_until=NULL WHERE idempotency_key='cihc' AND processed_at IS NULL AND dead_at IS NULL;"
done
HC=$(q vv_bootstrap <<<"SELECT attempts||'/'||(dead_at IS NOT NULL)::text FROM outbox WHERE idempotency_key='cihc'")
[[ "$HC" == 5/t* ]]; ck "H2/H3: Hard-Crash-Giftelement in DLQ ($HC)" $?
q vv_app >/dev/null 2>&1 <<<"BEGIN; SELECT set_config('app.tenant_id','$AA',true); INSERT INTO outbox(tenant_id,topic,payload,idempotency_key) VALUES ('$AA','if','{}','ciif'); COMMIT;"
for i in 1 2 3 4; do
  q vv_worker >/dev/null 2>&1 <<<"BEGIN; SELECT set_config('app.tenant_id','$AA',true); SELECT count(*) FROM vv_outbox_claim(5); COMMIT;"
  q vv_bootstrap >/dev/null 2>&1 <<<"UPDATE outbox SET locked_until=NULL WHERE idempotency_key='ciif';"
done
q vv_worker >/dev/null 2>&1 <<<"BEGIN; SELECT set_config('app.tenant_id','$AA',true); SELECT count(*) FROM vv_outbox_claim(5); COMMIT;"
q vv_worker >/dev/null 2>&1 <<<"BEGIN; SELECT set_config('app.tenant_id','$AA',true); SELECT count(*) FROM vv_outbox_claim(5); COMMIT;"
DEAD=$(q vv_bootstrap <<<"SELECT (dead_at IS NOT NULL)::text FROM outbox WHERE idempotency_key='ciif'")
[ "$DEAD" = false ]; ck "H3: in-flight 5. Versuch NICHT fälschlich getötet" $?

echo "----"
[ "$FAIL" = 0 ] && echo "Alle Sicherheits-Gegenproben grün." || { echo "SICHERHEITS-GEGENPROBE FEHLGESCHLAGEN"; exit 1; }
