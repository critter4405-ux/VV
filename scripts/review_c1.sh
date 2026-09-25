#!/usr/bin/env bash
# ============================================================================
# VV C-1 „Kontext-Signatur" — Fremdmodell-Review-Harness, READ-ONLY (Vier-Augen)
# Unabhängiger Live-Lauf gegen eine FRISCHE PostgreSQL 16 im Docker-Container. Auf dem Host nur Docker.
#   vv_c1_pg   postgres:16  — DB (Migrationen 0001–0013 + synthetische Seeds)
#   vv_c1_py   python:3.12  — Keyring (Betreiber-Skript), Validatoren LIVE, Selbsttest, DB-Gegenproben
#                             (Stage 0 + M05 + C-1 DoD 1–7 inkl. echtem Schlüsselwechsel)
#   vv_c1_node node:22      — Typecheck + Tests Web/Worker/Ticket-Dienst, C-1 Ende-zu-Ende (fail-closed)
# Der reale Repo-Baum wird NICHT verändert (Temp-Kopie, docker cp). Aufruf aus dem Repo-Root, in WSL:
#     bash scripts/review_c1.sh            # optional: VV_PGPORT=55434, VV_KEEP_DB=1
# Das Skript URTEILT NICHT: PASS/FAIL je Schritt + Logs unter ./review-c1-out/ (nur synthetische Daten).
# ============================================================================
set -uo pipefail
REPO_SRC="$(pwd)"
PORT="${VV_PGPORT:-55434}"
PW="change_me_dev_only"
PGC="vv_c1_pg"; PYC="vv_c1_py"; NDC="vv_c1_node"; NET="vv_c1_net"
OUT="$REPO_SRC/review-c1-out"
WORK="$(mktemp -d)"; PASS=0; FAIL=0
ok(){ echo "  [PASS] $1"; PASS=$((PASS+1)); }
no(){ echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }
hd(){ echo; echo "== $1 =="; }
cleanup(){
  docker rm -f "$PYC" "$NDC" >/dev/null 2>&1
  if [ "${VV_KEEP_DB:-0}" = 1 ]; then echo "VV_KEEP_DB=1: $PGC läuft weiter auf 127.0.0.1:$PORT (Keyring: $OUT/ticket_keyring.json)";
  else docker rm -f "$PGC" >/dev/null 2>&1; docker network rm "$NET" >/dev/null 2>&1; fi
  rm -rf "$WORK"; }
trap cleanup EXIT

command -v docker >/dev/null || { echo "Docker nicht auf PATH"; exit 2; }
[ -f "$REPO_SRC/db/migrations/0013_kontext_signatur.sql" ] || { echo "Bitte aus dem Repo-Root (Branch feat/c1-kontext-signatur) aufrufen"; exit 2; }
mkdir -p "$OUT"

