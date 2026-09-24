#!/usr/bin/env bash
# ============================================================================
# VV M05 — Fremdmodell-Review-Harness, READ-ONLY (Vier-Augen, Phase C)
# Unabhängiger Live-Lauf gegen eine FRISCHE PostgreSQL 16 im Docker-Container.
# Auf dem Host wird NUR Docker gebraucht. Container:
#   vv_m05_pg   postgres:16      — Datenbank (Migrationen 0001–0011 + synthetische Seeds)
#   vv_m05_py   python:3.12      — Validatoren LIVE, Selbsttest, DB-Gegenproben (psql + psycopg)
#   vv_m05_node node:22          — Typechecks + Unit-/Integrationstests Web/Worker
# Der reale Repo-Baum wird NICHT verändert (Arbeit in einer Temp-Kopie, Übertragung per docker cp).
#
# Aufruf aus dem Repo-Root, am zuverlässigsten in WSL (nicht Git Bash, MSYS-Pfadumwandlung):
#     bash scripts/review_m05.sh            # optional: VV_PGPORT=55433
# Braucht Registry-Zugang für postgres:16, python:3.12, node:22 (bzw. lokal vorhandene Images).
#
# Das Skript URTEILT NICHT. Es liefert je Schritt PASS/FAIL + die vollständigen Logs unter
# ./review-m05-out/ (nur synthetische Daten). Das Urteil zieht der Prüfer.
# ============================================================================
set -uo pipefail
REPO_SRC="$(pwd)"
PORT="${VV_PGPORT:-55433}"
PW="change_me_dev_only"
PGC="vv_m05_pg"; PYC="vv_m05_py"; NDC="vv_m05_node"; NET="vv_m05_net"
OUT="$REPO_SRC/review-m05-out"
WORK="$(mktemp -d)"; PASS=0; FAIL=0
ok(){ echo "  [PASS] $1"; PASS=$((PASS+1)); }
no(){ echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }
hd(){ echo; echo "== $1 =="; }
cleanup(){ docker rm -f "$PGC" "$PYC" "$NDC" >/dev/null 2>&1; docker network rm "$NET" >/dev/null 2>&1; rm -rf "$WORK"; }
trap cleanup EXIT

command -v docker >/dev/null || { echo "Docker nicht auf PATH"; exit 2; }
[ -f "$REPO_SRC/db/migrations/0008_m05_functions.sql" ] || { echo "Bitte aus dem Repo-Root aufrufen"; exit 2; }
mkdir -p "$OUT"

