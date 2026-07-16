import Foundation

/// The MinStats agent wire contract, shared verbatim by the Mac agent and
/// the iOS client so there is exactly one source of truth.
///
/// Units are RAW — exactly as the samplers produce them: Celsius, CPU as a
/// 0…1 fraction, memory in GB, process memory in bytes. Formatting is the
/// client's job, so each client owns its own °C/°F preference.
public enum MinStatsProtocolVersion {
    public static let current = 1
    /// Fixed (not ephemeral) so a client can be added by host:port when
    /// Bonjour isn't available — e.g. over a tailnet.
    public static let defaultPort: UInt16 = 51847
    public static let bonjourType = "_minstats._tcp"
}

// MARK: - Identity

/// `GET /health` — unauthenticated so a client can list a Mac before
/// pairing. Deliberately exposes nothing the Bonjour TXT record doesn't.
public struct HealthDTO: Codable, Sendable {
    public let `protocol`: Int
    public let id: String
    public let name: String
    public let model: String
    public let os: String
    public let agent: String
    public let paired: Bool
    /// e.g. ["stats", "kill", "restart"] — omits "fans" on fanless Macs.
    public let capabilities: [String]
    /// The Mac's stable Tailscale address (100.64.0.0/10), if it's on a
    /// tailnet — reachable from anywhere on that tailnet, unlike the `.local`
    /// name which only resolves on the LAN. Nil when Tailscale isn't running.
    public let tailnetHost: String?

    public init(
        protocol protocolVersion: Int, id: String, name: String, model: String,
        os: String, agent: String, paired: Bool, capabilities: [String],
        tailnetHost: String? = nil
    ) {
        self.protocol = protocolVersion
        self.id = id
        self.name = name
        self.model = model
        self.os = os
        self.agent = agent
        self.paired = paired
        self.capabilities = capabilities
        self.tailnetHost = tailnetHost
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
