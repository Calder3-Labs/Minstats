# MinStats

A minimalist macOS menu bar system monitor — and a secure companion app to watch (and lightly control) your Macs from your iPhone, from anywhere.

<p align="center">
  <img src="docs/screenshots/panel.png" alt="MinStats menu bar panel" width="300">
</p>

Most system monitors show you everything. **MinStats shows you the vital few — temperature, CPU, RAM — beautifully**, and nothing you'll never read. It started as a menu bar app because I couldn't find an elegant one. It grew a phone companion because I wanted the same glance after I walked away from the machine.

The numbers it lives by:

- **Zero third-party dependencies.** Both apps. The supply chain is Apple's SDK — IOKit, Network.framework, CryptoKit, SwiftUI — and nothing else. For software whose pairing credentials can quit apps on your Mac, that isn't minimalism for its own sake; it's the trust model.
- **1.4 MB installer, ~1 MB universal binary.** The running app idles at ~47 MB RAM and 0.0% CPU — and ranks *itself* honestly in its own process list.
- **No backend, no account, no telemetry.** Your phone talks to your Mac directly — over your Wi-Fi or your own VPN (Tailscale just works). There is no server to breach and nothing leaves your devices.

## Two parts, one design language

| | **MinStats** (macOS) | **MinStats** (iOS companion) |
|---|---|---|
| Lives in | the menu bar (no Dock icon, no window) | your pocket |
| Shows | temperature · CPU · RAM · top processes · fans | the same, for every paired Mac |
| Also does | temperature alerts, launch at login, °C/°F, refresh rate | remotely quit an app — behind Face ID if you like |
| Talks over | — | pinned TLS + mutually HMAC-signed requests |

The iPhone can't read another Mac's sensors, so the menu bar app doubles as a tiny **agent**: it already samples everything and runs as you, so it serves that same sample to a paired phone — costing zero extra sampling per poll. The agent is **off by default**; nothing listens until you enable Phone Pairing, and the menu spells out exactly what that grants before it starts.

## Highlights

