# MinStats security hardening — a learning walkthrough

This document explains the security and performance work done on the MinStats
agent and iOS companion in July 2026 (agent **1.3.1 → 1.6.0**). It's written to
*teach*, not just to record: each fix names the underlying concept, shows why
the old code was wrong, and points at the file that changed. Read it top to
bottom and you'll have a working mental model of how the phone↔Mac channel is
secured.

If you just want to cut a new build, skip to [Building a new
version](#building-a-new-version) at the end.

---

## 1. The mental model: what are we actually defending?

Before any fix makes sense, you need the threat model — *who* might attack,
*from where*, and *what they'd gain*.

MinStats runs an HTTP agent on your Mac (port 51847) that a paired iPhone polls
for stats and can send `kill`/`restart` commands to. So the asset being
protected is **control of your Mac**, and the attackers worth worrying about
are:

- **A passive eavesdropper on the same network** (coffee-shop Wi-Fi) — can they
  read your process list, or capture something reusable?
- **An active attacker on the same network** — can they *impersonate* your Mac
  to your phone, or impersonate your phone to your Mac? (On a LAN, ARP spoofing
  makes this realistic, not theoretical.)
- **The public internet** — can `restart my Mac` ever be reached from outside?
- **Someone who gets hold of a pairing link** — for how long, and how widely,
  does that one secret grant control?

Two design choices frame everything else:

1. **There is no TLS.** The agent speaks plain HTTP. Security comes from
   *message authentication* (HMAC signatures), not *transport encryption*. This
   is a deliberate trade for a personal tool with no server and no certificate
   authority — but it means we must think carefully about what a signature does
   and doesn't protect (it authenticates, it does **not** hide).
2. **The agent runs unprivileged, as you.** It can quit *your* apps and *ask*
   for a restart — nothing a process already running as your user couldn't do.
   There's no root helper, by design. So the boundary we're hardening is "can an
   *unauthorized party* reach these actions," not "can these actions do
   privileged things" (they can't).

Keep those two in mind; several fixes are only sensible in that light.

---

## 2. HMAC request signing (the pre-existing foundation)

This existed *before* the hardening work, but you can't understand the fixes
without it.

**Concept — HMAC (Hash-based Message Authentication Code).** A keyed hash. Both
sides share a secret key; the sender computes `HMAC(key, message)` and attaches
it. The receiver recomputes it and compares. If they match, the message came
from someone who holds the key *and* wasn't altered in transit. Crucially, the
secret **never travels** — only the derived code does.

MinStats signs a *canonical string* built from the request, not the raw bytes:

```
METHOD \n PATH \n TIMESTAMP \n NONCE \n sha256hex(body)
```

Every field matters:

- **method + path** — so a signature captured for `GET /stats` can't be replayed
  as `POST /control/kill`.
- **timestamp** — requests outside a ±60s window are rejected (limits how long a
  captured request stays valid).
- **nonce** — a random one-time value; the agent remembers used nonces for 120s
  and rejects repeats. This is the **anti-replay** mechanism: even within the
  60s window, a captured request can't be sent twice.
- **sha256hex(body)** — binds the exact body, so a kill payload can't be swapped
  under a valid signature.

**Two subtleties worth internalizing:**

- **Constant-time comparison.** The code uses
  `HMAC.isValidAuthenticationCode(...)`, not `==`. Comparing secrets with `==`
  leaks *where* the first mismatched byte is via timing, which can let an
  attacker recover a valid code byte-by-byte. Always compare MACs in constant
  time.
- **Burn the nonce only *after* the signature validates.** If you recorded the
  nonce first, an attacker could send garbage with a *victim's* nonce and "use
  up" that nonce, blocking the legitimate request (a denial-of-service on
  replay protection). Order matters.

> Files: `Sources/MinStats/Agent/Auth.swift` (verify),
> `ios/MinStats/StatsClient.swift` (sign). The two **must stay byte-identical**
> in how they build the signing string, or every request 401s.

