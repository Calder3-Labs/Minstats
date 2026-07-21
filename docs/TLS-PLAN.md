# TLS for the MinStats agent — spike results + implementation plan

Status: **steps 1-4 LIVE as of 2026-07-21** — builds are Developer ID-signed
(`Makefile` `SIGN`), `AgentIdentity.tlsEnabled` is on, and the fix is verified:
two builds with different cdhashes each completed a signed `/stats` over TLS in
~0.1s with zero Keychain prompts (the ad-hoc failure mode was a prompt/hang per
handshake — see below, kept as history). Remaining: re-pair phones so pairings
capture the pin; step 6 (ATS removal, verify on device); step 5 (retire HTTP,
a later major); step 7 (rotation UX decision).

## The blocker: the TLS key can't be signed with without a Keychain prompt

The HTTPS listener needs a `SecIdentity` to sign the handshake. Its private key
is imported (`SecPKCS12Import`) into the login Keychain, and macOS gates key
*use* on two independent things: the trusted-application ACL AND — since 10.12 —
the **key partition list**, which is bound to **code identity (cdhash)**. This
app is **ad-hoc signed**, so every `make run` rebuild changes the cdhash, the
partition list no longer matches, and any signing attempt raises a *"MinStats
wants to sign using key…"* Keychain password dialog. Over Tailscale (or any
unattended/remote poll) nobody is at the Mac to click it, so the TLS handshake
**hangs mid-`SecKeyCreateSignature`** and the connection times out — which
looked exactly like a network/MTU return-path failure but was not. On LAN it
"worked" only because someone was at the Mac to approve it for that build.

This is the **same hazard the code already documents for the agent secret**
(hence that secret lives in a 0600 file, not the Keychain — see the `ClientStore`
comment in `Auth.swift`). The TLS key can't be a plain file, though: the TLS
stack requires a `SecIdentity`, which is Keychain-bound on macOS.

**Things that do NOT fix it (tried and rejected 2026-07-20):**
- An **allow-any ACL** on import (`SecAccessCreate` + nil trusted-app list). It
  opens the ACL but NOT the partition list, so the ad-hoc app still prompts. A
  CLI test passed only because import + use in one process shares the partition
  implicitly — a fresh app launch (different cdhash) does not.
- A **dedicated keychain** via `SecPKCS12Import(kSecImportExportKeychain:)` —
  fails at import with -26276 (the legacy-PBE P12 the spike requires won't import
  into a freshly-created keychain that way).

**What WILL fix it:** Developer ID signing gives a **stable code identity**, so
one "Always Allow" (or a one-time `set-key-partition-list` with the stable Team
ID) sticks across all future builds — a one-time authorization, not a per-build
prompt; and the notarized product never shows it. Developer ID is a prerequisite
for the commercial plan anyway, so TLS completion is sequenced behind it. A
`security create-keychain` + `security import -A` + `set-key-partition-list`
(app-owned keychain with an app-known password) could make it prompt-free even
under ad-hoc signing, but that's fragile dev-only machinery for a problem
Developer ID retires — not worth it.

**Interim state (historical; resolved 2026-07-21):** committed 1.9.0 kept the HTTP listener + the ATS exemption
(`NSAllowsArbitraryLoads` in `ios/Info.plist`), so the phone works over LAN and
Tailscale on plain HTTP with HMAC auth as before. The HTTPS listener + pinning
are present but effectively dormant (a pinned phone would trip the prompt on the
Mac). Finish steps 5-6 after Developer ID.

Verification gotchas worth keeping (cost hours this session): a pairing captured
by a pre-pin iOS build stores a permanent no-pin record (re-pair is the only
fix; symptom "LAN works, Tailscale unreachable" because ATS exempts local nets
but blocks cleartext to 100.64/10); Safari cannot smoke-test :51848 — it
hard-fails the 10-year self-signed cert on system policy (>825-day limit) with
no tap-through (use `curl -4 -sk` from another Mac); and Mac-side `netstat`
proves only that a response was WRITTEN (bytes in the send queue), not
DELIVERED — get the peer's own confirmation before calling a transport verified.

## Why TLS at all

The agent is authenticated end-to-end (HMAC request + response signing, nonce
replay protection, per-phone secrets), so a LAN attacker **cannot forge or
tamper**. The only gap is **confidentiality**: `/stats` travels in cleartext, so
a LAN eavesdropper can *read* temperatures, memory, and the process list. TLS
closes that, and — the bigger driver — lets us drop the broad
`NSAllowsArbitraryLoads` ATS exemption that App Store review scrutinizes.

No domains, no CA, raw IPs / `.local` / Tailscale → a normal cert is impossible.
The design is **self-signed cert + public-key pinning**: the pin travels in the
pairing link (which already carries the shared secret), the phone pins it.

## What the spike PROVED (works)

