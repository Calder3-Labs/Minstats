import Foundation
import MinStatsProtocol
import Network
import Security
import SystemConfiguration

/// The agent: serves MinStats' latest sample to paired clients over the
/// local network (and, later, a tailnet), and accepts control commands.
///
/// It's embedded in the menu bar app rather than run as a helper because
/// the app already owns the samplers (one IOHID/SMC client, one sampling
/// loop), already launches at login, and already runs as the user — which
/// is exactly the privilege the control endpoints need and no more.
@MainActor
final class StatsServer {
    private let auth: Auth
    private let deviceID: String
    /// Supplies the most recent sample. The server never samples itself —
    /// a polling phone costs zero extra IOKit work.
    private let snapshot: @MainActor () -> StatsDTO
    /// Reads / writes the temperature-alert config for the phone. Channel
    /// secrets never cross this boundary (see `AlertConfigDTO`).
    private let alertConfig: @MainActor () -> AlertConfigDTO
    private let setAlertConfig: @MainActor (AlertConfigDTO) -> AlertConfigDTO
    private var listener: NWListener?

    init(
        auth: Auth,
        deviceID: String,
        snapshot: @escaping @MainActor () -> StatsDTO,
        alertConfig: @escaping @MainActor () -> AlertConfigDTO,
        setAlertConfig: @escaping @MainActor (AlertConfigDTO) -> AlertConfigDTO
    ) {
        self.auth = auth
        self.deviceID = deviceID
        self.snapshot = snapshot
        self.alertConfig = alertConfig
        self.setAlertConfig = setAlertConfig
    }