---

## 3. Fix: harden the HTTP parser (1.4.0)

**The bug.** The hand-rolled HTTP parser read `Content-Length` like this:

```swift
let expected = Int(headers["content-length"] ?? "0") ?? 0
// ...
buffer.subdata(in: bodyStart..<(bodyStart + expected))
```

Send `Content-Length: -1` and `expected` is negative, so the range's upper bound
falls *below* its lower bound — an invalid `Range`, which is a **hard crash** in
Swift. And because the agent is embedded in the menu-bar app, that one request
takes down the whole UI.

**Concept — never trust length fields from the wire; validate before you index.**
This is a classic parser vulnerability class. A length/offset from untrusted
input must be range-checked *before* it's used to slice a buffer. The check is
one line:

```swift
guard let expected = Int(headers["content-length"] ?? "0"),
      (0...(256 * 1024)).contains(expected)
else { return nil }
```

**Why this one was urgent.** It required *no* authentication — the crash happens
during parsing, before signature checks. Any peer who could open the port could
kill your app on demand. That's the difference between a *pre-auth* and
*post-auth* bug, and it's why this jumped the queue.

> File: `Sources/MinStats/Agent/HTTP.swift`. Verified by replaying
> `Content-Length: -1` against a live agent: dropped, agent survived.

---

## 4. Fix: sign *responses*, not just requests (1.4.0)

**The gap.** Authentication was **one-directional**. The phone proved itself to
the Mac, but *nothing proved the Mac to the phone*. So an active attacker on the
LAN could impersonate your agent: feed your phone fake stats, fake "kill
succeeded" results, or (worse) get itself remembered as the working route.

**Concept — mutual authentication.** If both parties must be sure of each other,
*both directions* need to be authenticated. We already had the machinery (HMAC +
the shared secret), so the fix is symmetric: the agent signs its response body
too.

```
X-MinStats-Signature = HMAC(secret, "RESPONSE\n" + requestNonce + "\n" + sha256hex(body))
```

**Why bind it to the request's nonce?** Without that binding, a valid response
captured once could be **replayed** as the answer to a *different* request. The
nonce is unique per request, so tying the response signature to it means a
captured response is only ever valid for the exact request that produced it.
(Notice the `RESPONSE\n` prefix too — it *domain-separates* response signatures
from request signatures so one can never be mistaken for the other.)

**Client behavior — fail safe, but don't over-react.** The phone now *requires*
a valid signature on any signed 200. But an unverified reply doesn't immediately
mean "offline": the iOS client races several network routes at once (see §8), so
one impostor answering on one route shouldn't drown out the real Mac answering on
another. An unverified response is kept as a *non-definitive* outcome — the race
continues — and only surfaces as an error ("the reply couldn't be verified") if
*no* route produces a genuine answer.

**Deployment consequence.** Old agents don't sign, so an updated phone reads them
as unverified. **Update Macs before phones.** This is the general rule whenever
you tighten what a client *demands*: roll out the server side first.

> Files: `Auth.swift` (`responseSignature`), `StatsServer.swift` (`signed(...)`),
> `StatsClient.swift` (`verifiedResponse`).

---

## 5. Fix: listener hygiene (1.4.1)

Three related resource-exhaustion / responsiveness issues in the connection
layer.

**a) Cap concurrent connections.** There was no limit, so a peer could open
sockets endlessly, each leaking a connection object and its receive loop. Fix: a
hard cap (16); connections beyond it are refused before they start.

**b) Per-connection deadline.** A peer could open a socket and send *one byte*,
holding a slot forever (a classic **slow-loris** style attack). Fix: every
connection is cancelled 10s after it opens if it hasn't completed its exchange —
which also reaps half-sent junk the parser never finishes.

> Concept — *bound every resource a remote party can consume.* Connections,
> memory per connection (the 256 KB cap from §3), and *time*. Any unbounded one
> is a denial-of-service lever.

