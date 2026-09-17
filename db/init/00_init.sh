#!/bin/bash
# VV initdb-Wrapper (WP1) — spielt Migrationen + Seed sortiert und fail-fast ein.
# Grund: das Postgres-Entrypoint führt NUR Dateien auf oberster Ebene von
# /docker-entrypoint-initdb.d aus (keine Unterverzeichnisse) — ein reiner Verzeichnis-Mount
# würde die Migrationen stillschweigend überspringen (Review-Befund Codex #1).
set -euo pipefail

run() { psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" -f "$1"; }

echo "[vv-init] Migrationen einspielen"
for f in /db/migrations/*.sql; do echo "  -> $f"; run "$f"; done

# App-Rollen-Passwort aus Secret setzen (nicht in SQL hartkodiert).
if [ -n "${VV_APP_PASSWORD:-}" ]; then
  echo "[vv-init] Passwort für vv_app aus VV_APP_PASSWORD setzen"
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
    -c "ALTER ROLE vv_app PASSWORD '${VV_APP_PASSWORD}';"
fi

echo "[vv-init] Seed (nur synthetisch) einspielen"
for f in /db/seed/*.sql; do echo "  -> $f"; run "$f"; done

echo "[vv-init] fertig."