1. **Cert generation with the system toolchain.** `/usr/bin/openssl` (LibreSSL,
   present on every Mac — NOT the Homebrew one) generates a self-signed cert +
   key and a P12. RSA-2048 used (see gotcha #1).

2. **Loading it as a TLS identity with no Keychain hang.** `SecPKCS12Import`
   returns `errSecSuccess` immediately (no approval dialog, no hang — the risk
   CLAUDE.md flagged for the agent secret did NOT bite here), yields a
   `SecIdentity` → `sec_identity_create` → `NWProtocolTLS.Options` via
   `sec_protocol_options_set_local_identity` → `NWListener` reaches `.ready`.

3. **Real handshake + pinning both directions.** `openssl s_client` completes the
   handshake and receives our cert; a `URLSession` server-trust delegate that
   hashes the leaf key **connects on the right pin (HTTP 200) and rejects a wrong
   pin (error -999)**. MITM protection confirmed.

## Gotchas the spike surfaced (must-dos, not optional)

1. **P12 cipher must be Apple-compatible or `SecPKCS12Import` CRASHES.** LibreSSL's
   default P12 encryption makes Security framework *crash* (not error) with
   "SecKeyCopyExternalRepresentation called with NULL SecKeyRef" — it can't
   extract the key. Fix: generate the P12 with legacy PBE —
   `-keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1`. With that, import
   is clean.

2. **Compute the pin the SAME WAY on both sides — Security framework, not openssl
   SPKI.** `SecKeyCopyExternalRepresentation` returns the *raw* key (PKCS#1 for
   RSA, X9.63 for EC), NOT the full SubjectPublicKeyInfo. Hashing openssl's SPKI
   (`x509 -pubkey | pkey -pubin -outform der | dgst`) produces a DIFFERENT value
   and the correct pin gets rejected. So the **Mac must compute the pairing-link
   pin via Security framework** — `SecCertificateCopyKey` →
   `SecKeyCopyExternalRepresentation` → `SHA256` → base64 — the identical bytes
   the iOS client extracts. (We control both ends, so a raw-key pin is fine; no
   need to reconstruct a standards-form SPKI.)

## What the spike did NOT verify (the remaining risk)

**Can we actually remove `NSAllowsArbitraryLoads` on iOS?** The pinning delegate
works with `URLSession` on macOS (same API iOS uses), but ATS enforcement differs
by platform, and the exemption-removal must be tested on an **iOS build/device
with the exemption removed, across all three transports** (LAN IP, `.local`,
Tailscale `100.64/10`). Expectation: HTTPS + a server-trust pinning delegate
satisfies ATS even for a self-signed cert, and real HTTPS resolves the
Tailscale-CGNAT block — but ATS with IP literals is finicky, so this is the one
thing left to confirm empirically before we can claim the exemption is gone.

## Implementation plan (in dependency order)

1. **`AgentIdentity` cert lifecycle (Mac).** On first pairing-enable, generate the
   self-signed identity (shell to `/usr/bin/openssl` with the PBE flags from
   gotcha #1) into `~/Library/Application Support/MinStats/` as a `0600` P12,
   alongside the existing secret. Reuse the key across cert renewals so the pin is
   stable. Expose `secIdentity()` and `pin()` (Security-framework method, gotcha
   #2). Long validity (10y) to avoid rotation.
2. **`StatsServer` TLS listener.** Swap `NWParameters.tcp` for
   `NWParameters(tls:)` with the identity. Keep everything else (HMAC, routing).
3. **Pairing link + `Auth.pairingURL`.** Add a `pin` query item. iOS
   `PairedDevice(pairingURL:)` parses it (optional — absent = old pairing).
4. **iOS `StatsClient`.** Switch scheme to `https://`; add a `URLSessionDelegate`
   server-trust handler pinning `device.pin` (gotcha #2 method). Keep HMAC.
5. **Transition.** For independent agent/phone updates: agent serves **both** HTTP
   and HTTPS during a transition window (or a second port); phone prefers HTTPS
   when it has a pin, falls back to HTTP when it doesn't (old pairing) — so no
   flag day. `/health` (the unauth version handshake) must stay reachable on
   whatever the phone can still speak. Retire HTTP in a later major version.
6. **ATS.** Remove `NSAllowsArbitraryLoads`; **verify on device** across LAN IP /
   `.local` / Tailscale (the open question above). If it won't cooperate, keep a
   narrowly-justified exemption.
7. **Rotation UX.** "Rotate secret" already exists; make it also regenerate the
   cert (keeping the key so pins survive) — or leave the cert alone and only
   rotate the HMAC secret. Decide.

## Effort / sequencing

Steps 1–4 are now low-risk (spike proved the mechanics). Step 5 (transition) is
the real product work. Step 6 (ATS) is the remaining unknown and should be
verified early on a device — ideally right after steps 1–4, before investing in
the transition, since a bad ATS result changes the calculus.