hd "0) Stand (read-only)"
HEAD=$(git -C "$REPO_SRC" rev-parse --short HEAD 2>/dev/null || echo "?")
BR=$(git -C "$REPO_SRC" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")
echo "  Branch=$BR HEAD=$HEAD"; echo "$BR $HEAD" > "$OUT/stand.txt"
git -C "$REPO_SRC" status --porcelain 2>/dev/null | grep -v '^?? review-m05-out' | head -5 > "$OUT/dirty.txt"
[ -s "$OUT/dirty.txt" ] && no "Arbeitsbaum nicht sauber (siehe dirty.txt)" || ok "Arbeitsbaum sauber"
cp -r "$REPO_SRC" "$WORK/repo"
rm -rf "$WORK/repo/.git" "$WORK/repo/review-m05-out" "$WORK/repo/apps/"*/node_modules 2>/dev/null

hd "1) Frische PostgreSQL 16 + Migrationen 0001–0011 + Seeds"
docker rm -f "$PGC" "$PYC" "$NDC" >/dev/null 2>&1; docker network rm "$NET" >/dev/null 2>&1
docker network create "$NET" >/dev/null
docker run -d --name "$PGC" --network "$NET" -p "127.0.0.1:$PORT:5432" \
  -e POSTGRES_USER=vv_bootstrap -e POSTGRES_PASSWORD="$PW" -e POSTGRES_DB=vv postgres:16 >/dev/null \
  || { echo "postgres:16 nicht startbar"; exit 2; }
for i in $(seq 1 60); do docker exec "$PGC" pg_isready -U vv_bootstrap -d vv >/dev/null 2>&1 && break; sleep 1; done
docker cp "$WORK/repo/db" "$PGC:/db" >/dev/null
MIG=$(docker exec -e PGPASSWORD="$PW" "$PGC" bash -c '
  set -e
  for f in /db/migrations/*.sql; do psql -q -v ON_ERROR_STOP=1 -U vv_bootstrap -d vv -f "$f" >/dev/null; done
  for f in /db/seed/*.sql; do psql -q -v ON_ERROR_STOP=1 -U vv_bootstrap -d vv -f "$f" >/dev/null; done
  echo OK' 2>&1)
# Test-Harness: feste Dev-Literale (keine Secrets, keine Interpolation)
for r in vv_app vv_worker; do
  docker exec -e PGPASSWORD="$PW" "$PGC" psql -q -v ON_ERROR_STOP=1 -U vv_bootstrap -d vv \
    -c "ALTER ROLE $r PASSWORD 'change_me_dev_only'" >/dev/null || MIG="Passwort $r"
done
[ "$MIG" = "OK" ] && ok "Migrationen + Seeds fehlerfrei" || { no "Migrationen: $MIG"; echo "$MIG" > "$OUT/migration.txt"; }
docker exec "$PGC" psql -tA -U vv_bootstrap -d vv -c "select version()" > "$OUT/pg-version.txt"

hd "2) Python-Container: Validatoren LIVE, Selbsttest, DB-Gegenproben (Stage 0 + M05)"
docker run -d --name "$PYC" --network "$NET" python:3.12 sleep 3600 >/dev/null
docker cp "$WORK/repo" "$PYC:/repo" >/dev/null
docker exec "$PYC" bash -c "apt-get update -qq >/dev/null && apt-get install -y -qq postgresql-client >/dev/null && \
  pip install -q -r /repo/validators/requirements.txt" > "$OUT/py-setup.txt" 2>&1 \
  && ok "psql + psycopg im Python-Container" || no "Python-Setup (siehe py-setup.txt)"
docker exec -w /repo -e VV_REPORT_DIR=review-live \
  -e VV_VALIDATE_DSN="host=$PGC dbname=vv user=vv_app password=$PW" -e VV_REQUIRE_LIVE=1 \
  "$PYC" python -m validators.validate > "$OUT/validators-live.txt" 2>&1 \
  && ok "Validatoren LIVE grün" || no "Validatoren LIVE (siehe validators-live.txt)"
docker exec -w /repo "$PYC" python -m validators.selftest > "$OUT/selftest.txt" 2>&1 \
  && ok "Validator-Selbsttest grün" || no "Selbsttest (siehe selftest.txt)"
docker exec -w /repo -e VV_PGHOST="$PGC" -e PW="$PW" -e VV_M05_REPORT=/tmp/m05.json \
  "$PYC" bash scripts/ci_db_asserts.sh > "$OUT/db-asserts.txt" 2>&1 \
  && ok "DB-Gegenproben (Stage 0 + M05) grün" || no "DB-Gegenproben (siehe db-asserts.txt)"
docker cp "$PYC:/tmp/m05.json" "$OUT/m05-asserts.json" >/dev/null 2>&1
grep -E "^\s+\[(FAIL|OK)" "$OUT/db-asserts.txt" | grep -c "FAIL" | xargs -I{} echo "  (FAIL-Zeilen in db-asserts.txt: {})"

hd "3) Node-Container: Typecheck + Tests Web/Worker (gegen dieselbe DB)"
docker run -d --name "$NDC" --network "$NET" node:22 sleep 3600 >/dev/null
docker cp "$WORK/repo/apps" "$NDC:/apps" >/dev/null
for app in web worker; do
  docker exec -w "/apps/$app" "$NDC" bash -c "npm ci --silent && npx tsc --noEmit" > "$OUT/typecheck-$app.txt" 2>&1 \
    && ok "Typecheck $app" || no "Typecheck $app (siehe typecheck-$app.txt)"
  docker exec -w "/apps/$app" \
    -e DATABASE_URL="postgres://vv_app:$PW@$PGC:5432/vv" \
    -e WORKER_DATABASE_URL="postgres://vv_worker:$PW@$PGC:5432/vv" -e VV_REQUIRE_DB=1 \
    "$NDC" npm test > "$OUT/test-$app.txt" 2>&1 \
    && ok "Tests $app (inkl. DB-Integration)" || no "Tests $app (siehe test-$app.txt)"
done

hd "4) Zusatz: Migrationen ein zweites Mal (Idempotenz) + RLS ohne Kontext"
RE=$(docker exec -e PGPASSWORD="$PW" "$PGC" bash -c '
  for f in /db/migrations/000[6-9]*.sql /db/migrations/001[0-9]*.sql; do psql -q -v ON_ERROR_STOP=1 -U vv_bootstrap -d vv -f "$f" >/dev/null || exit 1; done; echo OK' 2>&1)
[ "$RE" = "OK" ] && ok "0006–0011 erneut fehlerfrei (idempotent)" || no "Idempotenz: $RE"
for t in member membership_period m05_approval_request scope_node principal_link; do
  N=$(docker exec -e PGPASSWORD="$PW" "$PGC" psql -tA -h 127.0.0.1 -U vv_app -d vv -c "SELECT count(*) FROM $t" 2>&1)
  echo "$N" | grep -qiE "permission denied|^0$" && ok "vv_app ohne Kontext auf $t: $(echo "$N" | head -c 40)" || no "vv_app sieht $t: $N"
done

echo
echo "===================================================================="
echo "ERGEBNIS: PASS=$PASS FAIL=$FAIL   (Logs: review-m05-out/)"
echo "Das Skript urteilt nicht — Bewertung durch den Prüfer."
echo "===================================================================="
