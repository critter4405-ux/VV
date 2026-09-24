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
O=$(q vv_app <<<"SELECT vv_outbox_claim(1, ARRAY['hc'])" 2>&1); echo "$O" | grep -qi "permission denied"; ck "vv_app EXECUTE vv_outbox_claim denied" $?

# H1: approved_by-Bindung (seit Reparaturrunde 1 mit R3 Attestation + R4 Freigeber-Recht je Effekt)
# Antrag eines synthetischen Principals auf einen zugeordneten Effekt; builder = Modell -> Attestation nötig.
q vv_app >/dev/null 2>&1 <<SQL
BEGIN; SELECT set_config('app.tenant_id','$AA',true); SELECT set_config('app.actor','sub-schrift-aa',true);
INSERT INTO approval(tenant_id,kind,effect_id,subject_ref,requested_by,builder_model) VALUES ('$AA','external_pii','q05.import.commit','ci1','sub-schrift-aa','claude-opus-5.5'); COMMIT;
SQL
O=$(q vv_app <<<"BEGIN; SELECT set_config('app.tenant_id','$AA',true); UPDATE approval SET approved_by='x',status='approved' WHERE subject_ref='ci1'; COMMIT;" 2>&1); echo "$O" | grep -qi "permission denied"; ck "H1: vv_app UPDATE approval.approved_by denied" $?
O=$(q vv_app <<<"SELECT vv_consume_approval('q05.import.commit','ci1')" 2>&1); echo "$O" | grep -qi "permission denied"; ck "H1: vv_app EXECUTE vv_consume_approval denied" $?
AID=$(q vv_bootstrap <<<"SELECT id FROM approval WHERE subject_ref='ci1'" | grep -iE '^[0-9a-f-]{36}$' | head -1)
dec(){ q vv_app 2>&1 <<SQL
BEGIN; SELECT set_config('app.tenant_id','$AA',true); SELECT set_config('app.actor','$1',true);
SELECT vv_decide_approval('$AID','approved',$2); COMMIT;
SQL
}
O=$(dec sub-schrift-aa "'gpt-5.3-codex'"); echo "$O" | grep -qi "nicht selbst freigeben"; ck "H1: Selbst-Freigabe (actor=requester) abgewiesen (SoD)" $?
O=$(dec sub-trainer-aa "'gpt-5.3-codex'"); echo "$O" | grep -qi "kein Recht"; ck "R4: Actor ohne Freigeber-Recht (Trainer) abgewiesen" $?
O=$(dec human-unbekannt "'gpt-5.3-codex'"); echo "$O" | grep -qi "kein Recht"; ck "R4: unbekannter Actor (kein Principal) abgewiesen" $?
O=$(dec sub-vorstand-aa "NULL"); echo "$O" | grep -qi "Attestation"; ck "R3: Modell-Vorschlag ohne Reviewer-Attestation nicht freigebbar" $?
O=$(dec sub-vorstand-aa "'claude-sonnet-4'"); echo "$O" | grep -qi "Attestation"; ck "R3: Reviewer aus gleicher Modellfamilie abgewiesen" $?
O=$(q vv_bootstrap <<<"UPDATE approval SET status='approved', approved_by='sub-vorstand-aa', decided_at=now() WHERE id='$AID'" 2>&1); echo "$O" | grep -qi "approval_attestation_ck"; ck "R3: CHECK verhindert 'approved' ohne Attestation (auch als Eigentümer)" $?
dec sub-vorstand-aa "'gpt-5.3-codex'" >/dev/null
AB=$(q vv_bootstrap <<<"SELECT status||'/'||approved_by||'/'||reviewer_model FROM approval WHERE id='$AID'" | grep -i approved/ | head -1)
[ "$AB" = approved/sub-vorstand-aa/gpt-5.3-codex ]; ck "H1/R3/R4: Freigeber = app.actor, Fremdfamilie attestiert ($AB)" $?
C1=$(q vv_worker <<<"BEGIN; SELECT set_config('app.tenant_id','$AA',true); SELECT (vv_consume_approval('q05.import.commit','ci1') IS NOT NULL); COMMIT;" | grep -iE '^(t|f)$' | head -1)
C2=$(q vv_worker <<<"BEGIN; SELECT set_config('app.tenant_id','$AA',true); SELECT (vv_consume_approval('q05.import.commit','ci1') IS NOT NULL); COMMIT;" | grep -iE '^(t|f)$' | head -1)
[ "$C1" = t ] && [ "$C2" = f ]; ck "H1: Consume einmal, Replay ROT ($C1/$C2)" $?
# R4: Effekt ohne Freigeber-Zuordnung (Stage-0-Platzhalter) -> niemand darf entscheiden
q vv_app >/dev/null 2>&1 <<SQL
BEGIN; SELECT set_config('app.tenant_id','$AA',true); SELECT set_config('app.actor','sub-schrift-aa',true);
INSERT INTO approval(tenant_id,kind,effect_id,subject_ref,requested_by,builder_model) VALUES ('$AA','deletion','person.delete','ci-nomap','sub-schrift-aa','human:manuell'); COMMIT;
SQL
NID=$(q vv_bootstrap <<<"SELECT id FROM approval WHERE subject_ref='ci-nomap'" | grep -iE '^[0-9a-f-]{36}$' | head -1)
O=$(q vv_app 2>&1 <<SQL
BEGIN; SELECT set_config('app.tenant_id','$AA',true); SELECT set_config('app.actor','sub-vorstand-aa',true);
SELECT vv_decide_approval('$NID','approved'); COMMIT;
SQL
); echo "$O" | grep -qi "keine Freigeber-Zuordnung"; ck "R4: Effekt ohne Freigeber-Zuordnung -> deny-by-default" $?

