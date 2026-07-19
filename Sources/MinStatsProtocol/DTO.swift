import Foundation

/// The MinStats agent wire contract, shared verbatim by the Mac agent and
/// the iOS client so there is exactly one source of truth.
///
/// Units are RAW — exactly as the samplers produce them: Celsius, CPU as a
/// 0…1 fraction, memory in GB, process memory in bytes. Formatting is the
/// client's job, so each client owns its own °C/°F preference.
public enum MinStatsProtocolVersion {
    /// The wire generation. **Bump ONLY on a breaking change** — a field
    /// removed/renamed, or its meaning/units changed. *Additive* changes (a new
    /// optional field, a new endpoint) must NOT bump it: those are handled
    /// backward-compatibly by optional DTO fields, the `HealthDTO.capabilities`
    /// list, and graceful handling of a missing endpoint (e.g. the iOS app
    /// treating a 404 on `/alerts` as "this agent is too old for that feature").
    ///
    /// Because it only moves on breaking changes, "agent version != app version"
    /// means genuinely incompatible, and the *direction* says which side is
    /// older and needs updating — see `compatibility(agentProtocol:)`. `/health`
    /// carries this and is the designated handshake: its DTO must stay
    /// backward-decodable across generations so a client can always read the
    /// version even when it can't speak the rest of the protocol.
    public static let current = 1
    /// Fixed (not ephemeral) so a client can be added by host:port when
    /// Bonjour isn't available — e.g. over a tailnet.
    public static let defaultPort: UInt16 = 51847
    public static let bonjourType = "_minstats._tcp"

    public enum Compatibility: Equatable {
        case ok
        /// The agent speaks a newer generation — update the client.
        case agentNewer
        /// The agent speaks an older generation — update the agent.
        case agentOlder
    }

    /// Compares an agent's advertised protocol to what this build speaks.
    public static func compatibility(agentProtocol: Int) -> Compatibility {
        if agentProtocol > current { return .agentNewer }
        if agentProtocol < current { return .agentOlder }
        return .ok
    }
}

// MARK: - Identity

/// `GET /health` — unauthenticated so a client can list a Mac before
/// pairing, so it carries only what the Bonjour TXT record already
/// broadcasts, plus the agent version — the one remote diagnostic worth
/// having ("did my update land?"). The OS version and reachable addresses
/// (Tailscale/LAN IPs) used to be here and were moved out deliberately:
/// they fingerprinted the Mac to any peer on any network it joins. The
/// alt routes travel in the pairing link, which is where they belong.
public struct HealthDTO: Codable, Sendable {
    public let `protocol`: Int
    public let id: String
    public let name: String
    public let model: String
    public let agent: String
    /// e.g. ["stats", "kill", "restart"] — omits "fans" on fanless Macs.
    public let capabilities: [String]

    public init(
        protocol protocolVersion: Int, id: String, name: String, model: String,
        agent: String, capabilities: [String]
    ) {
        self.protocol = protocolVersion
        self.id = id
        self.name = name
        self.model = model
        self.agent = agent
        self.capabilities = capabilities
    }
}

// MARK: - Alerts

/// `GET /alerts` (read) and `PUT /alerts` (write) — the non-sensitive
/// temperature-alert settings, so a paired phone can tune *what to alert on*
/// remotely. Deliberately carries **no delivery-channel details**: the Discord
/// webhook is a bearer credential and the iMessage recipient is PII, so both
/// stay Mac-only and never cross the wire.
///
/// `thresholdC` is raw Celsius (the client formats °C/°F). `channelsConfigured`
/// is a read-only hint — is there anywhere for an alert to actually go? — so the
/// phone can warn when alerts are on but would fire into the void; the agent
/// ignores it on write.
public struct AlertConfigDTO: Codable, Sendable {
    public let enabled: Bool
    public let thresholdC: Double
    public let channelsConfigured: Bool

    public init(enabled: Bool, thresholdC: Double, channelsConfigured: Bool = false) {
        self.enabled = enabled
        self.thresholdC = thresholdC
        self.channelsConfigured = channelsConfigured
    }

    enum CodingKeys: String, CodingKey { case enabled, thresholdC, channelsConfigured }

    // `channelsConfigured` is a read-only hint the agent derives and ignores on
    // write, so it's optional on decode — a PUT carrying only the two settable
    // fields is valid input, not malformed.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        thresholdC = try c.decode(Double.self, forKey: .thresholdC)
        channelsConfigured = try c.decodeIfPresent(Bool.self, forKey: .channelsConfigured) ?? false
    }
}

