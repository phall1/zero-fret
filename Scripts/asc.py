#!/usr/bin/env python3
"""Minimal App Store Connect API client: ES256 JWT, no third-party dependencies.

    Scripts/asc.py GET /v1/apps
    Scripts/asc.py GET '/v1/builds?filter[app]=ID&limit=5'
    Scripts/asc.py PATCH /v1/betaBuildLocalizations/ID '{"data": {...}}'

Credentials come from the environment, same three variables `Scripts/archive.sh`
uses, so `source .env.asc` is enough:

    ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH

They are read rather than hardcoded so this file can be tracked in a public
repo. The .p8 is the actual secret, but the key and issuer IDs identify the
account and belong with the team ID in gitignored config.

Why hand-rolled: the official tooling wants a Ruby or Node toolchain for what is
one signed JWT and a few GETs. `openssl dgst -sha256 -sign` does the ES256
signature; the only fiddly part is that OpenSSL emits DER and JWT wants the raw
r||s pair, which `_der_to_raw` converts.
"""
import base64, json, os, subprocess, sys, time, urllib.request, urllib.error


def _env(name, hint):
    value = os.environ.get(name)
    if not value:
        sys.exit(f"error: {name} is not set. {hint}\n"
                 f"       source .env.asc  (see .env.asc.example)")
    return value


KEY = os.path.expanduser(_env("ASC_KEY_PATH", "Path to your AuthKey_*.p8."))
KID = _env("ASC_KEY_ID", "The key ID from App Store Connect.")
ISS = _env("ASC_ISSUER_ID", "The issuer ID from the same Keys page.")


def _b64(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=")


def _der_to_raw(der):
    """ECDSA signature: DER SEQUENCE of two INTEGERs -> the raw 64-byte r||s."""
    assert der[0] == 0x30
    i = 2 if der[1] < 0x80 else 2 + (der[1] & 0x7f)

    def rd(i):
        assert der[i] == 0x02
        n = der[i + 1]
        # Strip DER's sign-padding byte, then left-pad to the P-256 field width.
        return der[i + 2:i + 2 + n].lstrip(b"\x00").rjust(32, b"\x00"), i + 2 + n

    r, i = rd(i)
    s, _ = rd(i)
    return r + s


def token():
    header = _b64(json.dumps({"alg": "ES256", "kid": KID, "typ": "JWT"},
                             separators=(",", ":")).encode())
    now = int(time.time())
    payload = _b64(json.dumps({"iss": ISS, "iat": now, "exp": now + 900,
                               "aud": "appstoreconnect-v1"},
                              separators=(",", ":")).encode())
    signing_input = header + b"." + payload
    der = subprocess.run(["openssl", "dgst", "-sha256", "-sign", KEY],
                         input=signing_input, capture_output=True, check=True).stdout
    return (signing_input + b"." + _b64(_der_to_raw(der))).decode()


def call(method, path, body=None):
    url = path if path.startswith("http") else "https://api.appstoreconnect.apple.com" + path
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", "Bearer " + token())
    if data:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req) as r:
            raw = r.read().decode()
            return r.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        try:
            return e.code, json.loads(raw)
        except Exception:
            return e.code, {"raw": raw}


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    method, path = sys.argv[1], sys.argv[2]
    body = json.loads(sys.argv[3]) if len(sys.argv) > 3 else None
    status, out = call(method, path, body)
    print("HTTP", status)
    print(json.dumps(out, indent=1)[:4000])