# R1 (B-02): Audit nur über geprüfte Funktion
O=$(q vv_app <<<"BEGIN; SELECT set_config('app.tenant_id','$AA',true); INSERT INTO audit_log(tenant_id,actor,action) VALUES ('$AA','fake','fake'); COMMIT;" 2>&1); echo "$O" | grep -qi "permission denied"; ck "R1: vv_app INSERT audit_log denied" $?
O=$(q vv_app <<<"BEGIN; SELECT set_config('app.tenant_id','$AA',true); INSERT INTO audit_log(id,tenant_id,actor,action) OVERRIDING SYSTEM VALUE VALUES (999999,'$AA','fake','fake'); COMMIT;" 2>&1); echo "$O" | grep -qi "permission denied"; ck "R1: OVERRIDING SYSTEM VALUE denied" $?
O=$(q vv_app <<<"BEGIN; SELECT set_config('app.tenant_id','$AA',true); INSERT INTO audit_anchor(tenant_id,head_hash,reason) VALUES ('$AA','x','x'); COMMIT;" 2>&1); echo "$O" | grep -qi "permission denied"; ck "R1: vv_app INSERT audit_anchor denied" $?
O=$(q vv_app <<<"BEGIN; SELECT set_config('app.tenant_id','$AA',true); SELECT set_config('app.actor','sub-schrift-aa',true); SELECT vv_audit_write('app.x',NULL,'{}','sub-vorstand-aa'); COMMIT;" 2>&1); echo "$O" | grep -qi "permission denied"; ck "R1: vv_app kann Actor nicht vorgeben (vv_audit_write denied)" $?
O=$(q vv_app <<<"BEGIN; SELECT set_config('app.tenant_id','$AA',true); SELECT set_config('app.actor','sub-schrift-aa',true); SELECT vv_audit_log('m05.execute','x','{}'); COMMIT;" 2>&1); echo "$O" | grep -qi "reserviert"; ck "R1: reservierte Fach-Aktion über vv_audit_log abgewiesen" $?
q vv_app >/dev/null 2>&1 <<<"BEGIN; SELECT set_config('app.tenant_id','$AA',true); SELECT set_config('app.actor','sub-schrift-aa',true); SELECT vv_audit_log('app.ci.r1','ci-r1','{}'); COMMIT;"
AR=$(q vv_bootstrap <<<"SELECT actor FROM audit_log WHERE subject_ref='ci-r1' ORDER BY id DESC LIMIT 1")
[ "$AR" = sub-schrift-aa ]; ck "R1: vv_audit_log schreibt Actor aus app.actor ($AR)" $?

