# MinStats

Minimalist macOS menu bar app showing system temperature (headline), CPU, and RAM,
with per-metric top-process lists, fan RPM, and a detail popover. Personal project;
elegance and minimalism are explicit goals — prefer removing over adding.

## Build & run (Command Line Tools only — no Xcode required)

- `make run` — release build, assemble + sign `dist/MinStats.app` (ad-hoc by
  default; a maintainer sets a real Developer ID in gitignored `Local.mk` —
  and should, since stable code identity is what keeps the TLS key
  prompt-free and local-network TCC sticky; hardened runtime either way),
  install it to `/Applications` and relaunch from THERE (the SMAppService
  login item resolves to /Applications/MinStats.app — launching dist/ instead
  left a stale copy that every reboot silently regressed to)
- `make print` — CLI probe: dumps one sample of everything (raw sensors, display
  sensors, fans, CPU, top processes, RAM) without launching UI. Use this first when
  debugging samplers.
- `make dmg` — universal (arm64+x86_64 via per-arch `--triple` builds + lipo;
  SwiftPM `--arch` needs full Xcode, don't use it) installer at `dist/MinStats.dmg`
- `make icon` — regenerates `Support/AppIcon.icns` from
  `Support/AppIcon/GenerateIcon.swift` (steel hex nut, cold→hot ring drawn in
  CoreGraphics at each iconset size, no Xcode). The .icns is committed; only
  re-run when the artwork changes. `bundle`/`dmg` copy it into
  `Contents/Resources/`; `Info.plist` references it via `CFBundleIconFile`.
- `.build/release/MinStats --debug-popover` — auto-opens the popover 2s after
  launch and prints placement frames to stderr
- `.build/release/MinStats --serve` — headless agent (no menu bar UI) printing
  the pairing link; lets the whole wire API be curl-tested without Xcode
- `--register-login` / `--unregister-login` — toggle the SMAppService login
  item from the CLI (must be run from the INSTALLED bundle so SMAppService
  resolves to /Applications/MinStats.app)

### iOS companion — separate (private) repo

The iOS app consumes `MinStatsProtocol` from this repo as a SwiftPM
dependency; its source, Xcode project, and from-scratch setup guide live in a
private repository. Everything the phone speaks — routes, DTOs, the signing
contract — is fully specified here (`Sources/MinStatsProtocol/`, the Agent
sources, and the docs), so this repo alone is enough to audit the wire.

## Architecture (10-ish files, keep it that way)

- `Sources/PrivateIOKit/` — C target. `include/PrivateIOKit.h` declares the private
  IOHID event-system symbols (Apple Silicon temperature sensors, no root needed);
  `include/SMC.h` declares the AppleSMC user-client structs (fans). PrivateIOKit.h
  is the SwiftPM umbrella header — new headers must be #included from it.
- `Sources/MinStats/Samplers/` — one file per metric, all plain `final class`
  with `sample()`:
  - `TemperatureSampler` — private IOHID API. `sample()` returns raw sensors;
    `headline(from:)` = hottest die sensor; `displaySensors(from:)` condenses to
    4 summary rows (CPU die / Power delivery / SSD / Battery), drops tcal
    calibration keys, passes unknown names through raw.
  - `CPUSampler` — host_processor_info tick deltas; nil on first call.
  - `MemorySampler` — host_statistics64, Activity Monitor "Memory Used" formula.
  - `ProcessSampler` — libproc rusage deltas; returns (cpu, memory) top-N pools
    (`StatsModel` asks for 10 — the menu bar slices its own 3/5 off the top, the
    agent serves the whole pool so the phone's expandable lists can show 10);
    groups helper processes by owning .app bundle; CPU normalized to machine
    capacity (same scale as CPUSampler). Each top-N group carries `owned`
    (2.1.0) — every pid runs as this user, checked top-N-only via
    proc_pidinfo, lookup failure = not-owned (conservative) — serialized as
    optional `ProcessDTO.owned` so the phone can render system rows as data
    (a "system" tag, no kill affordance) instead of offering a kill that can
    only come back denied; nil from older agents keeps the old offer-and-
    refuse behavior. Two truths learned 2026-07-22: (1) unprivileged
    `proc_pid_rusage` FAILS on other users' pids, so the lists have only ever
    contained this user's processes — root daemons (mds_stores…) can never
    appear, their load shows only in the machine-level CPU%, and
    `owned: false` is a rare guard (vanished pid), not the common case;
    (2) a booted iOS Simulator runs USER-owned doppelgängers of system
    daemons (its own diagnosticd/locationd/geod) — don't "verify" ownership
    with `pgrep | head -1`, it may pick the other twin. Also: no CPU-fraction
    floor in the ranking — on a many-core idle Mac at a long refresh interval
    NOTHING crossed the old 0.0005 threshold and the empty CPU list read as
    a broken app; accumulation is threshold-free (costs nothing, the memory
    pass already resolves every name) and top-N surfaces the honest winners.
  - `FanSampler` — AppleSMC via IOConnectCallStructMethod. SMCParamStruct layout
    is load-bearing (must be the C-imported 80-byte struct; a Swift-native mirror
    packs to 76 and the kernel rejects it). Decodes flt (Apple Silicon) and fpe2
    (Intel) per key. Returns [] on fanless Macs (FNum key absent → SMC result 0x84).
- `Sources/MinStats/StatsModel.swift` — @MainActor @Observable; the sampling
  Task loop, all UserDefaults persistence (refreshInterval, useFahrenheit,
  menuBarMode, topProcessCount), `menuTitle` (UNPADDED with even gaps — the
  no-jitter guarantee moved to the status item's fixed `length`, sized from
  `menuTitleTemplate`; padding the string evened total width by making the
  gaps lopsided, 2.2.7), and `voiceOverSummary` (spoken label for the menu-bar
  item — the compact mode is an image with no readable text). The five samplers
  live on a background **`SamplingActor`** (same file): the loop `await`s
  `collect()` off the main thread and applies the returned Sendable `SampleSet`
  on the main actor, so the per-tick IOKit/libproc work (incl. a syscall per
  process) can't hitch the menu bar. The actor preserves each sampler's delta
  state across ticks.
- `Sources/MinStats/StatusBarController.swift` — AppKit NSStatusItem (deliberately
  NOT MenuBarExtra: it can't distinguish right-clicks). Left click = NSPopover with
  DetailView; right click = context menu (display mode, Fahrenheit, launch at login
  via SMAppService, Enable Phone Pairing, Pair iPhone…, quit). "Enable Phone
  Pairing" is the gate that starts/stops the agent; "Pair iPhone…" only appears
  once it's on. That item carries a state-aware `subtitle` (macOS 14.4+; guarded)
  — "Off — nothing on this Mac is shared" / "On — a paired iPhone can view stats
  & quit apps" — and **enabling** it pops a confirmation NSAlert spelling out
  what it grants (a network listener + remote app-quit, private-network-only,
  needs pairing); disabling is silent (always safe). Title updates via re-arming
  withObservationTracking.
  Popover is clamped below screen.visibleFrame.maxY so the notch can't clip it.
- `Sources/MinStats/DetailView.swift` — the popover content. NSPopover sizes
  content to its IDEAL size, so the sensor ScrollView derives an explicit height
  from row count (maxHeight alone collapses to one row). Background has a 0.55
  windowBackgroundColor wash over the vibrancy to keep contrast over busy
  backgrounds — that opacity is the translucency dial.
- `Sources/MinStats/AlertMonitor.swift` + `AlertsView.swift` — temperature
  alerting. `AlertMonitor.configDTO()`/`apply(_:)` are the phone-facing read/write
  (threshold + enabled; channel secrets never cross the wire — see the `/alerts`
  route). The iOS detail screen edits the same config remotely; the Mac's own
  `AlertsView` reflects it live since `AlertMonitor` is `@Observable`. `StatsModel.sampleOnce` calls `alerts.evaluate(headlineC:)` each tick;
  it fires when the die temp crosses a threshold, then holds off via hysteresis
  (re-arm only after cooling past a margin) + a 15-min cooldown. **No push
  service by design** — the Mac emits *outbound* to a channel the owner already
  has, so there's no relay, no credential held, nothing stored off the machine
  (works behind NAT and independent of phone pairing). **Webhook providers**
  (`AlertProvider` + `AlertSender`, agent 1.7.3): Discord (`content`), Slack
  (`text`), and ntfy (raw text → real push to your phone; bare topic expands to
  https://ntfy.sh/<topic>). Each formats its own payload — a single "generic
  URL" field would silently no-op since the payload key is service-specific.
  All https-only; endpoint stays Mac-side (never on the wire). iMessage was
  tried and dropped (1.7.1): it failed silently in too many ways while the UI
  reported success. `AlertMonitor.sendTest` is `async throws` and reports the
  ACTUAL outcome (`AlertSender.SendError`: notConfigured / unreachable /
  rejected). `AlertsView` = threshold + a service picker + endpoint + honest
  Send Test, from the right-click menu.
- `Sources/MinStats/main.swift` — entry point (main.swift + App.main() pattern,
  no @main). `--print` probe branch first, then NSApplication + AppDelegate.
- `Sources/MinStatsProtocol/` — Codable wire DTOs + `WireSignature` (the shared
  signing message) + `MinStatsProtocolVersion`, the ONE source of truth for the
  API, compiled into both the Mac agent and the iOS app (macOS+iOS platforms).
  Units are raw (Celsius, 0…1 CPU, bytes); clients format. **Versioning
  contract:** `MinStatsProtocolVersion.current` bumps ONLY on a breaking wire
  change; additive changes (new optional field / endpoint) stay backward-compat
  via optional DTO fields, `HealthDTO.capabilities`, and graceful 404 handling.
  The iOS app does a `/health` handshake on connect and, via
  `compatibility(agentProtocol:)`, shows a banner telling the user which side to
  update on a mismatch (so a version skew is never a silent failure). `/health`
  must stay backward-decodable forever — it's the handshake. `Tests/` pins both
  the signing format and the compatibility directions.
- `Sources/MinStats/Agent/` — the phone-facing agent, embedded in the menu bar
  app (it already owns the samplers and runs as the user, which is exactly the
  privilege control needs). **Opt-in: off by default.** `StatusBarController`
  only starts it when `phonePairingEnabled` is set (right-click → "Enable Phone
  Pairing"), so a fresh install exposes nothing on the network — no listener, no
  Bonjour — until the owner chooses to. Toggling off calls `server.stop()`,
  releasing the port and Bonjour. (`--serve` is unaffected: it's an explicit CLI
  opt-in.) The secret and existing pairings persist across toggles, so a paired
  phone reconnects the moment it's switched back on.
  - `StatsServer` — ONE NWListener: **HTTPS on 51848 + Bonjour** (agent 2.0.0,
    TLS-only since 2026-07-21 — the plain-HTTP listener on 51847 is RETIRED,
    TLS step 5). Self-signed identity from `AgentIdentity.tlsIdentity()`,
    pinned by the phone (iOS `PinningDelegate`) via the `pin` in the pairing
    link; the pin hashes the KEY, so cert renewals never force a re-pair.
    Bonjour rides the TLS listener — discovery is browse-only TXT metadata,
    the phone never dials an unpaired Mac. A pre-2.0 pin-less pairing gets
    connection-refused (the phone's "check pairing" hint); re-pairing is the
    whole migration. Rotation (TLS step 7, 2.2.1): per-phone "Revoke" keeps
    the TLS identity; **"Revoke all pairings" also rotates it** (new key →
    new pin, listener bounced, confirmation dialog spells it out) — the full
    trust reset for a leaked QR or key. `AgentIdentity.tlsEnabled` is the
    kill-switch — MUST be
    false under ad-hoc signing (per-rebuild cdhash → a Keychain password
    prompt per handshake no remote peer can answer; history in
    ENGINEERING-NOTES.md, private) — and with it false the agent does not serve at all.
    Step 6 resolved AGAINST removing the ATS exemption (see the ATS caveat
    below). Cert lifecycle + the two spike gotchas (legacy P12 PBE,
    Security-framework pin) are in `AgentIdentity`. Serves
    `StatsModel.snapshot()` — the sample the menu bar ALREADY took, so a
    polling phone costs zero extra IOKit work. Connections are handled off-main
    on a dedicated serial queue (only routing hops to the main actor), capped
    at 16 concurrent with a 10s per-connection deadline — held-open sockets
    can't pin slots or jank the menu bar. Routes: `GET /health` (unauth),
    `GET /stats` (signed), `GET`/`PUT /alerts` (signed; the phone reads/writes
    the temperature-alert config — enabled + threshold only, NEVER the channel
    secrets), `POST /control/kill` (signed + private-peer). `/alerts`
    is config not control, so it's signed but NOT private-peer-gated —
    deliberately Tailscale-reachable; the Mac stays the source of truth and
    clamps the threshold (30–120 °C) on write. `/control/*` is refused unless
    the peer is RFC1918/link-local/loopback/100.64.0.0/10 (Tailscale CGNAT) —
    the code-level guarantee that a kill is never internet-reachable.
    **`/control/restart` was REMOVED (2.2.0, 2026-07-22)**: on a FileVault Mac
    a remote restart strands the machine at pre-boot unlock (no agent, no
    Tailscale — worse than the sickness it would cure), the osascript request
    was vetoable with no honest success signal, and the path was untested by
    design. Old phones get the graceful 404; capabilities no longer lists it.
  - `Auth` — HMAC-SHA256 signing over `METHOD\nPATH\nTS\nNONCE\nsha256hex(body)`.
    The signed *message* is built by `WireSignature` in `MinStatsProtocol` — the
    ONE shared function both the agent and `ios/MinStats/StatsClient.swift` call,
    so they can't drift (was two hand-kept copies that 401'd everyone if they
    diverged). `Tests/MinStatsProtocolTests` pins the exact format. Only the HMAC
    *key* differs per side. 60s skew window + 120s nonce cache (replay). Nonce is burned only
    AFTER the signature validates. **Responses are signed too** (agent 1.4.0+):
    authenticated routes return `X-MinStats-Signature`, HMAC over
    `RESPONSE\n<request nonce>\n<sha256hex(body)>`, so a LAN impostor can't
    spoof stats/kill results to the phone. The phone REQUIRES it on any signed
    200 — update Macs before the phone, or the phone shows "reply couldn't be
    verified" against a pre-1.4 agent. **Per-phone secrets** (1.5.0+):
    `X-MinStats-Key` carries the *client* id and `ClientStore` holds one
    secret per paired phone — the pairing QR offers an unclaimed slot, a
    phone's first verified request claims it (a fresh slot is minted), and
    the pairing window revokes any one phone alone. The pre-1.5 shared
    secret migrates in as a claimed legacy client under the Mac's device id,
    per UserDefaults domain (app and `--serve` have different ids), so
    existing pairings keep working with zero action. Phones self-report a
    display name (1.6.0+, `X-MinStats-Client-Name`, percent-encoded; recorded
    only after the signature verifies) — the hardware id ("iPhone17,3"),
    because iOS 16+ gates the personal name behind an entitlement needing a
    paid account; the code auto-upgrades to it if that ever lands.
  - `HTTP` — a deliberately tiny HTTP/1.1 subset (no dependency).
  - `Control` — kill (restart removed in 2.2.0 — see the routes note), all
    UNPRIVILEGED as the logged-in user by
    design (enough for your own apps; root-owned processes return `denied`,
    never escalate — no privileged helper). A kill target is a whole process
    *group* (one .app = a main process + its helpers, all folded under the
    bundle name). Kill quits the **app once** via `NSRunningApplication.terminate()`
    (a real Cmd-Q so it can save) and lets macOS tear the helpers down with it;
    it deliberately does NOT signal the helper pids. Signalling them directly is
    what SIGTERM'd Brave's renderers and left crashed "Error code 15" tabs while
    the browser stayed up — verified & fixed 2026-07-16. Only genuinely app-less
    groups (daemons, CLI tools like `yes`) get a direct SIGTERM/SIGKILL. The
    pid-reuse interlock re-resolves
    each pid via `ProcessSampler.displayName` (shared static — both sides MUST
    derive names identically) and refuses on mismatch.
- `ios/MinStats/` — the companion app. `StatsClient` (signing + route racing),
  `DeviceStore` (+ iOS Keychain for secrets — stable code identity here, unlike
  the Mac), `Discovery` (NWBrowser), `DeviceMonitor` (polls at the Mac's own
  interval, foreground only), `MonitorPool` (owns one `DeviceMonitor` per Mac so
  `DeviceListView` can pull-to-refresh them all at once, and a row + its detail
  screen share a single monitor rather than each polling its own),
  `DeviceDetailView`/`StatBars` (the ported design language), and
  `DiagnosticsMonitor` (MetricKit).
  - **Crash visibility (`DiagnosticsMonitor`).** A process-lifetime MetricKit
    subscriber (registered from the app's root `.task`) persists crash/hang
    diagnostic payloads as JSON on-device (newest 15). Settings offers a
    ShareLink to send them — **user-initiated, never auto-uploaded** (same
    no-relay ethos as alerts). Xcode Organizer is the eventual central view once
    on the App Store; this works on any build today. NOTE: MetricKit delivers
    only on a real device, aggregated ~once/24h — never in the Simulator.
  - **Offline UX.** A poll failure is classified into an actionable reason
    (`StatsClient.offlineHint`): a refused socket → "MinStats isn't answering,
    check pairing"; a timeout → "asleep / off-network / VPN dropped". The list
    row shows a short form, the detail screen a full banner. Confirmed-offline
    (past the 2-poll grace, or an explicit refresh) **clears the last sample** —
    stale stats with live kill buttons read as current and invite acting on gone
    pids. Pull-to-refresh flips to "Connecting…" and resolves immediately (no
    grace — the tap is an explicit "try now").

## Verification

After sampler changes: `make print` and sanity-check (idle M2 die temps ~35-55°C;
RAM within a few hundred MB of Activity Monitor). Thermal test: 4× `yes >/dev/null &`
for 20s → die temps +10-15°C, CPU ~50%+; kill the hogs after (pkill -x yes).
After UI changes: `make run` and eyeball the popover. App must never show a Dock
icon (LSUIElement in Support/Info.plist).

## Known caveats / decisions

- Temperature uses PRIVATE APIs → App Store is off the table (sandbox also blocks
  it). Distribution path is Developer ID + notarization. **Developer ID signing
  is live (2026-07-21, team X5UDV422D8 — the personal team upgraded in place, so
  no iOS project changes were needed); notarization is not yet set up**, so
  downloads on other Macs still need right-click→Open once, or
  `xattr -d com.apple.quarantine`. The `dmg` target already signs with
  `--timestamp` (required by notarization; needs network, so dev `bundle`
  builds omit it).
- **Intel Macs: not supported, by decision (2026-07-19).** The binary runs
  (universal) and fans work, but temperature enumeration via IOHID returns
  little/nothing — the headline feature — and Intel temps would need SMC keys
  (TC0P etc.), which won't be implemented. Market/list MinStats as **Apple
  Silicon only** so no one pays expecting Intel temps.
- Fan decoding: the `flt` path is VERIFIED on real hardware (Mac mini, Mac16,11,
  2026-07-14) — reads a single fan at ~1000 rpm idle and renders as "Fan" on the
  phone. The `fpe2` (Intel) path remains untested; no Intel Mac available.
- `displaySensors` omitting absent hardware is verified both ways: the fanless
  Air shows no fan rows, and the battery-less mini shows no Battery row (rather
  than a misleading 0°).
- swift-format/linters not set up; match existing style manually.
- Per-phone client secrets live in a **0600 file** (`~/Library/Application
  Support/MinStats/agent-clients`, JSON), NOT the Keychain. The Keychain ACL
  binds to code identity; ad-hoc signing changes it every rebuild, so
  `SecItemCopyMatching` *blocks forever* on an approval dialog a headless
  agent can't show — a hang, not an error. Also: the secrets only authorize
  quitting apps, i.e. strictly less than any
  same-user process can already do. Revisit once Developer ID signing
  stabilises code identity. The old single-secret `agent-secret` file is kept
  until its legacy client is revoked (revocation deletes it, or migration
  would resurrect it next launch).
- **Don't diagnose agent latency with plain `curl` across subnets.** Against a
  host with no IPv6 route, curl tries an IPv4-mapped IPv6 address and burns a
  full 5s timeout before falling back — looking exactly like a 5s server stall.
  It cost a wrong diagnosis and a pointless "fix" once. Use `curl -4`, or better
  a URLSession probe, which does Happy Eyeballs like the iOS app (same request:
  curl 5.04s vs URLSession 0.084s vs agent's real 0.02s).
- `/health` reports `agent` (SystemInfo.agentVersion) — bump it on any change
  worth identifying remotely. It's what proved an update had landed while the
  symptom persisted, which is what exposed the misdiagnosis above.
- Local-network TCC is keyed to code identity too — stable now under Developer
  ID signing (under ad-hoc, every rebuild could re-prompt or silently drop the
  permission; expect ONE re-prompt on the first post-switch LAN connection). `NSLocalNetworkUsageDescription`
  + `NSBonjourServices` are mandatory on macOS 15+ or the listener silently
  fails — hence `NWListener.stateUpdateHandler` logging its state.
- **iOS ATS treats the Tailscale range as public internet** — and *only* that
  range. ATS exempts `.local` and RFC1918 (so LAN routes always work) but on
  `100.64.0.0/10` (RFC6598 CGNAT) it stays fully in force, and this bites BOTH
  transports: plain HTTP is refused outright, and (verified on device
  2026-07-21) even the pinned HTTPS handshake is killed with -1200 *after*
  `PinningDelegate` approves the trust — ATS's certificate policy (the
  self-signed 10-year cert) is not delegate-overridable. Safari (ATS-exempt)
  loads the same URLs fine, which makes both failures masquerade as network
  problems. Fix: `NSAllowsArbitraryLoads` in `ios/Info.plist`, kept
  deliberately (TLS step 6 verdict) — it can't be narrower (exception domains
  can't take raw IPs; `NSAllowsLocalNetworking` excludes CGNAT) and it removes
  no real security (every route is pinned TLS + HMAC-signed both ways). The
  path to someday dropping it: an ATS-compliant short-validity cert renewed on
  a stable key (the pin hashes the KEY, so renewals don't re-pair). This is
  *the* reason "works on Wi-Fi, offline on cellular" points at ATS, not the
  tunnel.
- **Reads race the routes; control is sequential.** Off the LAN, trying routes
  one-by-one meant each dead route (`.local` that won't resolve, a bounced
  tailnet) burned a full timeout before the next — ~3 routes × 5s × the 2-poll
  grace hung "Connecting…" ~45s before Offline. So GET (`/health`, `/stats`)
  **races every route at once** and takes the first definitive answer — a poll
  resolves in ~one timeout, and on success it returns the instant the working
  route replies. Each parallel signed request gets its **own nonce**, so several
  routes reaching the same Mac can't trip the replay cache. The race is
  **staggered** (agent app 1.5.0-era): the learned last-good route gets a 1.5s
  head start, and in the healthy steady state the sleepers are cancelled before
  they touch the network — a poll costs ONE request instead of one per route
  (the battery win), while a stale route only delays the full race by the head
  start. Control (POST) stays
  **sequential** — racing a kill would fire it down every route. `StatsClient`
  still persists the last-good host (used to order the sequential control path);
  paired with the offline *grace* (ride out a dropped poll or two) this is what
  makes remote usable on spotty cellular.
- **App lock fails open with no passcode.** The optional Face ID / passcode lock
  (`AppLock`, off by default) uses `.deviceOwnerAuthentication`; with no device
  passcode there's nothing to evaluate, so it unlocks rather than trapping the
  owner out (and the setting is offered disabled). `NSFaceIDUsageDescription` is
  mandatory or Face ID throws. It locks the *whole* app on foreground and its
  opaque cover doubles as the app-switcher snapshot.