hd "0) Stand (read-only)"
HEAD=$(git -C "$REPO_SRC" rev-parse --short HEAD 2>/dev/null || echo "?")
BR=$(git -C "$REPO_SRC" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")
echo "  Branch=$BR HEAD=$HEAD"; echo "$BR $HEAD" > "$OUT/stand.txt"
git -C "$REPO_SRC" status --porcelain 2>/dev/null | grep -v '^?? review-' | head -5 > "$OUT/dirty.txt"
[ -s "$OUT/dirty.txt" ] && no "Arbeitsbaum nicht sauber (siehe dirty.txt)" || ok "Arbeitsbaum sauber"
cp -r "$REPO_SRC" "$WORK/repo"
rm -rf "$WORK/repo/.git" "$WORK/repo/review-"*-out "$WORK/repo/apps/"*/node_modules 2>/dev/null
# CRLF-Schutz (Windows-Checkout): Skripte/SQL mit LF in die Container
find "$WORK/repo" -type f \( -name '*.sh' -o -name '*.sql' -o -name '*.py' \) -exec sed -i 's/\r$//' {} +

hd "1) Frische PostgreSQL 16 + Migrationen 0001–0013 + Seeds"
docker rm -f "$PGC" "$PYC" "$NDC" >/dev/null 2>&1; docker network rm "$NET" >/dev/null 2>&1
docker network create "$NET" >/dev/null
docker run -d --name "$PGC" --network "$NET" -p "127.0.0.1:$PORT:5432" \
  -e POSTGRES_USER=vv_bootstrap -e POSTGRES_PASSWORD="$PW" -e POSTGRES_DB=vv postgres:16 >/dev/null \
  || { echo "postgres:16 nicht startbar"; exit 2; }
for i in $(seq 1 60); do docker exec "$PGC" pg_isready -U vv_bootstrap -d vv >/dev/null 2>&1 && break; sleep 1; done
sleep 2
docker cp "$WORK/repo/db" "$PGC:/db" >/dev/null
MIG=$(docker exec -e PGPASSWORD="$PW" "$PGC" bash -c '
  set -e
  for f in /db/migrations/*.sql; do psql -q -v ON_ERROR_STOP=1 -U vv_bootstrap -d vv -f "$f" >/dev/null; done
  for f in /db/seed/*.sql; do psql -q -v ON_ERROR_STOP=1 -U vv_bootstrap -d vv -f "$f" >/dev/null; done
  echo OK' 2>&1)
for r in vv_app vv_worker; do
  docker exec -e PGPASSWORD="$PW" "$PGC" psql -q -v ON_ERROR_STOP=1 -U vv_bootstrap -d vv \
    -c "ALTER ROLE $r PASSWORD 'change_me_dev_only'" >/dev/null || MIG="Passwort $r"
done
[ "$MIG" = "OK" ] && ok "Migrationen 0001–0013 + Seeds fehlerfrei" || { no "Migrationen: $MIG"; echo "$MIG" > "$OUT/migration.txt"; }
docker exec "$PGC" psql -tA -U vv_bootstrap -d vv -c "select version()" > "$OUT/pg-version.txt"

hd "2) Python-Container: Keyring, Validatoren LIVE, Selbsttest, DB-Gegenproben"
docker run -d --name "$PYC" --network "$NET" python:3.12 sleep 3600 >/dev/null
docker cp "$WORK/repo" "$PYC:/repo" >/dev/null
# apt-Index kann einzelne 404 liefern (P55) -> update-Fehler tolerieren, Installation zählt.
docker exec "$PYC" bash -c "(apt-get update -qq || true) >/dev/null 2>&1; apt-get install -y -qq postgresql-client >/dev/null && \
  pip install -q -r /repo/validators/requirements.txt" > "$OUT/py-setup.txt" 2>&1 \
  && ok "psql + psycopg im Python-Container" || no "Python-Setup (siehe py-setup.txt)"
docker exec -w /repo -e PGHOST="$PGC" -e PGUSER=vv_bootstrap -e PGPASSWORD="$PW" -e PGDATABASE=vv \
  -e KEYRING_FILE=/tmp/ticket_keyring.json "$PYC" bash scripts/rotate_ticket_key.sh init > "$OUT/keyring-init.txt" 2>&1 \
  && ok "Wegwerf-Ticket-Schlüssel per Betreiber-Skript (DB + Keyring)" || no "Keyring-Init (siehe keyring-init.txt)"
KR="-e VV_TICKET_KEYRING=/tmp/ticket_keyring.json"
docker exec -w /repo -e VV_REPORT_DIR=review-live \
  -e VV_VALIDATE_DSN="host=$PGC dbname=vv user=vv_app password=$PW" -e VV_REQUIRE_LIVE=1 \
  "$PYC" python -m validators.validate > "$OUT/validators-live.txt" 2>&1 \
  && ok "Validatoren LIVE grün (inkl. C-1)" || no "Validatoren LIVE (siehe validators-live.txt)"
docker exec -w /repo "$PYC" python -m validators.selftest > "$OUT/selftest.txt" 2>&1 \
  && ok "Validator-Selbsttest grün" || no "Selbsttest (siehe selftest.txt)"
docker exec -w /repo -e VV_PGHOST="$PGC" -e PW="$PW" $KR -e VV_M05_REPORT=/tmp/m05.json \
  "$PYC" bash scripts/ci_db_asserts.sh > "$OUT/db-asserts.txt" 2>&1 \
  && ok "DB-Gegenproben Stage 0 + M05 (auf Ticket-Weg) grün" || no "DB-Gegenproben (siehe db-asserts.txt)"
docker cp "$PYC:/tmp/m05.json" "$OUT/m05-asserts.json" >/dev/null 2>&1
docker exec -w /repo -e VV_PGHOST="$PGC" -e PW="$PW" $KR -e VV_C1_REPORT=/tmp/c1.json \
  "$PYC" python3 scripts/c1_db_asserts.py > "$OUT/c1-asserts.txt" 2>&1 \
  && ok "C-1 DB-Gegenproben DoD 1–7 grün" || no "C-1 DB-Gegenproben (siehe c1-asserts.txt)"
docker cp "$PYC:/tmp/c1.json" "$OUT/c1-asserts.json" >/dev/null 2>&1
docker cp "$PYC:/tmp/ticket_keyring.json" "$WORK/ticket_keyring.json" >/dev/null 2>&1
[ "${VV_KEEP_DB:-0}" = 1 ] && cp "$WORK/ticket_keyring.json" "$OUT/ticket_keyring.json"

hd "3) Node-Container: Typecheck + Tests Web/Worker/Ticket-Dienst + C-1 Ende-zu-Ende"
docker run -d --name "$NDC" --network "$NET" node:22 sleep 3600 >/dev/null
docker cp "$WORK/repo" "$NDC:/repo" >/dev/null
docker cp "$WORK/ticket_keyring.json" "$NDC:/tmp/ticket_keyring.json" >/dev/null
for app in web worker ticket; do
  docker exec -w "/repo/apps/$app" "$NDC" bash -c "npm ci --silent && npx tsc --noEmit" > "$OUT/typecheck-$app.txt" 2>&1 \
    && ok "Typecheck $app" || no "Typecheck $app (siehe typecheck-$app.txt)"
  docker exec -w "/repo/apps/$app" \
    -e DATABASE_URL="postgres://vv_app:$PW@$PGC:5432/vv" \
    -e WORKER_DATABASE_URL="postgres://vv_worker:$PW@$PGC:5432/vv" \
    -e VV_BOOTSTRAP_URL="postgres://vv_bootstrap:$PW@$PGC:5432/vv" $KR -e VV_REQUIRE_DB=1 \
    "$NDC" npm test > "$OUT/test-$app.txt" 2>&1 \
    && ok "Tests $app" || no "Tests $app (siehe test-$app.txt)"
  docker exec -w "/repo/apps/$app" "$NDC" npm audit --omit=dev --audit-level=high > "$OUT/audit-$app.txt" 2>&1 \
    && ok "npm audit $app (high/critical: 0)" || no "npm audit $app (siehe audit-$app.txt)"
done
docker exec -w /repo -e VV_PGHOST="$PGC" -e PW="$PW" $KR "$NDC" bash scripts/c1_e2e.sh > "$OUT/c1-e2e.txt" 2>&1 \
  && ok "C-1 Ende-zu-Ende (Token -> Ticket -> Web -> DB, fail-closed)" || no "C-1 Ende-zu-Ende (siehe c1-e2e.txt)"

hd "4) Zusatz: Idempotenz 0006–0013 + direkte vv_app-Zugriffe"
RE=$(docker exec -e PGPASSWORD="$PW" "$PGC" bash -c '
  for f in /db/migrations/000[6-9]*.sql /db/migrations/001[0-9]*.sql; do psql -q -v ON_ERROR_STOP=1 -U vv_bootstrap -d vv -f "$f" >/dev/null || exit 1; done; echo OK' 2>&1)
[ "$RE" = "OK" ] && ok "0006–0013 erneut fehlerfrei (idempotent)" || no "Idempotenz: $RE"
for t in person member membership_period approval outbox audit_log scope_node principal_link ticket_key vv_ctx; do
  N=$(docker exec -e PGPASSWORD="$PW" "$PGC" psql -tA -h 127.0.0.1 -U vv_app -d vv -c "SELECT count(*) FROM $t" 2>&1)
  echo "$N" | grep -qi "permission denied" && ok "vv_app ohne Tabellenrecht auf $t" || no "vv_app liest $t: $(echo "$N" | head -c 60)"
done
N=$(docker exec -e PGPASSWORD="$PW" "$PGC" psql -tA -h 127.0.0.1 -U vv_app -d vv -c \
  "BEGIN; SELECT set_config('app.tenant_id','00000000-0000-0000-0000-0000000000bb',true); SELECT count(*) FROM m05_list_members(); COMMIT;" 2>&1)
echo "$N" | grep -qi "deny-by-default" && ok "P54-Repro: gefälschte GUC öffnet nichts" || no "P54-Repro: $(echo "$N" | head -c 80)"

echo
echo "===================================================================="
echo "ERGEBNIS: PASS=$PASS FAIL=$FAIL   (Logs: review-c1-out/)"
echo "Das Skript urteilt nicht — Bewertung durch den Prüfer."
echo "===================================================================="
