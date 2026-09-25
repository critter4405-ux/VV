#!/usr/bin/env bash
# VV — Schlüsselverwaltung Kontext-Signatur (C-1, Grill P58 Punkt 6). Betreiber-Skript.
#
#   scripts/rotate_ticket_key.sh init                 # erster Schlüssel (DB + Keyring des Ticket-Dienstes)
#   scripts/rotate_ticket_key.sh rotate [--transition-min N]   # planmäßig alle 90 Tage (Default N=15)
#   scripts/rotate_ticket_key.sh retire <kid>         # alten Schlüssel deaktivieren (Geheimnis gelöscht)
#   scripts/rotate_ticket_key.sh emergency            # Verdacht: sofort neu + alten sofort deaktivieren
#   scripts/rotate_ticket_key.sh status               # Übersicht, Warnung ab 90 Tagen
#
# Umgebung:
#   PGHOST/PGPORT/PGDATABASE/PGUSER/PGPASSWORD  Betreiber-Verbindung (Superuser vv_bootstrap) — NICHT vv_app
#   KEYRING_FILE          Laufzeit-Secret des Ticket-Dienstes (Default ./.secrets/ticket_keyring.json, 0600,
#                         wird IN PLACE geschrieben -> Bind-Mount/Docker-Secret sieht den neuen Inhalt)
#   SOPS_AGE_RECIPIENTS   optional: zusätzlich sops/age-verschlüsselte Kopie <KEYRING_FILE>.sops.json (ADR-11)
#   TICKET_RESTART_CMD    optional: z. B. "docker compose restart ticket" (sonst Hinweis ausgeben)
#   KEYRING_UID           optional: Eigentümer der Laufzeit-Datei (Container-Nutzer `node` = 1000), damit NUR
#                         der Ticket-Dienst sie lesen kann (Bind-Mount übernimmt Eigentümer + Modus 0600)
#
# Ablauf Wechsel: (1) neuer Schlüssel in die DB (ab jetzt gelten ALT und NEU), (2) Keyring auf NEU,
# (3) Ticket-Dienst neu starten, (4) ALT läuft nach der Übergangszeit ab (valid_until), (5) `retire` löscht
# das alte Geheimnis. Jeder Schritt landet in der Audit-Kette jedes Mandanten (nur Kennung, nie Geheimnis).
# Das Geheimnis wird nie als Programmargument übergeben (nicht in `ps` sichtbar), nur über stdin/Datei.
set -euo pipefail
umask 077
KEYRING_FILE="${KEYRING_FILE:-./.secrets/ticket_keyring.json}"
export PGUSER="${PGUSER:-vv_bootstrap}" PGDATABASE="${PGDATABASE:-vv}"
TRANSITION_MIN=15

die(){ echo "rotate_ticket_key: $*" >&2; exit 1; }
log(){ echo "[ticket-key] $*"; }
psql_in(){ psql -X -q -v ON_ERROR_STOP=1 -At -f -; }

new_kid(){ echo "k$(date -u +%Y%m%d%H%M%S)"; }
new_key(){ python3 -c 'import base64,secrets;print(base64.b64encode(secrets.token_bytes(32)).decode())'; }

ring_get(){ # $1 = active|key:<kid>
  python3 - "$KEYRING_FILE" "$1" <<'PY'
import json,sys
r=json.load(open(sys.argv[1])); q=sys.argv[2]
print(r["active"] if q=="active" else r["keys"][q.split(":",1)[1]])
PY
}

ring_write(){ # stdin: "<kid> <b64key>" (aktiver Schlüssel); schreibt in place (Inode bleibt)
  mkdir -p "$(dirname "$KEYRING_FILE")"
  local tmp; tmp="$(mktemp "$(dirname "$KEYRING_FILE")/.ring.XXXXXX")"
  python3 -c '
import json,sys
kid,key=sys.stdin.read().split()
json.dump({"version":1,"active":kid,"keys":{kid:key}},open(sys.argv[1],"w"))' "$tmp"
  touch "$KEYRING_FILE"; chmod 600 "$KEYRING_FILE"
  cat "$tmp" > "$KEYRING_FILE"; rm -f "$tmp"
  if [ -n "${KEYRING_UID:-}" ]; then chown "$KEYRING_UID" "$KEYRING_FILE"; fi
  if [ -n "${SOPS_AGE_RECIPIENTS:-}" ]; then
    command -v sops >/dev/null || die "SOPS_AGE_RECIPIENTS gesetzt, aber sops fehlt"
    sops --encrypt --age "$SOPS_AGE_RECIPIENTS" --input-type json --output-type json "$KEYRING_FILE" \
      > "${KEYRING_FILE%.json}.sops.json"
    log "verschlüsselte Kopie: ${KEYRING_FILE%.json}.sops.json"
  fi
}

