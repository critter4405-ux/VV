#!/usr/bin/env bash
# VV — Supply-Chain: Container-Images auf @sha256-Digest pinnen.
#
# Warum getrennt vom Rest: die Bau-/Prüf-Sandbox sperrt per Egress-Policy den Zugang zu den
# Container-Registries (Docker Hub, quay.io), daher lassen sich die Digests dort nicht auflösen.
# Dieses Skript in einer Umgebung MIT Registry-Zugang ausführen (lokaler Rechner, GitHub-Runner):
# es löst für jede getaggte Referenz den aktuellen Manifest-Digest auf und schreibt
#   image:tag            ->  image:tag@sha256:<digest>
# in docker-compose.yml und .github/workflows/ci.yml. Idempotent (bereits gepinnte Refs bleiben,
# der Tag vor dem @ dient als lesbarer Anker + Update-Handle für Dependabot(docker)).
#
# Braucht: docker (mit `docker manifest inspect`) ODER skopeo. Kein Pull nötig.
set -euo pipefail
cd "$(dirname "$0")/.."

resolve() { # image:tag -> sha256:...
  local ref="$1"
  if command -v skopeo >/dev/null 2>&1; then
    skopeo inspect --no-tags "docker://$ref" 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin)['Digest'])"
  elif command -v docker >/dev/null 2>&1; then
    DOCKER_CLI_EXPERIMENTAL=enabled docker manifest inspect -v "$ref" 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin)
print((d[0] if isinstance(d,list) else d).get('Descriptor',{}).get('digest',''))"
  else
    echo "FEHLER: weder docker noch skopeo vorhanden" >&2; exit 2
  fi
}

# Alle image:tag-Referenzen aus den beiden Zieldateien einsammeln (noch ohne @sha256).
mapfile -t REFS < <(grep -rhoE 'image: *[^ ]+' docker-compose.yml .github/workflows/ci.yml \
  | sed -E 's/image: *//' | grep -v '@sha256:' | sort -u)

for ref in "${REFS[@]}"; do
  dig="$(resolve "$ref")"
  [ -z "$dig" ] && { echo "!! konnte $ref nicht auflösen (übersprungen)"; continue; }
  pinned="${ref}@${dig}"
  # In beiden Dateien ersetzen (image: <ref>  ->  image: <ref>@sha256:...)
  for f in docker-compose.yml .github/workflows/ci.yml; do
    python3 - "$f" "$ref" "$pinned" <<'PY'
import sys,io
f,ref,pin=sys.argv[1],sys.argv[2],sys.argv[3]
t=io.open(f,encoding="utf-8").read()
t=t.replace("image: "+ref+"\n","image: "+pin+"\n").replace("image: "+ref+" ","image: "+pin+" ")
io.open(f,"w",encoding="utf-8").write(t)
PY
  done
  echo "gepinnt: $ref -> $dig"
done
echo "Fertig. docker compose config prüfen und committen."
