#!/usr/bin/env python3
"""CI smoke test for the agent's wire API — no hardware needed.

Launches `MinStats --serve` headless, parses the pairing link it prints,
then drives the REAL stack: TLS handshake, unauth /health, HMAC-signed
/stats with response-signature verification, nonce-replay rejection, and
the graceful 404 on the removed control route. Sensors read empty on a CI
VM — irrelevant; this proves auth + TLS + routing end to end.
"""
import base64, hashlib, hmac, json, os, ssl, subprocess, sys, tempfile, time
import urllib.error, urllib.parse, urllib.request

BINARY = ".build/release/MinStats"

def fail(msg):
    print(f"FAIL: {msg}", file=sys.stderr)
    sys.exit(1)

# Isolated support dir: fresh client store + fresh TLS identity, minted and
# used by this very process — no shared state, no Keychain partition prompts.
env = dict(os.environ, MINSTATS_SUPPORT_DIR=tempfile.mkdtemp(prefix="minstats-smoke-"))
proc = subprocess.Popen([BINARY, "--serve"], stderr=subprocess.PIPE, text=True, env=env)
try:
    pairing = None
    deadline = time.time() + 30
    while time.time() < deadline:
        line = proc.stderr.readline()
        if not line:
            time.sleep(0.2)
            continue
        if "pairing:" in line:
            pairing = line.split("pairing:", 1)[1].strip()
            break
    if not pairing:
        fail("never saw the pairing link")

    q = dict(urllib.parse.parse_qsl(urllib.parse.urlparse(pairing).query))
    secret = base64.b64decode(q["secret"].replace(" ", "+"))
    client_id = q.get("client", q["id"])
    port = q.get("tlsport") or fail("pairing link has no tlsport")
    base = f"https://127.0.0.1:{port}"

    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE

    def call(method, path, headers=None, expect=200):
        req = urllib.request.Request(base + path, headers=headers or {}, method=method)
        try:
            with urllib.request.urlopen(req, context=ctx, timeout=15) as r:
                return r.status, r.read(), dict(r.headers)
        except urllib.error.HTTPError as e:
            return e.code, e.read(), dict(e.headers)

    def signed_headers(method, path, nonce):
        ts = str(time.time())
        msg = f"{method}\n{path}\n{ts}\n{nonce}\n{hashlib.sha256(b'').hexdigest()}".encode()
        sig = base64.b64encode(hmac.new(secret, msg, hashlib.sha256).digest()).decode()
        return {"X-MinStats-Key": client_id, "X-MinStats-Timestamp": ts,
                "X-MinStats-Nonce": nonce, "X-MinStats-Signature": sig}

    # 1. Unauthenticated /health over TLS.
    for attempt in range(20):
        try:
            status, body, _ = call("GET", "/health")
            break
        except Exception:
            time.sleep(0.5)
    else:
        fail("TLS listener never answered /health")
    health = json.loads(body)
    assert status == 200 and "agent" in health, f"health: {status} {body[:100]}"
    print(f"ok /health (agent {health['agent']})")

    # 2. Signed /stats, response signature verified.
    nonce = "ci-nonce-0001"
    status, body, resp_headers = call("GET", "/stats", signed_headers("GET", "/stats", nonce))
    assert status == 200, f"/stats: {status} {body[:100]}"
    rmsg = f"RESPONSE\n{nonce}\n{hashlib.sha256(body).hexdigest()}".encode()
    expected = base64.b64encode(hmac.new(secret, rmsg, hashlib.sha256).digest()).decode()
    got = resp_headers.get("X-MinStats-Signature")
    assert got == expected, f"response signature invalid: {got}"
    print("ok /stats signed + response signature valid")

    # 3. Replaying the same nonce must be rejected.
    status, _, _ = call("GET", "/stats", signed_headers("GET", "/stats", nonce))
    assert status == 401, f"replay accepted?! {status}"
    print("ok replay rejected (401)")

    # 4. Bad signature must be rejected, and must not burn the nonce.
    h = signed_headers("GET", "/stats", "ci-nonce-0002")
    h["X-MinStats-Signature"] = base64.b64encode(b"0" * 32).decode()
    status, _, _ = call("GET", "/stats", h)
    assert status == 401, f"forged signature accepted?! {status}"
    status, _, _ = call("GET", "/stats", signed_headers("GET", "/stats", "ci-nonce-0002"))
    assert status == 200, "nonce was burned by a FORGED request (replay-DoS hazard)"
    print("ok forged signature rejected, nonce not burned")

    # 5. The removed control route 404s gracefully.
    status, _, _ = call("POST", "/control/restart", signed_headers("POST", "/control/restart", "ci-nonce-0003"))
    assert status == 404, f"/control/restart: {status}"
    print("ok removed route 404s")

    print("wire smoke: ALL PASS")
finally:
    proc.terminate()