**c) Get networking off the main thread.** The listener and all parsing ran on
the app's main (UI) thread, so a burst of connections would jank the menu bar.
Fix: a dedicated serial `DispatchQueue` handles accept/receive/parse; only the
final *routing* hops to the main actor (where the samplers and control actions
live). A serial queue also means the connection counter needs no lock — only one
thread touches it.

> Swift-6 note: `static` members of a `@MainActor` class inherit that isolation.
> The queue and constants had to be marked `nonisolated` to be usable from the
> off-main connection callbacks.

> File: `StatsServer.swift`.

---

## 6. Fix: confirmed pairing links + dead-code removal (1.4.1)

**The hijack.** Tapping a `minstats://pair?...` link called `store.add()`
directly, and `add()` *replaces* any device with the same id. Device ids are
**public** — they're broadcast in the Bonjour TXT record and returned by
`/health`. So a crafted link carrying *your* Mac's id but an *attacker's* host
and secret would, on one tap, silently repoint your phone at an impostor (which
§4's gap then made fully impersonable).

**Concept — a security-relevant, destructive action needs explicit consent.**
"Silently apply data that arrived from outside" is the anti-pattern. The fix: a
confirmation alert naming the Mac and its host, with an extra warning when it
would *replace* an existing pairing. The paste-into-sheet path stays
friction-free because that's already a deliberate act by the user.

**Bonus — deleting `DeviceStore.updateHost`.** This was dead code that would have
rewritten a paired Mac's address from *unauthenticated* Bonjour data if it had
ever been wired up. Removing unused code that handles untrusted input is a real
security win: attack surface you don't have can't be exploited.

> Files: `ios/MinStats/DeviceListView.swift` (`.onOpenURL` + alert),
> `ios/MinStats/DeviceStore.swift` (removal).

---

## 7. Fix: stop leaking, and stop persisting, secrets (1.4.2)

Three separate "information-at-rest / over-exposure" fixes.

**a) Trim `/health`.** It was unauthenticated (so a phone can list a Mac before
pairing) but returned your OS version, agent version, **and your Tailscale/LAN IP
addresses** — to *any* peer on *any* network the Mac joins. That's
**fingerprinting**: handing an attacker a map of your private network for free.
The iOS app never even read those fields (the routes travel in the pairing link).
Fix: `/health` now returns only what Bonjour already broadcasts (id, name,
model, protocol) plus the agent version (kept because it's genuinely useful for
"did my update land?" and reveals little).

> Concept — *minimize what an unauthenticated endpoint discloses.* Every extra
> field is free reconnaissance. Default to the least information that still does
> the job.

**b) Pasteboard hygiene for the pairing link.** The link *is* a bearer
credential — whoever holds it controls the Mac. "Copy pairing link" put it on the
clipboard, where **Universal Clipboard** syncs it to all your nearby Apple
devices and clipboard managers archive it indefinitely. Fixes: mark the entry
with the `org.nspasteboard.ConcealedType` hint (respecting clipboard managers
won't store it), and auto-clear it after 60s — but only if it's *still ours*
(guarded by `changeCount`, so we never wipe something you copied since).

> Concept — treat credentials as *ephemeral*. A secret that lingers in a
> convenient place (clipboard, logs, a chat transcript) is a secret you've
> effectively published.

**c) Storage permissions.**
- **Mac:** the secret file is now created `0600` *atomically* via
  `createFile(atPath:contents:attributes:)`. The old write-then-`chmod` left a
  brief window where the file existed with default (umask) permissions — a
  **TOCTOU**-flavored gap where another local user could read it.
- **iOS:** the Keychain item is now
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. `ThisDeviceOnly` means the
  secret is excluded from encrypted backups, so it can't be restored onto a
  *different* device.

> Files: `Auth.swift`, `PairingView.swift`, `DeviceStore.swift`, `DTO.swift`.

---

## 8. Fix: per-phone secrets + the battery win (1.5.0)