db_add(){ # $1 kid, stdin key
  local key; key="$(cat)"
  printf '\\set kid %s\n\\set key %s\nSELECT vv_ticket_key_add(:'"'"'kid'"'"', decode(:'"'"'key'"'"', '"'"'base64'"'"'));\n' "$1" "$key" | psql_in >/dev/null
}

restart_service(){
  if [ -n "${TICKET_RESTART_CMD:-}" ]; then log "starte Ticket-Dienst neu: $TICKET_RESTART_CMD"; eval "$TICKET_RESTART_CMD"
  else log "HINWEIS: Ticket-Dienst jetzt neu starten (z. B. docker compose restart ticket)"; fi
}

cmd="${1:-}"; shift || true
while [ $# -gt 0 ]; do
  case "$1" in
    --transition-min) TRANSITION_MIN="$2"; shift 2 ;;
    *) ARG="$1"; shift ;;
  esac
done
[[ "$TRANSITION_MIN" =~ ^[0-9]{1,4}$ ]] || die "--transition-min: Minuten (Zahl)"

case "$cmd" in
  init)
    [ -s "$KEYRING_FILE" ] && die "Keyring existiert bereits ($KEYRING_FILE) — für einen Wechsel 'rotate' verwenden"
    KID="$(new_kid)"; KEY="$(new_key)"
    printf '%s' "$KEY" | db_add "$KID"
    printf '%s %s' "$KID" "$KEY" | ring_write
    printf "SELECT vv_ticket_key_event('%s', 'init', '{}'::jsonb);\n" "$KID" | psql_in >/dev/null
    log "Schlüssel $KID angelegt (DB + $KEYRING_FILE)"; restart_service ;;
  rotate|emergency)
    [ -s "$KEYRING_FILE" ] || die "kein Keyring ($KEYRING_FILE) — zuerst 'init'"
    OLD="$(ring_get active)"; KID="$(new_kid)"; KEY="$(new_key)"
    [ "$OLD" != "$KID" ] || die "Kennung kollidiert — eine Sekunde warten"
    printf '%s' "$KEY" | db_add "$KID"                      # ab jetzt: ALT und NEU gültig
    printf '%s %s' "$KID" "$KEY" | ring_write               # Dienst signiert nach Neustart mit NEU
    printf "SELECT vv_ticket_key_event('%s', 'rotate', jsonb_build_object('from', '%s', 'to', '%s', 'mode', '%s'));\n" \
      "$KID" "$OLD" "$KID" "$cmd" | psql_in >/dev/null
    restart_service
    if [ "$cmd" = emergency ]; then
      printf "SELECT vv_ticket_key_disable('%s');\n" "$OLD" | psql_in >/dev/null
      log "NOTFALL: $OLD sofort deaktiviert (Geheimnis gelöscht), neuer Schlüssel $KID"
    else
      printf "SELECT vv_ticket_key_expire('%s', now() + interval '%s minutes');\n" "$OLD" "$TRANSITION_MIN" | psql_in >/dev/null
      log "Wechsel $OLD -> $KID; $OLD gilt noch $TRANSITION_MIN min, danach: $0 retire $OLD"
    fi ;;
  retire)
    [ -n "${ARG:-}" ] || die "retire <kid>"
    [[ "$ARG" =~ ^[a-z0-9]{1,16}$ ]] || die "ungültige Kennung"
    if [ -s "$KEYRING_FILE" ] && [ "$(ring_get active)" = "$ARG" ]; then die "$ARG ist der aktive Signaturschlüssel — zuerst rotieren"; fi
    printf "SELECT vv_ticket_key_disable('%s');\n" "$ARG" | psql_in >/dev/null
    log "$ARG deaktiviert (Geheimnis gelöscht, protokolliert)" ;;
  status)
    psql_in <<'SQL'
SELECT kid || ' | ' || status || ' | angelegt ' || to_char(created_at, 'YYYY-MM-DD') ||
       ' | Alter ' || (current_date - created_at::date) || ' Tage' ||
       coalesce(' | gültig bis ' || to_char(valid_until, 'YYYY-MM-DD HH24:MI'), '') ||
       CASE WHEN status = 'active' AND valid_until IS NULL AND created_at < now() - interval '90 days'
            THEN '  <- WECHSEL FÄLLIG (90 Tage)' ELSE '' END
  FROM ticket_key ORDER BY created_at;
SQL
    ;;
  *) sed -n 2,8p "$0"; exit 2 ;;
esac
