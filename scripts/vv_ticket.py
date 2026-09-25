#!/usr/bin/env python3
"""VV — Kontext-Signatur (C-1): Ticket-Werkzeug für TESTS und Gegenproben (nur synthetische Daten).

Erzeugt Tickets im Format des Ticket-Dienstes (apps/ticket):
    v1.<kid>.<payload_b64url>.<hmac_sha256_b64url>
    payload = {"t": <Mandant uuid>, "s": <OIDC-sub>, "iat": <unix>, "exp": <unix>, "jti": <uuid>}

Der Schlüssel kommt aus dem Keyring (JSON, erzeugt von scripts/rotate_ticket_key.sh), Pfad in
VV_TICKET_KEYRING. In Produktion stellt AUSSCHLIESSLICH der Ticket-Dienst Tickets aus; dieses
Werkzeug ist für CI/Prüf-Harness gedacht (dort ist der Keyring ein Wegwerf-Schlüssel je Lauf).

    python3 scripts/vv_ticket.py mint --tenant <uuid> --actor <sub> [--ttl 60]
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import json
import os
import sys
import time
import uuid


def b64url(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode("ascii")


def load_keyring(path: str | None = None) -> tuple[str, bytes]:
    path = path or os.environ.get("VV_TICKET_KEYRING")
    if not path:
        raise SystemExit("VV_TICKET_KEYRING nicht gesetzt (Pfad zum Keyring-JSON)")
    with open(path, encoding="utf-8") as fh:
        ring = json.load(fh)
    kid = ring["active"]
    return kid, base64.b64decode(ring["keys"][kid])


def sign(payload_json: bytes, kid: str, key: bytes) -> str:
    body = b64url(payload_json)
    mac = hmac.new(key, f"v1.{kid}.{body}".encode("ascii"), hashlib.sha256).digest()
    return f"v1.{kid}.{body}.{b64url(mac)}"


def mint(tenant: str, actor: str, ttl: int = 60, *, iat: int | None = None, exp: int | None = None,
         jti: str | None = None, kid: str | None = None, key: bytes | None = None,
         extra: dict | None = None, keyring: str | None = None) -> str:
    if kid is None or key is None:
        rk, rkey = load_keyring(keyring)
        kid = kid or rk
        key = key if key is not None else rkey
    now = int(time.time())
    iat = now if iat is None else iat
    exp = iat + ttl if exp is None else exp
    payload = {"t": tenant, "s": actor, "iat": iat, "exp": exp, "jti": jti or str(uuid.uuid4())}
    if extra:
        payload.update(extra)
    return sign(json.dumps(payload, separators=(",", ":")).encode("utf-8"), kid, key)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    m = sub.add_parser("mint")
    m.add_argument("--tenant", required=True)
    m.add_argument("--actor", required=True)
    m.add_argument("--ttl", type=int, default=60)
    m.add_argument("--iat-offset", type=int, default=0, help="Sekunden relativ zu jetzt (Test: abgelaufen)")
    m.add_argument("--jti")
    a = ap.parse_args()
    if a.cmd == "mint":
        print(mint(a.tenant, a.actor, a.ttl, iat=int(time.time()) + a.iat_offset, jti=a.jti))
    return 0


if __name__ == "__main__":
    sys.exit(main())
