import Foundation
import MinStatsProtocol
import Network
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
    private let port: NWEndpoint.Port
    private let auth: Auth
    private let deviceID: String
    /// Supplies the most recent sample. The server never samples itself —
    /// a polling phone costs zero extra IOKit work.
    private let snapshot: @MainActor () -> StatsDTO
    private var listener: NWListener?

    init(
        port: UInt16 = MinStatsProtocolVersion.defaultPort,
        auth: Auth,
        deviceID: String,
        snapshot: @escaping @MainActor () -> StatsDTO
    ) {
        self.port = NWEndpoint.Port(rawValue: port) ?? 51847
        self.auth = auth
        self.deviceID = deviceID
        self.snapshot = snapshot
    }

    func start() throws {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: port)

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
            Task { @MainActor in self?.accept(connection) }
        }
        // Without this, a bind failure (port taken, local-network denied)
        // is completely silent — the agent just never answers.
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                NSLog("MinStats agent listening on \(MinStatsProtocolVersion.defaultPort)")
            case let .failed(error):
                NSLog("MinStats agent failed: \(error.localizedDescription)")
            case let .waiting(error):
                NSLog("MinStats agent waiting: \(error.localizedDescription)")
            default:
                break
            }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connection handling

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
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
            Task { @MainActor in
                if let request = HTTP.parse(buffer) {
                    let response = self.route(request, from: connection)
                    self.send(response, on: connection)
                } else {
                    self.receive(connection, buffer: buffer)  // need more bytes
                }
            }
        }
    }

    private func send(_ response: HTTP.Response, on connection: NWConnection) {
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
            return .json(snapshot())

        case ("POST", "/control/kill"), ("POST", "/control/restart"):
            // Control is refused outright from anything but a private
            // address — the code-level guarantee that "restart my Mac"
            // can never be reached from the public internet, regardless of
            // how the network is configured.
            guard Self.isPrivatePeer(connection) else {
                return .error("control is restricted to private networks", status: 403)
            }
            if let denial = authorize(request) { return denial }
            return request.path == "/control/kill"
                ? handleKill(request)
                : handleRestart(request)

        case (_, "/health"), (_, "/stats"), (_, "/control/kill"), (_, "/control/restart"):
            return .error("method not allowed", status: 405)

        default:
            return .error("not found", status: 404)
        }
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

    private func handleRestart(_ request: HTTP.Request) -> HTTP.Response {
        guard let body = try? JSONDecoder().decode(RestartRequestDTO.self, from: request.body),
              body.confirm
        else {
            return .error("restart requires confirm: true", status: 400)
        }
        Control.requestRestart()
        return .json(RestartResponseDTO())
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
        var capabilities = ["stats", "kill", "restart"]
        if !snapshot().fans.isEmpty { capabilities.append("fans") }
        return HealthDTO(
            protocol: MinStatsProtocolVersion.current,
            id: deviceID,
            name: SystemInfo.computerName,
            model: SystemInfo.model,
            os: SystemInfo.osVersion,
            agent: SystemInfo.agentVersion,
            paired: true,
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
    /// NOT `Host.current().localizedName`: that's a networking API that
    /// resolves the host, and on a network with slow reverse-DNS it blocks
    /// for ~5s — per request, since it sits in the /health path. Measured at
    /// 0.001s on one Mac and 5.04s on another purely because of their subnets.
    /// SCDynamicStore reads the name straight from local config, no DNS, and
    /// it's the API that actually means "what is this Mac called".
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

    static let osVersion: String = {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }()

    static let agentVersion = "1.1.0"
}