# S0-1/S0-2 (im M05-Bau entdeckt, Migration 0009): gefälschte Freigabe beim INSERT
q vv_app >/dev/null 2>&1 <<SQL
BEGIN; SELECT set_config('app.tenant_id','$AA',true); SELECT set_config('app.actor','agent-9',true);
INSERT INTO approval(tenant_id,kind,effect_id,subject_ref,requested_by,builder_model,status,approved_by,decided_at)
VALUES ('$AA','deletion','person.delete','ci-forge','agent-9','claude','approved','human-x',now()); COMMIT;
SQL
FS=$(q vv_bootstrap <<<"SELECT status||'/'||coalesce(approved_by,'-') FROM approval WHERE subject_ref='ci-forge'")
[ "$FS" = "pending/-" ]; ck "S0-1: vv_app kann keine bereits genehmigte Freigabe einfügen ($FS)" $?
O=$(q vv_app <<<"BEGIN; SELECT set_config('app.tenant_id','$AA',true); SELECT set_config('app.actor','agent-9',true); INSERT INTO approval(tenant_id,kind,effect_id,subject_ref,requested_by) VALUES ('$AA','deletion','person.delete','ci-spoof','someone-else'); COMMIT;" 2>&1)
echo "$O" | grep -qi "Antragsteller-Spoofing"; ck "S0-2: requested_by ≠ app.actor abgewiesen" $?

# Audit append-only inkl. TRUNCATE
O=$(q vv_bootstrap <<<"TRUNCATE audit_log" 2>&1); echo "$O" | grep -qi "append-only"; ck "Audit: TRUNCATE für Eigentümer blockiert" $?

# H2/H3: Hard-Crash-DLQ + in-flight bleibt am Leben
q vv_app >/dev/null 2>&1 <<<"BEGIN; SELECT set_config('app.tenant_id','$AA',true); INSERT INTO outbox(tenant_id,topic,payload,idempotency_key) VALUES ('$AA','hc','{}','cihc'); COMMIT;"
for i in 1 2 3 4 5 6; do
  q vv_worker >/dev/null 2>&1 <<<"BEGIN; SELECT set_config('app.tenant_id','$AA',true); SELECT count(*) FROM vv_outbox_claim(5, ARRAY['hc','if','lk','dz','fx','pk']); COMMIT;"
  q vv_bootstrap >/dev/null 2>&1 <<<"UPDATE outbox SET locked_until=NULL WHERE idempotency_key='cihc' AND processed_at IS NULL AND dead_at IS NULL;"
done
HC=$(q vv_bootstrap <<<"SELECT attempts||'/'||(dead_at IS NOT NULL)::text FROM outbox WHERE idempotency_key='cihc'")
[[ "$HC" == 5/t* ]]; ck "H2/H3: Hard-Crash-Giftelement in DLQ ($HC)" $?
q vv_app >/dev/null 2>&1 <<<"BEGIN; SELECT set_config('app.tenant_id','$AA',true); INSERT INTO outbox(tenant_id,topic,payload,idempotency_key) VALUES ('$AA','if','{}','ciif'); COMMIT;"
for i in 1 2 3 4; do
  q vv_worker >/dev/null 2>&1 <<<"BEGIN; SELECT set_config('app.tenant_id','$AA',true); SELECT count(*) FROM vv_outbox_claim(5, ARRAY['hc','if','lk','dz','fx','pk']); COMMIT;"
  q vv_bootstrap >/dev/null 2>&1 <<<"UPDATE outbox SET locked_until=NULL WHERE idempotency_key='ciif';"
done
q vv_worker >/dev/null 2>&1 <<<"BEGIN; SELECT set_config('app.tenant_id','$AA',true); SELECT count(*) FROM vv_outbox_claim(5, ARRAY['hc','if','lk','dz','fx','pk']); COMMIT;"
q vv_worker >/dev/null 2>&1 <<<"BEGIN; SELECT set_config('app.tenant_id','$AA',true); SELECT count(*) FROM vv_outbox_claim(5, ARRAY['hc','if','lk','dz','fx','pk']); COMMIT;"
DEAD=$(q vv_bootstrap <<<"SELECT (dead_at IS NOT NULL)::text FROM outbox WHERE idempotency_key='ciif'")
[ "$DEAD" = false ]; ck "H3: in-flight 5. Versuch NICHT fälschlich getötet" $?