**Per-phone secrets — the revocation problem.** Originally *every* paired phone
shared *one* secret. So you couldn't revoke a single phone; rotating the secret
kicked *all* of them. That's a real gap the moment more than one device (or
person) pairs.

**Concept — principle of least privilege + independent credentials.** Each
client should hold its *own* credential so it can be reasoned about — and
revoked — independently. The redesign:

- `ClientStore` holds one `{id, secret, claimedAt, name}` per phone in a `0600`
  JSON file.
- The pairing QR always offers an **unclaimed** slot. A phone's *first verified
  request* "claims" it, and a fresh slot is minted for the next phone — so
  pairing two phones back-to-back just works, and a QR is never re-offered once
  used.
- `X-MinStats-Key` now carries the *client* id; the agent looks up that client's
  secret to verify. **Revoke one phone → its next request 401s, nobody else
  notices.**

**Migration — don't break existing users.** An install that paired under the old
single secret still works: on first launch of 1.5.0 that secret is imported as a
*claimed legacy client* keyed by the Mac's device id (which is exactly what those
old phones sign with). Zero action required. This is the general lesson for any
credential-format change: **provide a migration path that's invisible to the
user.**

**The battery win — staggered route racing.** Background: off the LAN, the iOS
client tries multiple routes to reach the Mac (`.local`, Tailscale IP, LAN IP).
It had been *racing all of them at once* on every poll — great for latency, but
it means ~3 simultaneous requests every few seconds, tripling radio wakeups
(battery) and agent load. The fix keeps the latency but cuts the waste: the
known-good route (learned and persisted) gets a **1.5s head start**; the other
routes only fire if it hasn't answered by then. In the healthy steady state the
sleepers are cancelled before they ever touch the network — **one request per
poll instead of three** — while a genuinely stale route only costs the head-start
delay, once.

> Concept — *optimize the common case without breaking the worst case.* The
> healthy path (known route works) becomes cheap; the unhealthy path (route
> changed) is no worse than a small delay before falling back to the old
> race-everything behavior.

> Files: `Auth.swift` (`ClientStore`), `StatsServer.swift`, `PairingView.swift`,
> `StatsClient.swift`, `DeviceStore.swift`.

---

## 9. Feature: show the running version (menu + Get Info) & the `/Applications` fix

**Version visibility.** "Which build is this Mac running?" should be answerable
without curling `/health`. Now:

- The right-click menu shows a greyed `MinStats x.y.z` label (no action ⇒
  auto-disabled — it's a label, not a button).
- `make bundle`/`make dmg` stamp `CFBundleShortVersionString` and
  `CFBundleVersion` into the app's `Info.plist` from the *one* version constant
  (`SystemInfo.agentVersion`), so Finder's Get Info matches the menu and the
  wire. **Single source of truth** — bump the constant and all three update
  together.

**The `/Applications` staleness trap (important).** `make run` used to build and
launch `dist/MinStats.app` — but your "Launch at Login" item
(`SMAppService.mainApp`) resolves to **`/Applications/MinStats.app`**. So a stale
copy sitting in `/Applications` was what actually relaunched on every reboot,
silently regressing you to an old build while `dist/` ran the new code. `make
run` now installs into `/Applications` and launches *that* copy, so what you
built is what survives a reboot.

> Concept — *know what actually runs.* A build step that produces an artifact the
> system never launches is worse than no build step: it *looks* current. Make the
> thing you test be the thing that runs.

> Files: `StatusBarController.swift`, `Makefile`, `Support/Info.plist`.

---

## 10. Feature: paired phones report a name (1.6.0)

Two phones both showing "Phone · paired …" is useless for deciding which to
revoke. Now each phone sends `X-MinStats-Client-Name` on signed requests and the
agent records it on that client.

**Two things worth learning here:**

- **Trust the name only after the signature verifies.** It's recorded from within
  `Auth.verify`, *after* the HMAC check passes — so only a genuinely paired phone
  can set its own label. And because it's still remote input headed for the UI,
  it's **sanitized** (percent-decoded, control characters stripped, length
  capped). *Every* string from the wire that reaches a UI or a log gets this
  treatment.