// MARK: - Stats

public struct SensorDTO: Codable, Sendable {
    public let name: String
    /// Celsius.
    public let c: Double

    public init(name: String, c: Double) {
        self.name = name
        self.c = c
    }
}

public struct FanDTO: Codable, Sendable {
    public let name: String
    public let rpm: Double

    public init(name: String, rpm: Double) {
        self.name = name
        self.rpm = rpm
    }
}

public struct MemoryDTO: Codable, Sendable {
    public let usedGB: Double
    public let totalGB: Double

    public init(usedGB: Double, totalGB: Double) {
        self.usedGB = usedGB
        self.totalGB = totalGB
    }
}

/// A process group (helpers folded into their owning .app).
///
/// `value` means different things per list — a 0…1 CPU fraction in
/// `topCPU`, bytes in `topMemory` — mirroring the sampler's own
/// `ProcessEntry`. `pids` carries every pid in the group so a client can
/// ask for the whole app to quit, not just one helper.
public struct ProcessDTO: Codable, Sendable {
    public let name: String
    public let value: Double
    public let pids: [Int32]

    public init(name: String, value: Double, pids: [Int32]) {
        self.name = name
        self.value = value
        self.pids = pids
    }
}

/// `GET /stats` — authenticated. Every metric is optional because the
/// samplers legitimately return nil (CPU has no delta on the first tick;
/// headline is nil if no sensor reads valid).
public struct StatsDTO: Codable, Sendable {
    public let `protocol`: Int
    public let sampledAt: Double
    /// The Mac's own refresh cadence, so a client can poll in step.
    public let interval: Double
    public let headlineC: Double?
    /// 0…1 fraction of total machine capacity.
    public let cpu: Double?
    public let memory: MemoryDTO?
    public let sensors: [SensorDTO]
    public let fans: [FanDTO]
    public let topCPU: [ProcessDTO]
    public let topMemory: [ProcessDTO]

    public init(
        protocol protocolVersion: Int, sampledAt: Double, interval: Double,
        headlineC: Double?, cpu: Double?, memory: MemoryDTO?,
        sensors: [SensorDTO], fans: [FanDTO],
        topCPU: [ProcessDTO], topMemory: [ProcessDTO]
    ) {
        self.protocol = protocolVersion
        self.sampledAt = sampledAt
        self.interval = interval
        self.headlineC = headlineC
        self.cpu = cpu
        self.memory = memory
        self.sensors = sensors
        self.fans = fans
        self.topCPU = topCPU
        self.topMemory = topMemory
    }
}

// MARK: - Control

public enum KillMode: String, Codable, Sendable {
    /// A real Cmd-Q — lets the app save. The default.
    case graceful
    /// SIGKILL / forceTerminate. Should sit behind a second confirmation.
    case force
}

/// `POST /control/kill`.
///
/// `name` is a safety interlock, not redundancy: a pid captured on a
/// seconds-old client screen may have exited and been recycled onto an
/// unrelated process. The agent re-resolves each pid's current name and
/// refuses on mismatch.
public struct KillRequestDTO: Codable, Sendable {
    public let pids: [Int32]
    public let name: String
    public let mode: KillMode

    public init(pids: [Int32], name: String, mode: KillMode = .graceful) {
        self.pids = pids
        self.name = name
        self.mode = mode
    }
}

public struct KillResultDTO: Codable, Sendable {
    public enum Status: String, Codable, Sendable {
        case terminating
        case denied
        case gone
    }

    public let pid: Int32
    public let status: Status
    public let reason: String?

    public init(pid: Int32, status: Status, reason: String? = nil) {
        self.pid = pid
        self.status = status
        self.reason = reason
    }
}

/// Per-pid, never all-or-nothing: killing an app group can partially
/// succeed and the client must be able to say which parts did.
public struct KillResponseDTO: Codable, Sendable {
    public let results: [KillResultDTO]

    public init(results: [KillResultDTO]) {
        self.results = results
    }
}

public struct RestartRequestDTO: Codable, Sendable {
    public let confirm: Bool

    public init(confirm: Bool) {
        self.confirm = confirm
    }
}

/// Restart is a *request*: an unprivileged graceful restart can be vetoed
/// by any app with unsaved changes, so the agent never claims success —
/// the client should treat the Mac going offline as the real confirmation.
public struct RestartResponseDTO: Codable, Sendable {
    public let status: String

    public init(status: String = "requested") {
        self.status = status
    }
}

public struct ErrorDTO: Codable, Sendable {
    public let error: String

    public init(error: String) {
        self.error = error
    }
}