# Pro-Nachprüfung 3.1, Restrisiko 1 — Reaper mit FOR UPDATE SKIP LOCKED (keine Lock-Contention).
# Eine reap-fähige (attempts=5, Lease abgelaufen) Zeile wird in einer Hintergrund-Transaktion
# FOR UPDATE gehalten. Ein gleichzeitiger Claim/Reaper muss sie ÜBERSPRINGEN (nicht töten) UND
# darf nicht auf ihr blockieren. Unter dem alten breiten UPDATE hätte der Claim ~4s blockiert.
q vv_app >/dev/null 2>&1 <<<"BEGIN; SELECT set_config('app.tenant_id','$AA',true); INSERT INTO outbox(tenant_id,topic,payload,idempotency_key) VALUES ('$AA','lk','{}','cilock'); COMMIT;"
q vv_bootstrap >/dev/null 2>&1 <<<"UPDATE outbox SET attempts=5, locked_until=now()-interval '1 minute' WHERE idempotency_key='cilock';"
q vv_bootstrap >/dev/null 2>&1 <<SQL &
BEGIN; SELECT id FROM outbox WHERE idempotency_key='cilock' FOR UPDATE; SELECT pg_sleep(6); COMMIT;
SQL
BG=$!
sleep 2
T0=$(date +%s%N)
q vv_worker >/dev/null 2>&1 <<<"BEGIN; SELECT set_config('app.tenant_id','$AA',true); SELECT count(*) FROM vv_outbox_claim(5, ARRAY['hc','if','lk','dz','fx','pk']); COMMIT;"
T1=$(date +%s%N)
MS=$(( (T1 - T0) / 1000000 ))
LOCKDEAD=$(q vv_bootstrap <<<"SELECT (dead_at IS NOT NULL)::text FROM outbox WHERE idempotency_key='cilock'")
wait "$BG" 2>/dev/null
[ "$LOCKDEAD" = false ] && [ "$MS" -lt 3000 ]; ck "Reaper SKIP LOCKED: gelockte tote Zeile übersprungen, kein Blockieren (${MS}ms)" $?
q vv_worker >/dev/null 2>&1 <<<"BEGIN; SELECT set_config('app.tenant_id','$AA',true); SELECT count(*) FROM vv_outbox_claim(5, ARRAY['hc','if','lk','dz','fx','pk']); COMMIT;"
LOCKDEAD2=$(q vv_bootstrap <<<"SELECT (dead_at IS NOT NULL)::text FROM outbox WHERE idempotency_key='cilock'")
[ "$LOCKDEAD2" = true ]; ck "Reaper: nach Lock-Freigabe tote Zeile korrekt in DLQ" $?

# Pro-Nachprüfung 3.1, Restrisiko 2 — kein „Slow-Worker"-Doppelzustand.
# Zeile wird tot markiert (Reaper), danach schließt der langsame Worker doch erfolgreich ab:
# Endzustand muss eindeutig sein (processed_at gesetzt, dead_at abgeräumt) — kein dead_at+processed_at.
q vv_app >/dev/null 2>&1 <<<"BEGIN; SELECT set_config('app.tenant_id','$AA',true); INSERT INTO outbox(tenant_id,topic,payload,idempotency_key) VALUES ('$AA','dz','{}','cidz'); COMMIT;"
# Slow-Worker: 5. Versuch geclaimt (Lease-Token gesetzt), Lease läuft ab, Reaper markiert tot.
q vv_bootstrap >/dev/null 2>&1 <<<"UPDATE outbox SET attempts=4 WHERE idempotency_key='cidz';"
q vv_worker >/dev/null 2>&1 <<<"SELECT count(*) FROM vv_outbox_claim(5, ARRAY['dz'])"
q vv_bootstrap >/dev/null 2>&1 <<<"UPDATE outbox SET locked_until=now()-interval '1 minute' WHERE idempotency_key='cidz';"
q vv_worker >/dev/null 2>&1 <<<"BEGIN; SELECT set_config('app.tenant_id','$AA',true); SELECT count(*) FROM vv_outbox_claim(5, ARRAY['hc','if','lk','dz','fx','pk']); COMMIT;"
DZ1=$(q vv_bootstrap <<<"SELECT (dead_at IS NOT NULL)::text FROM outbox WHERE idempotency_key='cidz'")
DID=$(q vv_bootstrap <<<"SELECT id FROM outbox WHERE idempotency_key='cidz'" | grep -iE '^[0-9a-f-]{36}$' | head -1)
DTK=$(q vv_bootstrap <<<"SELECT lease_token FROM outbox WHERE idempotency_key='cidz'" | grep -iE '^[0-9a-f-]{36}$' | head -1)
q vv_worker >/dev/null 2>&1 <<<"SELECT vv_outbox_done('$DID','$DTK')"
DZ2=$(q vv_bootstrap <<<"SELECT (dead_at IS NULL)::text||'/'||(processed_at IS NOT NULL)::text FROM outbox WHERE idempotency_key='cidz'")
[ "$DZ1" = true ] && [ "$DZ2" = true/true ]; ck "Kein Doppelzustand: Spät-Erfolg räumt dead_at ab (tot=$DZ1 -> clean/done=$DZ2)" $?