**macOS app**
- **Headline die temperature** — the hottest CPU/SoC sensor, read via Apple's private IOHID API (no root)
- **Cold→hot gradient bar** — the temperature's position at a glance
- **Top processes** by CPU and by memory, grouped by app (Chrome's dozen helpers collapse to one line, with every PID tracked so "quit" quits the whole app), with adaptive precision that never shows a lying `0%`
- **Temperature alerts with no backend**: when the Mac runs hot, it messages a webhook *you* control — Discord, Slack, or [ntfy](https://ntfy.sh) (real phone push, no account). Hysteresis + cooldown so it alerts once, not forty times
- **Fan RPM** via the SMC, and a condensed sensor summary that hides absent hardware (no fan rows on a fanless Air, no battery row on a mini)
- Compact / extended menu bar modes, °C/°F, 2/5/10/30 s refresh, launch at login

**iOS companion**
- Pair by scanning a QR — that one scan carries the address, the credential, *and* the TLS certificate pin
- A device list of all your Macs; a detail screen porting the Mac's visual language
- **Works away from home** over Tailscale/WireGuard, on spotty cellular: reads race every route in parallel and take the first verified answer
- **Remote quit** for runaway apps — always behind a confirmation, optionally behind Face ID; processes the agent *couldn't* kill are shown as data with a quiet "system" tag instead of a button that would only fail
- Honest offline states: the app tells you *why* a Mac is unreachable and clears stale stats rather than showing dead processes with live buttons
- System / Light / Dark appearance, and a built-in Connection Log for diagnosing your own network without a cable

## How it works

```
┌─────────────────── your Mac ───────────────────┐          ┌──── your iPhone ────┐
│  Samplers (IOKit / SMC / Mach)                 │          │                     │
│     ↓                                          │          │   Discovery (mDNS)  │
│  StatsModel ──snapshot()──▶ Agent (NWListener) │◀────────▶│   StatsClient       │
│                             · pinned TLS       │  HTTPS   │   · pins the cert   │
│                             · Bonjour advert.  │  + HMAC  │   · signs every     │
│                             · HMAC verify      │  (both   │     request         │
│                             · control (kill)   │   ways)  │   SwiftUI views     │
└────────────────────────────────────────────────┘          └─────────────────────┘
            shared wire contract: MinStatsProtocol (compiled into both)
```

- **Sensors.** Temperature comes from the private IOHID event-system API (the same approach Stats/macmon use — no public API exists). Fans come from the SMC. CPU/RAM use Mach kernel calls, with memory computed the way Activity Monitor's "Memory Used" is.
- **One source of truth.** The wire format — and the exact bytes both sides HMAC-sign — lives in a shared `MinStatsProtocol` package compiled into *both* apps, with tests pinning the format. The contract can't drift.
- **Versioned by handshake.** The phone checks `/health` on connect; on a mismatch it tells you *which side* to update instead of failing silently.

## Security model

Because the phone can *control* the Mac, auth is front-loaded, not bolted on — and the properties below aren't just claimed: **CI re-proves them on every push** ([`scripts/wire-smoke.py`](scripts/wire-smoke.py) drives the real agent through TLS handshake, mutual signing, replay rejection, and the forged-signature-must-not-burn-a-nonce rule on a bare runner).

- **Transport: pinned TLS.** The agent serves HTTPS with a self-signed certificate whose key-based pin travels *out-of-band* in the pairing QR. Private IPs and `.local` names can't get CA certificates — pinning is the correct trust model here, and stricter than the CA model for a closed two-party system: the phone verifies *this exact Mac*, not "someone who once controlled a DNS name."
- **Every request is HMAC-SHA256 signed** over `METHOD\nPATH\nTIMESTAMP\nNONCE\nSHA256(body)` — and **every response is signed back**, bound to the request's nonce. Neither direction can be spoofed by a LAN impostor, even before TLS is considered. Secrets never cross the wire.
- **Per-phone secrets, per-phone revocation.** Each paired phone holds its own credential. Revoke one phone and no other phone notices; **Revoke All** is a full trust reset that also rotates the TLS identity — nothing captured beforehand survives it.
- **Replay-protected**: a 60-second skew window plus a nonce cache, with the nonce burned only *after* the signature validates.
- **Control is network-scoped in code**: kill requests are refused unless the peer is on a private address (RFC1918 / link-local / loopback / Tailscale's CGNAT range) — unreachable from the public internet regardless of router configuration.
- **Honest privilege limits**: everything runs unprivileged as the logged-in user. Killing your own apps works; root processes return `denied`, never escalate — there is no privileged helper. Remote *restart* was removed entirely rather than shipped untestable: on a FileVault Mac it would strand the machine at the pre-boot unlock screen, and a "recovery" tool that needs physical recovery isn't one.
- **Design-by-removal**: features that couldn't fail *honestly* were deleted, not patched — iMessage alerting (failed silently while reporting success) and remote restart (above) are gone; unkillable processes show no kill button rather than one that errors. The pin hashes the *key*, not the certificate, so future cert renewals never invalidate a pairing.

## Build & run

**macOS** — needs only the Command Line Tools, no Xcode:
```sh
make run          # build, bundle, sign (ad-hoc by default), install, launch
make print        # dump one sample of everything to the terminal (no UI)
make serve        # run the agent headless — the whole API, curl-testable
make dmg          # universal installer at dist/MinStats.dmg
```
(Signing defaults to ad-hoc, which is all a machine you own needs. A
distributor sets a real Developer ID in a gitignored `Local.mk`.)

**iOS** — needs Xcode. See [`ios/SETUP.md`](ios/SETUP.md) for the full from-scratch guide (physical device and every gotcha that cost hours).

## Requirements

- **Apple Silicon Mac, macOS 14+.** Intel Macs run the binary (it's universal) and fans work, but the temperature enumeration this app exists for returns nothing useful on Intel — so treat it as Apple Silicon only.
- iPhone with iOS 17+ for the companion.

## Project layout

```
Sources/
  PrivateIOKit/        C shim for private IOHID + SMC symbols
  MinStatsProtocol/    Codable wire DTOs + the shared signing contract
  MinStats/
    Samplers/          Temperature, CPU, Memory, Process, Fan
    Agent/             StatsServer, Auth, HTTP, Control
    StatsModel · StatusBarController · DetailView · AlertMonitor · main
ios/MinStats/          the SwiftUI companion app
Support/               Info.plist, app icon + generator
Tests/                 pins the wire-signature format + version compatibility
docs/                  screenshots
```

## Status

**Working and verified on real hardware, at home and away** — multiple Macs paired, live stats and app-quit from the phone over cellular + Tailscale on pinned TLS. Signed with Developer ID; notarization is the remaining distribution step.

Known honest limitations: Intel temperatures are unsupported by decision; the iOS app keeps a broad ATS exemption because ATS rejects self-signed certificates on VPN routes even when the pinning delegate approves them — verified on device, with a documented exemption-free path (short-lived certificates renewed on a stable key, so pins survive) if it's ever needed.

## License

**GPL-3.0** ([LICENSE](LICENSE)) for the app and agent — derivatives stay
open. **MIT** for the wire contract
([`Sources/MinStatsProtocol/`](Sources/MinStatsProtocol/LICENSE)) — build any
client you like, under any license, no strings. Copyright © 2026 Calder3 Labs.