    /// TLS-only since 2.0.0 (TLS plan step 5): the plain-HTTP listener is
    /// retired. One listener serves HTTPS on the TLS port and carries the
    /// Bonjour advertisement — discovery is browse-only metadata (the phone
    /// reads the TXT record, it never dials an unpaired Mac), so nothing is
    /// lost by advertising from here. A pre-2.0 pin-less pairing now gets
    /// connection-refused, which the phone's offline hint reads as "check
    /// pairing" — re-pairing (the link carries the pin) is the migration.
    func start() throws {
        guard listener == nil else { return }
        guard AgentIdentity.tlsEnabled,
              let identity = AgentIdentity.tlsIdentity(),
              let secIdentity = sec_identity_create(identity),
              let tlsPort = NWEndpoint.Port(rawValue: MinStatsProtocolVersion.defaultTLSPort)
        else {
            // Loud: with no TLS identity there is no agent at all now.
            NSLog("MinStats agent: no TLS identity — agent NOT serving")
            return
        }
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secIdentity)
        let params = NWParameters(tls: tls)
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: tlsPort)

        // Bonjour advertisement so the phone finds this Mac with no config.
        listener.service = NWListener.Service(
            name: SystemInfo.computerName,
            type: MinStatsProtocolVersion.bonjourType,
            txtRecord: NWTXTRecord([
                "id": deviceID,
                "name": SystemInfo.computerName,
                "model": SystemInfo.model,
                "v": String(MinStatsProtocolVersion.current),
            ])
        )
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)   // already on `queue` — no hop
        }
        // Without this, a bind failure (port taken, local-network denied)
        // is completely silent — the agent just never answers.
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                NSLog("MinStats agent: TLS listening on \(MinStatsProtocolVersion.defaultTLSPort)")
            case let .failed(error):
                NSLog("MinStats agent: TLS failed: \(error.localizedDescription)")
            case let .waiting(error):
                NSLog("MinStats agent waiting: \(error.localizedDescription)")
            default:
                break
            }
        }
        listener.start(queue: Self.queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connection handling

    /// All listener and connection work runs here, off the main thread, so a
    /// burst of connections can't jank the menu bar UI. Serial, so the
    /// connection counter below needs no lock. Only routing hops to the main
    /// actor — the samplers and Control live there.
    nonisolated private static let queue = DispatchQueue(label: "MinStats.agent")

    /// Bounds on rude peers: more simultaneous connections than this are
    /// refused outright, and one that hasn't finished its exchange within the
    /// deadline is cut. The phone races ~3 routes per poll and a legitimate
    /// exchange takes milliseconds, so neither bound is ever felt.
    nonisolated private static let maxConnections = 16
    nonisolated private static let connectionDeadline: TimeInterval = 10

    /// Confined to `queue` — accept and every state change run there.
    nonisolated(unsafe) private var activeConnections = 0

    nonisolated private func accept(_ connection: NWConnection) {
        guard activeConnections < Self.maxConnections else {
            connection.cancel()   // over the cap: refuse without starting
            return
        }
        activeConnections += 1
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed:
                connection.cancel()   // guarantee the terminal .cancelled below
            case .cancelled:
                self?.activeConnections -= 1
                connection.stateUpdateHandler = nil   // break the self-retain cycle
            default:
                break
            }
        }
        connection.start(queue: Self.queue)
        // The deadline reaps held-open sockets (and half-sent junk the parser
        // never completes on) — the counterpart of the cap, so slots can't be
        // pinned down indefinitely.
        Self.queue.asyncAfter(deadline: .now() + Self.connectionDeadline) { [weak connection] in
            connection?.cancel()
        }
        receive(connection, buffer: Data())
    }

    nonisolated private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] chunk, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let chunk { buffer.append(chunk) }

            if error != nil || (isComplete && buffer.isEmpty) {
                connection.cancel()
                return
            }
            // Refuse absurd requests rather than buffering forever.
            guard buffer.count <= 256 * 1024 else {
                connection.cancel()
                return
            }
            if let request = HTTP.parse(buffer) {
                Task { @MainActor in
                    let response = self.route(request, from: connection)
                    self.send(response, on: connection)
                }
            } else {
                self.receive(connection, buffer: buffer)  // need more bytes
            }
        }
    }

    nonisolated private func send(_ response: HTTP.Response, on connection: NWConnection) {
        connection.send(content: response.wireData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - Routing

    private func route(_ request: HTTP.Request, from connection: NWConnection) -> HTTP.Response {
        switch (request.method, request.path) {
        case ("GET", "/health"):
            // Unauthenticated by design: the phone must be able to list a
            // Mac before pairing, and this exposes nothing the Bonjour TXT
            // record doesn't already broadcast.
            return .json(health())

        case ("GET", "/stats"):
            if let denial = authorize(request) { return denial }
            return signed(.json(snapshot()), for: request)

        case ("GET", "/alerts"):
            if let denial = authorize(request) { return denial }
            return signed(.json(alertConfig()), for: request)

        case ("PUT", "/alerts"):
            // Config, not control: a threshold isn't destructive like
            // restart/kill, so it's signed but NOT private-peer-gated —
            // deliberately reachable over Tailscale.
            if let denial = authorize(request) { return denial }
            return signed(handleSetAlerts(request), for: request)

        // /control/restart was REMOVED (2.2.0): on a FileVault Mac a remote
        // restart halts at the pre-boot unlock screen — agent, Tailscale and
        // all — converting reachable-but-sick into unreachable-until-
        // physically-attended; the AppleScript request was also vetoable and
        // unverifiable, and the path was untested by design. Old phones that
        // still POST it get the graceful 404 below, per the compat contract.
        case ("POST", "/control/kill"):
            // Control is refused outright from anything but a private
            // address — the code-level guarantee that a kill can never be
            // reached from the public internet, regardless of how the
            // network is configured.
            guard Self.isPrivatePeer(connection) else {
                return .error("control is restricted to private networks", status: 403)
            }
            if let denial = authorize(request) { return denial }
            return signed(handleKill(request), for: request)

        case (_, "/health"), (_, "/stats"), (_, "/alerts"), (_, "/control/kill"):
            return .error("method not allowed", status: 405)

        default:
            return .error("not found", status: 404)
        }
    }

    private func handleSetAlerts(_ request: HTTP.Request) -> HTTP.Response {
        guard let body = try? JSONDecoder().decode(AlertConfigDTO.self, from: request.body) else {
            return .error("malformed request", status: 400)
        }
        // Returns the config as actually applied (threshold clamped), so the
        // phone's optimistic value snaps to what the Mac accepted.
        return .json(setAlertConfig(body))
    }

    private func handleKill(_ request: HTTP.Request) -> HTTP.Response {
        guard let body = try? JSONDecoder().decode(KillRequestDTO.self, from: request.body) else {
            return .error("malformed request", status: 400)
        }
        guard !body.pids.isEmpty else {
            return .error("no pids given", status: 400)
        }
        let results = Control.kill(pids: body.pids, expectedName: body.name, mode: body.mode)
        return .json(KillResponseDTO(results: results))
    }

    /// Signs a response with the requesting client's secret and nonce,
    /// proving to the phone that it came from the paired Mac (see
    /// `Auth.responseSignature`). Only reached after `authorize`, so the
    /// headers are always present — but degrade to unsigned rather than
    /// trap if they somehow aren't.
    private func signed(_ response: HTTP.Response, for request: HTTP.Request) -> HTTP.Response {
        guard let nonce = request.headers["x-minstats-nonce"],
              let clientID = request.headers["x-minstats-key"]
        else { return response }
        var response = response
        response.signature = auth.responseSignature(clientID: clientID, nonce: nonce, body: response.body)
        return response
    }

    private func authorize(_ request: HTTP.Request) -> HTTP.Response? {
        do {
            try auth.verify(
                method: request.method, path: request.path,
                headers: request.headers, body: request.body
            )
            return nil
        } catch {
            return .error("unauthorized", status: 401)
        }
    }

    private func health() -> HealthDTO {
        var capabilities = ["stats", "kill"]
        if !snapshot().fans.isEmpty { capabilities.append("fans") }
        return HealthDTO(
            protocol: MinStatsProtocolVersion.current,
            id: deviceID,
            name: SystemInfo.computerName,
            model: SystemInfo.model,
            agent: SystemInfo.agentVersion,
            capabilities: capabilities
        )
    }

    // MARK: - Network scoping

    /// True for loopback, RFC1918, link-local, and 100.64.0.0/10 — the
    /// CGNAT range Tailscale uses, so control works over a tailnet while
    /// staying closed to the public internet.
    static func isPrivatePeer(_ connection: NWConnection) -> Bool {
        guard case let .hostPort(host, _) = connection.endpoint else { return false }
        switch host {
        case let .ipv4(address):
            let b = address.rawValue.map { $0 }
            guard b.count == 4 else { return false }
            if b[0] == 127 { return true }                                  // loopback
            if b[0] == 10 { return true }                                   // 10/8
            if b[0] == 172, (16...31).contains(b[1]) { return true }        // 172.16/12
            if b[0] == 192, b[1] == 168 { return true }                     // 192.168/16
            if b[0] == 169, b[1] == 254 { return true }                     // link-local
            if b[0] == 100, (64...127).contains(b[1]) { return true }       // 100.64/10 (Tailscale)
            return false
        case let .ipv6(address):
            if address.isLoopback || address.isLinkLocal { return true }
            // Unique-local (fc00::/7) covers Tailscale's IPv6 range too.
            if let first = address.rawValue.first, (first & 0xFE) == 0xFC { return true }
            // IPv4-mapped IPv6 — re-check against the v4 rules.
            if let mapped = address.asIPv4 {
                let b = mapped.rawValue.map { $0 }
                guard b.count == 4 else { return false }
                if b[0] == 127 || b[0] == 10 { return true }
                if b[0] == 172, (16...31).contains(b[1]) { return true }
                if b[0] == 192, b[1] == 168 { return true }
                if b[0] == 169, b[1] == 254 { return true }
                if b[0] == 100, (64...127).contains(b[1]) { return true }
            }
            return false
        default:
            return false
        }
    }
}

// MARK: - System identity

enum SystemInfo {
    /// The user-visible computer name ("Example-Air").
    ///
    /// SCDynamicStore reads it straight from local config with no DNS, and is
    /// the API that actually means "what is this Mac called" —
    /// `Host.current().localizedName` is a networking API that resolves the
    /// host, so it doesn't belong on a per-request path. Cached either way.
    ///
    /// Correcting the record: the commit that introduced this claimed it fixed
    /// a 5s /health stall on the Mac mini. It did NOT. That stall was `curl`
    /// trying an IPv4-mapped IPv6 address (`::ffff:10.187.64.140`) on a network
    /// with no IPv6 route and eating its full 5s timeout before falling back to
    /// IPv4. The agent always answered in ~0.02s, and URLSession — what the iOS
    /// app uses — does Happy Eyeballs and measured 0.084s against the same host.
    /// The bug was in the measuring tool. Kept because it's still the right API,
    /// not because it fixed anything.
    static let computerName: String = {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"
    }()

    /// Raw hardware identifier (e.g. "Mac14,2"). Deliberately not mapped to
    /// a marketing name — that would be a lookup table to maintain forever.
    static let model: String = {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        return String(decoding: buffer.prefix(while: { $0 != 0 }).map(UInt8.init(bitPattern:)), as: UTF8.self)
    }()

    /// Extra addresses this Mac is reachable at, beyond its `.local` name —
    /// so a client off the LAN (where `.local` doesn't resolve) can still find
    /// it. The app is transport-agnostic: it doesn't care *why* an address
    /// works, only that it's another route to try. Ordered so the fastest-to-
    /// fail-when-inapplicable comes first:
    ///
    /// 1. **Tailscale** (100.64.0.0/10) — globally unique to this device;
    ///    unroutable and fails instantly when the client isn't on the tailnet.
    /// 2. **LAN IP** (RFC1918) — what a plain WireGuard tunnel into the LAN
    ///    (e.g. a Firewalla) routes you to. Reserve it via DHCP so it's stable.
    ///    Caveat: a LAN IP is only meaningful on *that* subnet, so on a foreign
    ///    network it may briefly fail before "offline" — acceptable.
    ///
    /// Re-evaluated per call, so addresses appear without an app restart when a
    /// tunnel comes up later.
    static func reachableHosts() -> [String] {
        var tailscale: String?
        var lan: String?
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return [] }
        defer { freeifaddrs(addrs) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard Int32(ptr.pointee.ifa_flags) & IFF_UP == IFF_UP,
                  let sa = ptr.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET)
            else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(decoding: host.prefix(while: { $0 != 0 }).map(UInt8.init(bitPattern:)), as: UTF8.self)
            let o = ip.split(separator: ".").compactMap { Int($0) }
            guard o.count == 4 else { continue }
            if o[0] == 100, (64...127).contains(o[1]) {
                tailscale = tailscale ?? ip                                   // 100.64/10 (Tailscale)
            } else if o[0] == 10
                || (o[0] == 172 && (16...31).contains(o[1]))
                || (o[0] == 192 && o[1] == 168) {
                lan = lan ?? ip                                              // RFC1918 LAN
            }
        }
        return [tailscale, lan].compactMap { $0 }
    }

    /// Bump on any wire-visible or behavioural change. /health reports this so
    /// you can tell which build a Mac is actually running — without it, "did
    /// my update land?" is unanswerable from the network.
    static let agentVersion = "2.2.4"
}