# R8 (H-07): Lease-Fencing — ein Worker mit abgelaufenem Lease kann nicht mehr quittieren
q vv_app >/dev/null 2>&1 <<<"BEGIN; SELECT set_config('app.tenant_id','$AA',true); INSERT INTO outbox(tenant_id,topic,payload,idempotency_key) VALUES ('$AA','fx','{}','cifx'); COMMIT;"
q vv_worker >/dev/null 2>&1 <<<"SELECT count(*) FROM vv_outbox_claim(5, ARRAY['fx'])"
FID=$(q vv_bootstrap <<<"SELECT id FROM outbox WHERE idempotency_key='cifx'" | grep -iE '^[0-9a-f-]{36}$' | head -1)
T1=$(q vv_bootstrap <<<"SELECT lease_token FROM outbox WHERE id='$FID'" | grep -iE '^[0-9a-f-]{36}$' | head -1)
q vv_bootstrap >/dev/null 2>&1 <<<"UPDATE outbox SET locked_until = now() - interval '1 second' WHERE id='$FID'"
q vv_worker >/dev/null 2>&1 <<<"SELECT count(*) FROM vv_outbox_claim(5, ARRAY['fx'])"
T2=$(q vv_bootstrap <<<"SELECT lease_token FROM outbox WHERE id='$FID'" | grep -iE '^[0-9a-f-]{36}$' | head -1)
R_OLD=$(q vv_worker <<<"SELECT vv_outbox_done('$FID','$T1')" | grep -iE '^(t|f)$' | head -1)
R_REN=$(q vv_worker <<<"SELECT vv_outbox_renew('$FID','$T1',60)" | grep -iE '^(t|f)$' | head -1)
R_FAIL=$(q vv_worker <<<"SELECT vv_outbox_fail('$FID','$T1','x',5)" | grep -iE '^(t|f)$' | head -1)
P_MID=$(q vv_bootstrap <<<"SELECT (processed_at IS NULL)::text FROM outbox WHERE id='$FID'")
R_NEW=$(q vv_worker <<<"SELECT vv_outbox_done('$FID','$T2')" | grep -iE '^(t|f)$' | head -1)
[ "$T1" != "$T2" ] && [ "$R_OLD" = f ] && [ "$R_REN" = f ] && [ "$R_FAIL" = f ] && [ "$P_MID" = true ] && [ "$R_NEW" = t ]
ck "R8: Fencing — alter Lease quittiert/verlängert/scheitert nicht, neuer Lease quittiert ($R_OLD/$R_REN/$R_FAIL/$R_NEW)" $?

# R5 (H-06): Claim nur für Consumer-Topics; fremde Topics bleiben geparkt
q vv_app >/dev/null 2>&1 <<<"BEGIN; SELECT set_config('app.tenant_id','$AA',true); INSERT INTO outbox(tenant_id,topic,payload,idempotency_key) VALUES ('$AA','pk.ohne.consumer','{}','cipk'); COMMIT;"
q vv_worker >/dev/null 2>&1 <<<"SELECT count(*) FROM vv_outbox_claim(50, ARRAY['m05.execute','m05.import.approved'])"
PK=$(q vv_bootstrap <<<"SELECT attempts||'/'||(processed_at IS NULL)::text||'/'||(dead_at IS NULL)::text FROM outbox WHERE idempotency_key='cipk'")
[ "$PK" = "0/true/true" ]; ck "R5: Event ohne Consumer bleibt unberührt geparkt ($PK)" $?
NN=$(q vv_worker <<<"SELECT count(*) FROM vv_outbox_claim(50, NULL)" | grep -E '^[0-9]+$' | head -1)
[ "$NN" = 0 ]; ck "R5: Claim ohne Topic-Liste claimt nichts (deny-by-default)" $?

# M05/BASIS-02 (Modul-Bau): umfassende adversariale DB-Gegenproben (Python, psycopg)
if python3 "$(dirname "$0")/m05_db_asserts.py"; then pass "M05-Gegenproben (scripts/m05_db_asserts.py)"; else fail "M05-Gegenproben (scripts/m05_db_asserts.py)"; fi

echo "----"
[ "$FAIL" = 0 ] && echo "Alle Sicherheits-Gegenproben grün." || { echo "SICHERHEITS-GEGENPROBE FEHLGESCHLAGEN"; exit 1; }
