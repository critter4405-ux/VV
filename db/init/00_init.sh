#!/bin/bash
# VV initdb-Wrapper (WP1) — spielt Migrationen + Seed sortiert und fail-fast ein.
# Grund: das Postgres-Entrypoint führt NUR Dateien auf oberster Ebene von
# /docker-entrypoint-initdb.d aus (keine Unterverzeichnisse) — ein reiner Verzeichnis-Mount
# würde die Migrationen stillschweigend überspringen (Review-Befund Codex #1).
set -euo pipefail

run() { psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" -f "$1"; }

# Passwort aus Secret setzen — OHNE String-Interpolation ins SQL (Review-Runde 2, Codex #7-new:
# ALTER ROLE ... PASSWORD '${VAR}' war quoting-/injection-anfällig). Der Wert wird als psql-Variable
# übergeben und mit format('%L', ...) sicher quotiert; \gexec führt das erzeugte Statement aus.
set_password() {
  local role="$1" pw="$2"
  [ -n "$pw" ] || return 0
  # \gexec ohne abschließendes ';' (sonst ist der Query-Puffer bereits geleert -> No-Op).
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
    -v role="$role" -v pw="$pw" <<'SQL'
SELECT format('ALTER ROLE %I PASSWORD %L', :'role', :'pw')
\gexec
SQL
}

echo "[vv-init] Migrationen einspielen"
for f in /db/migrations/*.sql; do echo "  -> $f"; run "$f"; done

echo "[vv-init] Rollen-Passwörter aus Secrets setzen (sicher quotiert)"
set_password vv_app    "${VV_APP_PASSWORD:-}"
set_password vv_worker "${VV_WORKER_PASSWORD:-}"

echo "[vv-init] Seed (nur synthetisch) einspielen"
for f in /db/seed/*.sql; do echo "  -> $f"; run "$f"; done

echo "[vv-init] fertig."