- **The Apple constraint.** Since iOS 16, reading the *user-assigned* device name
  ("Eze's iPhone") requires the `user-assigned-device-name` entitlement — a paid
  developer account plus Apple approval. Without it, `UIDevice.name` just returns
  the model ("iPhone"). So the name sent is the **hardware id** ("iPhone17,3") —
  same raw-model spirit as the Mac's `Mac14,2` — and the code auto-upgrades to
  the personal name *if* that entitlement ever exists. Knowing a platform's
  privacy gates *before* designing a feature saves you from promising something
  the OS won't deliver.

> Files: `StatsClient.swift` (send), `Auth.swift` (`noteName`, sanitize),
> `PairingView.swift` (display).

---

## 11. Fix: hardening the alerts feature (1.6.1)

The alerts feature emails you — via iMessage-to-yourself or a Discord webhook —
when the Mac runs hot. A review found it *well-contained* (no remote input
reaches either channel: the message is the local machine name plus a sensor
number, and the config is local-only), so these are **defense-in-depth**
hardenings, not live-vulnerability fixes. Two of them are still worth studying.

**a) Eliminate the injection *class*, don't just escape it.** The iMessage path
runs AppleScript via `osascript`. The old code built the script by
*interpolating* the recipient and message into the script text and escaping `"`
and `\`. Escaping is a game you have to win every time; the attacker only has to
win once. The fix passes the values as **osascript arguments** (`on run argv`),
so they never touch the script source — there's nothing to escape, and no value
can alter the program.

```swift
process.arguments = ["-e", script, "--", recipient, message]
//                                    ↑ ends osascript's own option parsing, so
//                                      a recipient starting with "-" is data,
//                                      not a flag
```

> Concept — *prefer structural separation of code and data over sanitization.*
> Parameterized SQL queries, `execve` argument arrays (vs `sh -c`), and this
> `argv` pattern are all the same idea: the interpreter is told "this is data"
> out-of-band, so no amount of metacharacters in the data can escape into code.
> This is strictly stronger than escaping and it's why it's the preferred
> defense against every injection class. *Verified*: feeding a classic
> `" of svc` + `tell application "System Events"…` payload as the recipient
> delivered it as an inert string — no execution.

**b) Refuse cleartext for a credential-bearing signal.** The Discord webhook URL
was accepted as-typed, including `http://`. An alert reveals the machine name and
— implicitly — that you're away, so sending it in cleartext is a real leak. The
fix validates the URL to **HTTPS only** (`DiscordNotifier.validated`), which
doubles as the enable-condition for the "Send Test" button, so a bad URL is
visibly rejected in the UI rather than silently failing.

> Concept — *validate at the trust boundary, and let one validator drive both
> the action and the UI* so "what the app will do" and "what the UI says it'll
> do" can't diverge.

Two lower-severity notes were left as accepted trades, consistent with the
threat model (same-user malware is out of scope): the webhook URL and iMessage
recipient live in plaintext `UserDefaults` (a bearer credential + PII, but no
worse than same-user access already grants), and the granted Automation-to-
Messages TCC permission is a *persistent* capability any code in the process can
use.

> Files: `AlertMonitor.swift` (`IMessageNotifier`, `DiscordNotifier.validated`),
> `AlertsView.swift` (UI gate + hint).

---

## Recurring lessons (the transferable bits)

If you remember nothing else:

1. **Validate untrusted lengths/offsets before indexing.** (§3)
2. **Authenticate both directions if both sides need certainty.** (§4)
3. **Bind and domain-separate signatures** — to a nonce, to a `RESPONSE`
   prefix — so they can't be replayed or confused. (§2, §4)
4. **Compare secrets in constant time; burn nonces after validating.** (§2)
5. **Bound every remote-consumable resource:** connections, memory, *time*. (§5)
6. **Destructive/security-relevant actions need explicit consent.** (§6)
7. **Unauthenticated endpoints disclose the minimum.** (§7a)
8. **Treat credentials as ephemeral; don't let them linger.** (§7b)
9. **Set restrictive file/keychain permissions atomically.** (§7c)
10. **Give each client its own credential so it can be revoked alone —**
    **with an invisible migration path.** (§8)
11. **Sanitize every wire string that reaches a UI or log.** (§10)
12. **Make the artifact you test be the one that actually runs.** (§9)
13. **Separate code from data structurally (argv, params) instead of escaping —**
    **it's the stronger defense against every injection class.** (§11)
14. **Refuse cleartext for anything sensitive; validate at the boundary.** (§11)

---

## Building a new version

MinStats builds with **Command Line Tools only** (no Xcode) for the Mac app; the
iOS app needs full Xcode.

### Step 1 — bump the version (single source of truth)

There is exactly one place to change. Edit `agentVersion` in
`Sources/MinStats/Agent/StatsServer.swift`:

```swift
static let agentVersion = "1.6.1"   // ← bump this
```

That constant feeds **all three** version surfaces at once: the `/health`
endpoint, the right-click menu label, and (via the Makefile stamping it into
`Info.plist`) Finder's Get Info. Bump it on any change worth identifying
remotely — that's what lets you confirm from your phone that an update landed.

### Step 2 — build & install the Mac app

```sh
make run          # release build → assemble + ad-hoc sign → install to
                  # /Applications → relaunch. This is the everyday command.
```

`make run` installs into `/Applications` (not just `dist/`), so the login-item
copy stays current — see §9.

Other useful targets:

```sh
make print        # CLI probe: dump one sample of everything, no UI. Debug samplers.
make serve        # headless agent (no menu bar), prints the pairing link;
                  # lets the whole wire API be curl-tested without Xcode
make dmg          # universal (arm64 + x86_64) installer at dist/MinStats.dmg,
                  # version-stamped. Use when handing MinStats to a Mac that
                  # doesn't have the repo. Rebuild it whenever you'd hand it out.
make icon         # regenerate Support/AppIcon.icns (only when artwork changes)
make clean        # wipe .build and dist
```

**`.app` vs `.dmg` — which to install where?** If a Mac has the repo + toolchain
(like the mini), `git pull && make run` is strictly better: it builds natively,
stamps the version, installs to `/Applications`, and never adds a quarantine flag.
The `.dmg` is for a Mac *without* the repo — but a stale dmg is a trap (it can
lag many versions behind), so rebuild it fresh (`make dmg`) each time you'd
actually distribute it. Both `.app` and the app inside the `.dmg` are ad-hoc
signed, so a first launch on another Mac needs right-click → Open once (or
`xattr -d com.apple.quarantine`).

### Step 3 — rebuild & reinstall the iOS app (needs Xcode)

```sh
cd ios
xcodebuild -project MinStats.xcodeproj -scheme MinStats \
  -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' build
```

For a physical iPhone, see **`ios/SETUP.md`** (the from-scratch guide). Note the
free-provisioning **7-day expiry**: the iOS app must be rebuilt + reinstalled
about weekly regardless of code changes.

### Rollout order (don't skip this)

Because the phone now *requires* signed responses (§4) and prefers per-client
credentials (§8):

> **Update all Macs before you update the phone.** An updated phone reads a
> pre-1.4 agent as "reply couldn't be verified." Existing pairings otherwise
> migrate untouched (§8), so no re-pairing is needed for a version bump.

### Sanity checks after a build

```sh
# Version is consistent across all three surfaces:
curl -4 -s http://127.0.0.1:51847/health        # "agent":"x.y.z"
defaults read /Applications/MinStats.app/Contents/Info CFBundleShortVersionString
#   → and eyeball the greyed label in the right-click menu

# Samplers still sane (idle M2 die temps ~35-55 °C; RAM near Activity Monitor):
make print
```
